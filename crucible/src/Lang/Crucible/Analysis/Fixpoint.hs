{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}
module Lang.Crucible.Analysis.Fixpoint (
  -- * Entry point
  forwardFixpoint,
  -- * Abstract Domains
  Domain(..),
  IterationStrategy(..),
  Interpretation(..),
  PointAbstraction,
  paGlobals,
  paRegisters,
  lookupAbstractRegValue,
  -- * Pointed domains
  -- $pointed
  Pointed(..),
  pointed
  ) where

import Control.Applicative
import Control.Lens.Operators ( (^.), (%~), (%=) )
import qualified Control.Monad.State.Strict as St
import qualified Data.Functor.Identity as I
import qualified Data.Parameterized.Context as PU
import qualified Data.Parameterized.TraversableFC as PU
import qualified Data.Parameterized.Map as PM
import qualified Data.Set as S

import Prelude

import Lang.Crucible.CFG.Core
import Lang.Crucible.Analysis.Fixpoint.Components

-- | A wrapper around widening strategies
data WideningStrategy = WideningStrategy (Int -> Bool)

-- | A wrapper around widening operators.  This is mostly here to
-- avoid requiring impredicative types later.
data WideningOperator dom = WideningOperator (forall tp . dom tp -> dom tp -> dom tp)

-- | The iteration strategies available for computing fixed points.
--
-- Algorithmically, the best strategies seem to be based on Weak
-- Topological Orders (WTOs).  The WTO approach also naturally
-- supports widening (with a specified widening strategy and widening
-- operator).
--
-- A simple worklist approach is also available.
data IterationStrategy (dom :: CrucibleType -> *) where
  WTO :: IterationStrategy dom
  WTOWidening :: (Int -> Bool) -> (forall tp . dom tp -> dom tp -> dom tp) -> IterationStrategy dom
  Worklist :: IterationStrategy dom

-- | A domain of abstract values, parameterized by a term type
data Domain (dom :: CrucibleType -> *) =
  Domain { domTop    :: forall tp . dom tp
         , domBottom :: forall tp . dom tp
         , domJoin   :: forall tp . dom tp -> dom tp -> dom tp
         , domIter   :: IterationStrategy dom
         , domEq     :: forall tp . dom tp -> dom tp -> Bool
         }

-- | Transfer functions for each statement type
data Interpretation (dom :: CrucibleType -> *) =
  Interpretation { interpExpr       :: forall blocks ctx tp
                                     . TypeRepr tp
                                    -> Expr ctx tp
                                    -> PointAbstraction blocks dom ctx
                                    -> (Maybe (PointAbstraction blocks dom ctx), dom tp)
                 , interpCall       :: forall blocks ctx args ret
                                     . CtxRepr args
                                    -> TypeRepr ret
                                    -> Reg ctx (FunctionHandleType args ret)
                                    -> dom (FunctionHandleType args ret)
                                    -> PU.Assignment dom args
                                    -> PointAbstraction blocks dom ctx
                                    -> (Maybe (PointAbstraction blocks dom ctx), dom ret)
                 , interpReadGlobal :: forall blocks ctx tp
                                     . GlobalVar tp
                                    -> PointAbstraction blocks dom ctx
                                    -> (Maybe (PointAbstraction blocks dom ctx), dom tp)
                 , interpWriteGlobal :: forall blocks ctx tp
                                      . GlobalVar tp
                                     -> Reg ctx tp
                                     -> PointAbstraction blocks dom ctx
                                     -> Maybe (PointAbstraction blocks dom ctx)
                 , interpBr         :: forall blocks ctx
                                     . Reg ctx BoolType
                                    -> dom BoolType
                                    -> JumpTarget blocks ctx
                                    -> JumpTarget blocks ctx
                                    -> PointAbstraction blocks dom ctx
                                    -> (Maybe (PointAbstraction blocks dom ctx), Maybe (PointAbstraction blocks dom ctx))
                 , interpMaybe      :: forall blocks ctx tp
                                     . TypeRepr tp
                                    -> Reg ctx (MaybeType tp)
                                    -> dom (MaybeType tp)
                                    -> PointAbstraction blocks dom ctx
                                    -> (Maybe (PointAbstraction blocks dom ctx), dom tp, Maybe (PointAbstraction blocks dom ctx))
                 }

-- | This abstraction contains the abstract values of each register at
-- the program point represented by the abstraction.  It also contains
-- a map of abstractions for all of the global variables currently
-- known.
data PointAbstraction blocks dom ctx =
  PointAbstraction { _paGlobals :: PM.MapF GlobalVar dom
                   , _paRegisters :: PU.Assignment dom ctx
                   , _paRefs :: PM.MapF (RefStmtId blocks) dom
                   -- ^ In this map, the keys are really just the 'StmtId's in
                   -- '_paRegisterRefs', but with a newtype wrapper that unwraps
                   -- a level of their 'ReferenceType` type rep.
                   , _paRegisterRefs :: PU.Assignment (RefSet blocks) ctx
                   -- ^ This mapping records the *set* of references (named by
                   -- allocation site) that each register could hold.
                   }

-- | This is a wrapper around 'StmtId' that exposes the underlying type of a
-- 'ReferenceType', and is needed to define the abstract value we carry around.
newtype RefStmtId blocks tp = RefStmtId (StmtId blocks (ReferenceType tp))

-- | This type names an allocation site in a program.
--
-- Allocation sites are named by their basic block and their index into that
-- containing basic block.  We have to carry around the type repr for inspection
-- later (especially in instances).
data StmtId blocks tp = StmtId (TypeRepr tp) (Some (BlockID blocks)) Int
  deriving (Show)

instance Eq (StmtId blocks tp) where
  StmtId tp1 bid1 ix1 == StmtId tp2 bid2 ix2 =
    case testEquality tp1 tp2 of
      Nothing -> False
      Just Refl -> (bid1, ix1) == (bid2, ix2)

instance Ord (StmtId blocks tp) where
  compare (StmtId tp1 bid1 ix1) (StmtId tp2 bid2 ix2) =
    case toOrdering (compareF tp1 tp2) of
      LT -> LT
      GT -> GT
      EQ -> compare (bid1, ix1) (bid2, ix2)

instance TestEquality (RefStmtId blocks) where
  testEquality (RefStmtId (StmtId tp1 (Some bid1) idx1)) (RefStmtId (StmtId tp2 (Some bid2) idx2)) = do
    Refl <- testEquality tp1 tp2
    Refl <- testEquality bid1 bid2
    case idx1 == idx2 of
      True -> return $! Refl
      False -> Nothing

instance OrdF (RefStmtId blocks) where
  compareF (RefStmtId (StmtId tp1 (Some bid1) idx1)) (RefStmtId (StmtId tp2 (Some bid2) idx2)) =
    case compareF tp1 tp2 of
      EQF ->
        case compareF bid1 bid2 of
          EQF ->
            case compare idx1 idx2 of
              LT -> LTF
              GT -> GTF
              EQ -> EQF
          LTF -> LTF
          GTF -> GTF
      LTF -> LTF
      GTF -> GTF

-- | This is a wrapper around a set of 'StmtId's that name allocation sites of
-- references.  We need the wrapper to correctly position the @tp@ type
-- parameter so that we can put them in an 'PU.Assignment'.
newtype RefSet blocks tp = RefSet (S.Set (StmtId blocks tp))

emptyRefSet :: RefSet blocks tp
emptyRefSet = RefSet S.empty

unionRefSets :: RefSet blocks tp -> RefSet blocks tp -> RefSet blocks tp
unionRefSets (RefSet s1) (RefSet s2) = RefSet (s1 `S.union` s2)

instance ShowF dom => Show (PointAbstraction blocks dom ctx) where
  show pa = show (_paRegisters pa)

instance ShowF dom => ShowF (PointAbstraction blocks dom)

-- | Look up the abstract value of a register at a program point
lookupAbstractRegValue :: PointAbstraction blocks dom ctx -> Reg ctx tp -> dom tp
lookupAbstractRegValue pa (Reg ix) = (pa ^. paRegisters) PU.! ix

-- | The `FunctionAbstraction` contains the abstractions for the entry
-- point of each basic block in the function, as well as the final
-- abstract value for the returned register.
data FunctionAbstraction (dom :: CrucibleType -> *) blocks ret =
  FunctionAbstraction { _faRegs :: PU.Assignment (PointAbstraction blocks dom) blocks
                      , _faRet :: dom ret
                      }

data IterationState (dom :: CrucibleType -> *) blocks ret =
  IterationState { _isFuncAbstr :: FunctionAbstraction dom blocks ret
                 , _isRetAbstr  :: dom ret
                 , _processedOnce :: S.Set (Some (BlockID blocks))
                 }

newtype M (dom :: CrucibleType -> *) blocks ret a = M { runM :: St.State (IterationState dom blocks ret) a }
  deriving (St.MonadState (IterationState dom blocks ret), Monad, Applicative, Functor)

-- | Extend the abstraction with a domain value for the next register.
--
-- The set of references that the register can point to is set to the empty set
extendRegisters :: dom tp -> PointAbstraction blocks dom ctx -> PointAbstraction blocks dom (ctx ::> tp)
extendRegisters domVal pa =
  pa { _paRegisters = PU.extend (_paRegisters pa) domVal
     , _paRegisterRefs = PU.extend (_paRegisterRefs pa) emptyRefSet
     }

-- | Extend the abstraction with a domain value and a set of register references
-- simultaneously.
--
-- Note that we inject a singleton set of reference identifiers here because
-- there was no prior value, so we don't need to set union.
extendRegisterRefs :: dom (ReferenceType tp)
                   -> StmtId blocks (ReferenceType tp)
                   -> dom tp
                   -> PointAbstraction blocks dom ctx
                   -> PointAbstraction blocks dom (ctx ::> ReferenceType tp)
extendRegisterRefs domVal refId refDomVal pa =
  pa { _paRegisters = PU.extend (_paRegisters pa) domVal
     , _paRegisterRefs = PU.extend (_paRegisterRefs pa) (RefSet (S.singleton refId))
     , _paRefs = PM.insert (RefStmtId refId) refDomVal (_paRefs pa)
     }

-- | Join two point abstractions using the join operation of the domain.
--
-- We join registers pointwise.  For globals, we explicitly call join
-- when the global is in both maps.  If a global is only in one map,
-- there is an implicit join with bottom, which always results in the
-- same element.  Since it is a no-op, we just skip it and keep the
-- one present element.
joinPointAbstractions :: forall blocks (dom :: CrucibleType -> *) ctx
                       . Domain dom
                      -> PointAbstraction blocks dom ctx
                      -> PointAbstraction blocks dom ctx
                      -> PointAbstraction blocks dom ctx
joinPointAbstractions dom = zipPAWith (domJoin dom) unionRefSets

zipPAWith :: forall blocks (dom :: CrucibleType -> *) ctx
                       . (forall tp . dom tp -> dom tp -> dom tp)
                      -> (forall tp . RefSet blocks tp -> RefSet blocks tp -> RefSet blocks tp)
                      -> PointAbstraction blocks dom ctx
                      -> PointAbstraction blocks dom ctx
                      -> PointAbstraction blocks dom ctx
zipPAWith domOp refSetOp pa1 pa2 =
  pa1 { _paRegisters = PU.zipWith domOp (pa1 ^. paRegisters) (pa2 ^. paRegisters)
      , _paGlobals = I.runIdentity $ do
          PM.mergeWithKeyM (\_ a b -> return (Just (domOp a b))) return return (pa1 ^. paGlobals) (pa2 ^. paGlobals)
      , _paRefs = I.runIdentity $ do
          PM.mergeWithKeyM (\_ a b -> return (Just (domOp a b))) return return (pa1 ^. paRefs) (pa2 ^. paRefs)
      , _paRegisterRefs = PU.zipWith refSetOp (pa1 ^. paRegisterRefs) (pa2 ^. paRegisterRefs)
      }

-- | Compare two point abstractions for equality.
--
-- Note that the globals maps are converted to a list and the lists
-- are checked for equality.  This should be safe if order is
-- preserved properly in the list functions...
equalPointAbstractions :: forall blocks (dom :: CrucibleType -> *) ctx
                        . Domain dom
                       -> PointAbstraction blocks dom ctx
                       -> PointAbstraction blocks dom ctx
                       -> Bool
equalPointAbstractions dom pa1 pa2 =
  PU.foldlFC (\a (Ignore b) -> a && b) True pointwiseEqualRegs && equalGlobals
  where
    checkGlobal (PM.Pair gv1 d1) (PM.Pair gv2 d2) =
      case PM.testEquality gv1 gv2 of
        Just Refl -> domEq dom d1 d2
        Nothing -> False
    equalGlobals = and $ zipWith checkGlobal (PM.toList (pa1 ^. paGlobals)) (PM.toList (pa2 ^. paGlobals))
    pointwiseEqualRegs = PU.zipWith (\a b -> Ignore (domEq dom a b)) (pa1 ^. paRegisters) (pa2 ^. paRegisters)

-- | Apply the transfer functions from an interpretation to a block,
-- given a starting set of abstract values.
transfer :: forall dom blocks ret ctx
          . Domain dom
         -> Interpretation dom
         -> TypeRepr ret
         -> Block blocks ret ctx
         -> PointAbstraction blocks dom ctx
         -> M dom blocks ret (S.Set (Some (BlockID blocks)))
transfer dom interp retRepr blk = transferSeq 0 (_blockStmts blk)
  where
    transferSeq :: forall ctx'
                 . Int
                -> StmtSeq blocks ret ctx'
                -> PointAbstraction blocks dom ctx'
                -> M dom blocks ret (S.Set (Some (BlockID blocks)))
    transferSeq seqId (ConsStmt _loc stmt ss) =
      let mkStmtId :: forall tp . TypeRepr tp -> StmtId blocks tp
          mkStmtId typeRep = StmtId typeRep (Some (blockID blk)) seqId
      in transferSeq (seqId + 1) ss . transferStmt mkStmtId stmt
    transferSeq _ (TermStmt _loc term) = transferTerm term

    transferStmt :: forall ctx1 ctx2
                  . (forall (tp :: CrucibleType) . TypeRepr tp -> StmtId blocks tp)
                 -> Stmt ctx1 ctx2
                 -> PointAbstraction blocks dom ctx1
                 -> PointAbstraction blocks dom ctx2
    transferStmt mkStmtId s assignment =
      case s of
        SetReg tp ex ->
          let (assignment', absVal) = interpExpr interp tp ex assignment
              assignment'' = maybe assignment (joinPointAbstractions dom assignment) assignment'
          in extendRegisters absVal assignment''

        -- This statement aids in debugging the representation, but
        -- should not be a meaningful part of any analysis.  For now,
        -- skip it in the interpretation.  We could add a transfer
        -- function for it...
        --
        -- Note that this is not used to represent print statements in
        -- the language being represented.  This is a *crucible* level
        -- print.  This is actually apparent in the type of Print,
        -- which does not modify its context at all.
        Print _reg -> assignment

        CallHandle retTp funcHandle argTps actuals ->
          let actualsAbstractions = PU.zipWith (\_ act -> lookupReg act assignment) argTps actuals
              funcAbstraction = lookupReg funcHandle assignment
              (assignment', absVal) = interpCall interp argTps retTp funcHandle funcAbstraction actualsAbstractions assignment
              assignment'' = maybe assignment (joinPointAbstractions dom assignment) assignment'
          in extendRegisters absVal assignment''

        -- FIXME: This would actually potentially be nice to
        -- capture. We would need to extend the context,
        -- though... maybe with a unit type.
        Assert _ _ -> assignment

        ReadGlobal gv ->
          let (assignment', absVal) = interpReadGlobal interp gv assignment
              assignment'' = maybe assignment (joinPointAbstractions dom assignment) assignment'
          in extendRegisters absVal assignment''
        WriteGlobal gv reg ->
          let assignment' = interpWriteGlobal interp gv reg assignment
          in maybe assignment (joinPointAbstractions dom assignment) assignment'

        NewRefCell rep initValReg ->
          let initValAbst = lookupReg initValReg assignment
          in extendRegisterRefs (domBottom dom) (mkStmtId (ReferenceRepr rep)) initValAbst assignment
        ReadRefCell (Reg ix) ->
          -- Look up the set of refs that could be pointed to by this reg in
          -- _paRegisterRefs, then look up the domain values for each of those
          -- refs.  Join all of them and take the result as the domain value for
          -- this register.
          let RefSet refSet = (assignment ^. paRegisterRefs) PU.! ix
              refDomVals = [ domVal
                           | stmtid <- S.toList refSet
                           , let Just domVal = PM.lookup (RefStmtId stmtid) (_paRefs assignment)
                           ]
              regDomVal = foldr (domJoin dom) (domBottom dom) refDomVals
          in extendRegisters regDomVal assignment
        WriteRefCell (Reg ix) exprReg ->
          -- Look up the set of refs that could be pointed to by the destReg in
          -- _paRegisterRefs.  Update the values associated with those
          -- references in _paRefs with the dom value that corresponds to exprReg
          let exprAbstraction = lookupAbstractRegValue assignment exprReg
              RefSet refSet = (assignment ^. paRegisterRefs) PU.! ix
              updateAssignment stmtId = PM.insert (RefStmtId stmtId) exprAbstraction
          in assignment { _paRefs = foldr updateAssignment (_paRefs assignment) (S.toList refSet) }

    transferTerm :: forall ctx'
                  . TermStmt blocks ret ctx'
                 -> PointAbstraction blocks dom ctx'
                 -> M dom blocks ret (S.Set (Some (BlockID blocks)))
    transferTerm s assignment =
      case s of
        ErrorStmt {} -> return S.empty
        Jump target -> transferJump target assignment
        Br condReg target1 target2 -> do
          let condAbst = lookupReg condReg assignment
              (d1, d2) = interpBr interp condReg condAbst target1 target2 assignment
              d1' = maybe assignment (joinPointAbstractions dom assignment) d1
              d2' = maybe assignment (joinPointAbstractions dom assignment) d2
          s1 <- transferJump target1 d1'
          s2 <- transferJump target2 d2'
          return (S.union s1 s2)
        MaybeBranch tp mreg swTarget jmpTarget -> do
          let condAbst = lookupReg mreg assignment
              (d1, mAbstraction, d2) = interpMaybe interp tp mreg condAbst assignment
              d1' = maybe assignment (joinPointAbstractions dom assignment) d1
              d2' = maybe assignment (joinPointAbstractions dom assignment) d2
          s1 <- transferSwitch swTarget mAbstraction d1'
          s2 <- transferJump jmpTarget d2'
          return (S.union s1 s2)
        Return reg -> do
          let absVal = lookupReg reg assignment
          isRetAbstr %= domJoin dom absVal
          return S.empty

        TailCall fn callArgs actuals -> do
          let argAbstractions = PU.zipWith (\_tp act -> lookupReg act assignment) callArgs actuals
              callee = lookupReg fn assignment
              (_assignment', absVal) = interpCall interp callArgs retRepr fn callee argAbstractions assignment
              -- assignment'' = maybe assignment (joinPointAbstractions dom assignment) assignment'

          -- We don't really have a place to put a modified assignment
          -- here, which is interesting.  There is no next block...
          isRetAbstr %= domJoin dom absVal
          return S.empty

        VariantElim {} -> error "transferTerm: VariantElim terminator not supported"
        MSwitchStmt {} -> error "transferTerm: MSwitchStmt terminator not supported"


    transferJump :: forall ctx'
                  . JumpTarget blocks ctx'
                 -> PointAbstraction blocks dom ctx'
                 -> M dom blocks ret (S.Set (Some (BlockID blocks)))
    transferJump (JumpTarget target argsTps actuals) assignment = do
      let blockAbstr0 = assignment { _paRegisters = PU.zipWith (\_tp act -> lookupReg act assignment) argsTps actuals
                                   , _paRegisterRefs = PU.zipWith (\_tp act -> lookupRegRefs act assignment) argsTps actuals
                                   }
      transferTarget target blockAbstr0

    transferSwitch :: forall ctx' tp
                    . SwitchTarget blocks ctx' tp
                   -> dom tp
                   -> PointAbstraction blocks dom ctx'
                   -> M dom blocks ret (S.Set (Some (BlockID blocks)))
    transferSwitch (SwitchTarget target argTps actuals) domVal assignment = do
      let argRegAbstractions = PU.zipWith (\_ act -> lookupReg act assignment) argTps actuals
          argRegRefAbstractions = PU.zipWith (\_ act -> lookupRegRefs act assignment) argTps actuals
          blockAbstr0 = assignment { _paRegisters = PU.extend argRegAbstractions domVal
                                   , _paRegisterRefs = PU.extend argRegRefAbstractions emptyRefSet
                                   }
      transferTarget target blockAbstr0

    transferTarget :: forall ctx'
                    . BlockID blocks ctx'
                   -> PointAbstraction blocks dom ctx'
                   -> M dom blocks ret (S.Set (Some (BlockID blocks)))
    transferTarget target@(BlockID idx) assignment = do
      old <- lookupAssignment idx
      haveVisited <- isVisited target
      let new = joinPointAbstractions dom old assignment
      case haveVisited && equalPointAbstractions dom old new of
        True -> return S.empty
        False -> do
          markVisited target
          isFuncAbstr %= (faRegs %~ PU.update idx new)
          return (S.singleton (Some target))

markVisited :: BlockID blocks ctx -> M dom blocks ret ()
markVisited bid = do
  processedOnce %= S.insert (Some bid)

isVisited :: BlockID blocks ctx -> M dom blocks ret Bool
isVisited bid = do
  s <- St.gets _processedOnce
  return (Some bid `S.member` s)

-- | Compute a fixed point via abstract interpretation over a control
-- flow graph ('CFG') given 1) an interpretation + domain, 2) initial
-- assignments of domain values to global variables, and 3) initial
-- assignments of domain values to function arguments.
--
-- This is an intraprocedural analysis.  To handle function calls, the
-- transfer function for call statements must know how to supply
-- summaries or compute an appropriate conservative approximation.
--
-- There are two results from the fixed point computation:
--
-- 1) For each block in the CFG, the abstraction computed at the *entry* to the block
--
-- 2) The final abstract value for the value returned by the function
forwardFixpoint :: forall dom blocks ret init
                 . Domain dom
                -- ^ The domain of abstract values
                -> Interpretation dom
                -- ^ The transfer functions for each statement type
                -> CFG blocks init ret
                -- ^ The function to analyze
                -> PM.MapF GlobalVar dom
                -- ^ Assignments of abstract values to global variables at the function start
                -> PU.Assignment dom init
                -- ^ Assignments of abstract values to the function arguments
                -> (PU.Assignment (PointAbstraction blocks dom) blocks, dom ret)
forwardFixpoint dom interp cfg globals0 assignment0 =
  let BlockID idx = cfgEntryBlockID cfg
      pa0 = PointAbstraction { _paGlobals = globals0
                             , _paRegisters = assignment0
                             , _paRefs = PM.empty
                             , _paRegisterRefs = PU.fmapFC (const emptyRefSet) assignment0
                             }
      freshAssignment :: PU.Index blocks ctx -> PointAbstraction blocks dom ctx
      freshAssignment i =
        PointAbstraction { _paRegisters = PU.fmapFC (const (domBottom dom)) (blockInputs (getBlock (BlockID i) (cfgBlockMap cfg)))
                         , _paRegisterRefs = PU.fmapFC (const emptyRefSet) (blockInputs (getBlock (BlockID i) (cfgBlockMap cfg)))
                         , _paGlobals = PM.empty
                         , _paRefs = PM.empty
                         }
      s0 = IterationState { _isRetAbstr = domBottom dom
                          , _isFuncAbstr =
                            FunctionAbstraction { _faRegs = PU.update idx pa0 $ PU.generate (PU.size (cfgBlockMap cfg)) freshAssignment
                                                , _faRet = domBottom dom
                                                }
                          , _processedOnce = S.empty
                          }
      iterStrat = iterationStrategy dom
      abstr' = St.execState (runM (iterStrat interp cfg)) s0
  in (_faRegs (_isFuncAbstr abstr'), _isRetAbstr abstr')

-- | Inspect the 'Domain' definition to determine which iteration
-- strategy the caller requested.
iterationStrategy :: Domain dom -> (Interpretation dom -> CFG blocks init ret -> M dom blocks ret ())
iterationStrategy dom =
  case domIter dom of
    WTOWidening s op -> wtoIteration (Just (WideningStrategy s, WideningOperator op)) dom
    WTO -> wtoIteration Nothing dom
    Worklist -> worklistIteration dom

-- | Iterate over blocks using a worklist (i.e., after a block is
-- processed and abstract values change, put the block successors on
-- the worklist).
--
-- The worklist is actually processed by taking the lowest-numbered
-- block in a set as the next work item.
worklistIteration :: forall dom blocks ret init
                   . Domain dom
                  -> Interpretation dom
                  -> CFG blocks init ret
                  -> M dom blocks ret ()
worklistIteration dom interp cfg =
  loop (S.singleton (Some (cfgEntryBlockID cfg)))
  where
    loop worklist =
      case S.minView worklist of
        Nothing -> return ()
        Just (Some target@(BlockID idx), worklist') -> do
          assignment <- lookupAssignment idx
          visit (getBlock target (cfgBlockMap cfg)) assignment worklist'

    visit :: Block blocks ret ctx
          -> PointAbstraction blocks dom ctx
          -> S.Set (Some (BlockID blocks))
          -> M dom blocks ret ()
    visit blk startingAssignment worklist' = do
      s <- transfer dom interp (cfgReturnType cfg) blk startingAssignment
      loop (S.union s worklist')

-- | Iterate over the blocks in the control flow graph in weak
-- topological order until a fixed point is reached.
--
-- The weak topological order essentially formalizes the idea of
-- breaking the graph on back edges and putting the result in
-- topological order.  The blocks that serve as loop heads are the
-- heads of their respective strongly connected components.  Those
-- block heads are suitable locations to apply widening operators
-- (which can be provided to this iterator).
wtoIteration :: forall dom blocks ret init
              . Maybe (WideningStrategy, WideningOperator dom)
              -- ^ An optional widening operator
             -> Domain dom
             -> Interpretation dom
             -> CFG blocks init ret
             -> M dom blocks ret ()
wtoIteration mWiden dom interp cfg = loop (computeOrdering cfg)
  where
    loop [] = return ()
    loop (Vertex (Some bid@(BlockID idx)) : rest) = do
      assignment <- lookupAssignment idx
      let blk = getBlock bid (cfgBlockMap cfg)
      _ <- transfer dom interp (cfgReturnType cfg) blk assignment
      loop rest
    loop (SCC { wtoHead = hbid, wtoComps = comps } : rest) = do
      processSCC hbid comps 0
      loop rest

    -- Process a single SCC until the input to the head node of the
    -- SCC stabilizes.  Applies widening if requested.
    processSCC (Some hbid@(BlockID idx)) comps iterNum = do
      headInput0 <- lookupAssignment idx
      -- We process the SCC until the input to the head of the SCC stabilizes
      let headBlock = getBlock hbid (cfgBlockMap cfg)
      _ <- transfer dom interp (cfgReturnType cfg) headBlock headInput0
      loop comps
      headInput1 <- lookupAssignment idx
      case equalPointAbstractions dom headInput0 headInput1 of
        True -> return ()
        False -> do
          case mWiden of
            Just (WideningStrategy strat, WideningOperator widen)
              | strat iterNum -> do
                  let headInputW = zipPAWith widen unionRefSets headInput0 headInput1
                  isFuncAbstr %= (faRegs %~ PU.update idx headInputW)
            _ -> return ()
          processSCC (Some hbid) comps (iterNum + 1)

-- | Compute a weak topological order for the wto fixpoint iteration
computeOrdering :: CFG blocks init ret
                -> [WTOComponent (Some (BlockID blocks))]
computeOrdering cfg = weakTopologicalOrdering successors (Some block0)
  where
    block0 = cfgEntryBlockID cfg
    successors (Some bid) = nextBlocks (getBlock bid (cfgBlockMap cfg))

lookupAssignment :: forall dom blocks ret tp
                  . PU.Index blocks tp
                 -> M dom blocks ret (PointAbstraction blocks dom tp)
lookupAssignment idx = do
  abstr <- St.get
  return ((abstr ^. isFuncAbstr . faRegs) PU.! idx)

lookupReg :: Reg ctx tp -> PointAbstraction blocks dom ctx -> dom tp
lookupReg reg assignment = (assignment ^. paRegisters) PU.! regIndex reg

lookupRegRefs :: Reg ctx tp -> PointAbstraction blocks dom ctx -> RefSet blocks tp
lookupRegRefs reg assignment = (assignment ^. paRegisterRefs) PU.! regIndex reg

newtype Ignore a (b::k) = Ignore { _ignoreOut :: a }
 deriving (Eq, Ord, Show)

instance Show a => ShowF (Ignore a) where
  showF (Ignore x) = show x

-- Lenses

paGlobals :: (Functor f)
          => (PM.MapF GlobalVar dom -> f (PM.MapF GlobalVar dom))
          -> PointAbstraction blocks dom ctx
          -> f (PointAbstraction blocks dom ctx)
paGlobals f pa = (\a -> pa { _paGlobals = a }) <$> f (_paGlobals pa)

paRegisters :: (Functor f)
            => (PU.Assignment dom ctx -> f (PU.Assignment dom ctx))
            -> PointAbstraction blocks dom ctx
            -> f (PointAbstraction blocks dom ctx)
paRegisters f pa = (\a -> pa { _paRegisters = a }) <$> f (_paRegisters pa)

paRegisterRefs :: (Functor f)
               => (PU.Assignment (RefSet blocks) ctx -> f (PU.Assignment (RefSet blocks) ctx))
               -> PointAbstraction blocks dom ctx
               -> f (PointAbstraction blocks dom ctx)
paRegisterRefs f pa = (\a -> pa { _paRegisterRefs = a }) <$> f (_paRegisterRefs pa)

paRefs :: (Functor f)
       => (PM.MapF (RefStmtId blocks) dom -> f (PM.MapF (RefStmtId blocks) dom))
       -> PointAbstraction blocks dom ctx
       -> f (PointAbstraction blocks dom ctx)
paRefs f pa = (\a -> pa { _paRefs = a }) <$> f (_paRefs pa)

faRegs :: (Functor f)
       => (PU.Assignment (PointAbstraction blocks dom) blocks -> f (PU.Assignment (PointAbstraction blocks dom) blocks))
       -> FunctionAbstraction dom blocks ret
       -> f (FunctionAbstraction dom blocks ret)
faRegs f fa = (\a -> fa { _faRegs = a }) <$> f (_faRegs fa)

isFuncAbstr :: (Functor f)
            => (FunctionAbstraction dom blocks ret -> f (FunctionAbstraction dom blocks ret))
            -> IterationState dom blocks ret
            -> f (IterationState dom blocks ret)
isFuncAbstr f is = (\a -> is { _isFuncAbstr = a }) <$> f (_isFuncAbstr is)

isRetAbstr :: (Functor f) => (dom ret -> f (dom ret)) -> IterationState dom blocks ret -> f (IterationState dom blocks ret)
isRetAbstr f is = (\a -> is { _isRetAbstr = a }) <$> f (_isRetAbstr is)

processedOnce :: (Functor f)
              => (S.Set (Some (BlockID blocks)) -> f (S.Set (Some (BlockID blocks))))
              -> IterationState dom blocks ret
              -> f (IterationState dom blocks ret)
processedOnce f is = (\a -> is { _processedOnce = a}) <$> f (_processedOnce is)

-- $pointed
--
-- The 'Pointed' type is a wrapper around another 'Domain' that
-- provides distinguished 'Top' and 'Bottom' elements.  Use of this
-- type is never required (domains can always define their own top and
-- bottom), but this1 wrapper can save some boring boilerplate.

-- | The Pointed wrapper that adds Top and Bottom elements
data Pointed dom (tp :: CrucibleType) where
  Top :: Pointed a tp
  Pointed :: dom tp -> Pointed dom tp
  Bottom :: Pointed dom tp

deriving instance (Eq (dom tp)) => Eq (Pointed dom tp)

instance ShowF dom => Show (Pointed dom tp) where
  show Top = "Top"
  show Bottom = "Bottom"
  show (Pointed p) = showF p

instance ShowF dom => ShowF (Pointed dom)

-- | Construct a 'Pointed' 'Domain' from a pointed join function and
-- an equality test.
pointed :: (forall tp . dom tp -> dom tp -> Pointed dom tp)
        -- ^ Join of contained domain elements
        -> (forall tp . dom tp -> dom tp -> Bool)
        -- ^ Equality for domain elements
        -> Domain (Pointed dom)
pointed j eq =
  Domain { domTop = Top
         , domBottom = Bottom
         , domJoin = pointedJoin j
         , domEq = pointedEq eq
         , domIter = WTO
         }

  where
    pointedJoin _ Top _ = Top
    pointedJoin _ _ Top = Top
    pointedJoin _ Bottom a = a
    pointedJoin _ a Bottom = a
    pointedJoin j' (Pointed p1) (Pointed p2) = j' p1 p2

    pointedEq _ Top Top = True
    pointedEq _ Bottom Bottom = True
    pointedEq eq' (Pointed p1) (Pointed p2) = eq' p1 p2
    pointedEq _ _ _ = False
