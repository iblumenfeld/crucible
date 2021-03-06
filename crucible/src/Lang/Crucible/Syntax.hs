-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.Syntax
-- Description      : Provides a typeclass and methods for constructing
--                    AST expressions.
-- Copyright        : (c) Galois, Inc 2014
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This module provides typeclasses and combinators for constructing AST
-- expressions.
------------------------------------------------------------------------
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternGuards #-}
module Lang.Crucible.Syntax
  ( IsExpr(..)
    -- * Booleans
  , true
  , false
  , notExpr
  , (.&&)
  , (.||)
    -- * Expression classes
  , EqExpr(..)
  , OrdExpr(..)
  , NumExpr(..)
  , LitExpr(..)
    -- * Natural numbers
  , ConvertableToNat(..)
    -- * Real numbers
  , rationalLit
  , natToReal
  , integerToReal
    -- * Complex real numbers
  , realToCplx
  , imagToCplx
  , realPart
  , imagPart
  , realLit
  , imagLit
  , natToCplx
    -- MatlabChar
    -- String
    -- * Maybe
  , nothingValue
  , justValue
    -- * Vector
  , vectorSize
  , vectorLit
  , vectorGetEntry
  , vectorSetEntry
  , vectorIsEmpty
  , vecReplicate
    -- * Function handles
  , closure
    -- * IdentValueMap
  , emptyIdentValueMap
  , setIdentValue

  -- * Structs
  , mkStruct
  , getStruct
  , setStruct

  -- * Multibyte operations
  , concatExprs
  , bigEndianLoad
  , bigEndianLoadDef
  , bigEndianStore
  , littleEndianLoad
  , littleEndianLoadDef
  , littleEndianStore
  ) where

import           Data.Text (Text)
import           Data.Typeable
import qualified Data.Vector as V

import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Some
import           Numeric.Natural

import           Lang.MATLAB.MatlabChar

import           Lang.Crucible.CFG.Expr
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.Types

------------------------------------------------------------------------
-- IsExpr

-- | A typeclass for injecting applications into expressions.
class IsExpr e where
  app   :: App e tp -> e tp
  asApp :: e tp -> Maybe (App e tp)

------------------------------------------------------------------------
-- LitExpr

-- | An expression that embeds literal values of its type.
class LitExpr tp ty | tp -> ty where
  litExpr :: IsExpr e => ty -> e tp

instance (Typeable a, Eq a, Ord a, Show a) => LitExpr (ConcreteType a) a where
  litExpr x = app (ConcreteLit (TypeableValue x))

------------------------------------------------------------------------
-- Booleans

instance LitExpr BoolType Bool where
  litExpr b = app (BoolLit b)

-- | True expression
true :: IsExpr e => e BoolType
true = litExpr True

-- | False expression
false :: IsExpr e => e BoolType
false = litExpr False

notExpr :: IsExpr e => e BoolType -> e BoolType
notExpr x = app (Not x)

(.&&) :: IsExpr e => e BoolType -> e BoolType -> e BoolType
(.&&) x y = app (And x y)

(.||) :: IsExpr e => e BoolType -> e BoolType -> e BoolType
(.||) x y = app (Or x y)

infixr 3 .&&
infixr 2 .||

------------------------------------------------------------------------
-- EqExpr

class EqExpr tp where
  (.==) :: IsExpr e => e tp -> e tp -> e BoolType

  (./=) :: IsExpr e => e tp -> e tp -> e BoolType
  x ./= y = notExpr (x .== y)

infix 4 .==
infix 4 ./=

------------------------------------------------------------------------
-- OrdExpr

class EqExpr tp => OrdExpr tp where
  (.<) :: IsExpr e => e tp -> e tp -> e BoolType

  (.<=) :: IsExpr e => e tp -> e tp -> e BoolType
  x .<= y = notExpr (y .< x)

  (.>) :: IsExpr e => e tp -> e tp -> e BoolType
  x .> y = y .< x

  (.>=) :: IsExpr e => e tp -> e tp -> e BoolType
  x .>= y = y .<= x

infix 4 .<
infix 4 .<=
infix 4 .>
infix 4 .>=

------------------------------------------------------------------------
-- NumExpr

class NumExpr tp where
  (.+) :: IsExpr e => e tp -> e tp -> e tp
  (.-) :: IsExpr e => e tp -> e tp -> e tp
  (.*) :: IsExpr e => e tp -> e tp -> e tp

------------------------------------------------------------------------
-- Nat

instance LitExpr NatType Natural where
  litExpr n = app (NatLit n)

instance EqExpr NatType where
  x .== y = app (NatEq x y)

instance OrdExpr NatType where
  x .< y = app (NatLt x y)

instance NumExpr NatType where
  x .+ y = app (NatAdd x y)
  x .- y = app (NatSub x y)
  x .* y = app (NatMul x y)

------------------------------------------------------------------------
-- Integer

instance LitExpr IntegerType Integer where
  litExpr x = app (IntLit x)

------------------------------------------------------------------------
-- ConvertableToNat

class ConvertableToNat tp where
  -- | Convert value of type to Nat.
  -- This may be partial, it is the responsibility of the calling
  -- code that it is correct for this type.
  toNat :: IsExpr e => e tp -> e NatType

------------------------------------------------------------------------
-- RealValType

rationalLit :: IsExpr e => Rational -> e RealValType
rationalLit v = app (RationalLit v)

instance EqExpr RealValType where
  x .== y = app (RealEq x y)

instance OrdExpr RealValType where
  x .< y = app (RealLt x y)

natToInteger :: IsExpr e => e NatType -> e IntegerType
natToInteger x = app (NatToInteger x)

integerToReal :: IsExpr e => e IntegerType -> e RealValType
integerToReal x = app (IntegerToReal x)

natToReal :: IsExpr e => e NatType -> e RealValType
natToReal = integerToReal . natToInteger

instance ConvertableToNat RealValType where
  toNat v = app (RealToNat v)

------------------------------------------------------------------------
-- ComplexRealType

realToCplx :: IsExpr e => e RealValType -> e ComplexRealType
realToCplx v = app (Complex v (rationalLit 0))

imagToCplx :: IsExpr e => e RealValType -> e ComplexRealType
imagToCplx v = app (Complex (rationalLit 0) v)

realPart :: IsExpr e => e ComplexRealType -> e RealValType
realPart c = app (RealPart c)

imagPart :: IsExpr e => e ComplexRealType -> e RealValType
imagPart c = app (ImagPart c)

realLit :: IsExpr e => Rational -> e ComplexRealType
realLit = realToCplx . rationalLit

imagLit :: IsExpr e => Rational -> e ComplexRealType
imagLit = imagToCplx . rationalLit

natToCplx :: IsExpr e => e NatType -> e ComplexRealType
natToCplx = realToCplx . natToReal

instance ConvertableToNat ComplexRealType where
  toNat = toNat . realPart

------------------------------------------------------------------------
-- MatlabChar

instance LitExpr CharType MatlabChar where
  litExpr n = app (MatlabCharLit n)

instance EqExpr CharType where
  x .== y = app (MatlabCharEq x y)

instance ConvertableToNat CharType where
  toNat v = app (MatlabCharToNat v)

------------------------------------------------------------------------
-- String

instance LitExpr StringType Text where
  litExpr t = app (TextLit t)

------------------------------------------------------------------------
-- Maybe

nothingValue :: (IsExpr e, KnownRepr TypeRepr tp) => e (MaybeType tp)
nothingValue = app (NothingValue knownRepr)

justValue :: (IsExpr e, KnownRepr TypeRepr tp) => e tp -> e (MaybeType tp)
justValue x = app (JustValue knownRepr x)

------------------------------------------------------------------------
-- Vector

vectorSize :: (IsExpr e) => e (VectorType tp) -> e NatType
vectorSize v = app (VectorSize v)

vectorIsEmpty :: (IsExpr e) => e (VectorType tp) -> e BoolType
vectorIsEmpty v = app (VectorIsEmpty v)

vectorLit :: (IsExpr e) => TypeRepr tp -> V.Vector (e tp) -> e (VectorType tp)
vectorLit tp v = app (VectorLit tp v)

-- | Get the entry from a zero-based index.
vectorGetEntry :: (IsExpr e, KnownRepr TypeRepr tp) => e (VectorType tp) -> e NatType -> e tp
vectorGetEntry v i = app (VectorGetEntry knownRepr v i)

vectorSetEntry :: (IsExpr e, KnownRepr TypeRepr tp )
               => e (VectorType tp)
               -> e NatType
               -> e tp
               -> e (VectorType tp)
vectorSetEntry v i x = app (VectorSetEntry knownRepr v i x)

vecReplicate :: (IsExpr e, KnownRepr TypeRepr tp) => e NatType -> e tp -> e (VectorType tp)
vecReplicate n v = app (VectorReplicate knownRepr n v)

------------------------------------------------------------------------
-- Handles

instance LitExpr (FunctionHandleType args ret) (FnHandle args ret) where
  litExpr h = app (HandleLit h)

closure :: ( IsExpr e
           , KnownRepr TypeRepr tp
           , KnownRepr TypeRepr ret
           , KnownCtx  TypeRepr args
           )
        => e (FunctionHandleType (args::>tp) ret)
        -> e tp
        -> e (FunctionHandleType args ret)
closure h a = app (Closure knownRepr knownRepr h knownRepr a)


----------------------------------------------------------------------
-- IdentValueMap

-- | Initialize the ident value map to the given value.
emptyIdentValueMap :: KnownRepr TypeRepr tp => IsExpr e => e (StringMapType tp)
emptyIdentValueMap = app (EmptyStringMap knownRepr)

-- Update the value of the ident value map with the given value.
setIdentValue :: (IsExpr e, KnownRepr TypeRepr tp)
              => e (StringMapType tp)
              -> Text
              -> e (MaybeType tp)
              -> e (StringMapType tp)
setIdentValue m i v = app (InsertStringMapEntry knownRepr m (litExpr i) v)

-----------------------------------------------------------------------
-- Struct

mkStruct :: IsExpr e
         => CtxRepr ctx
         -> Ctx.Assignment e ctx
         -> e (StructType ctx)
mkStruct tps asgn = app (MkStruct tps asgn)

getStruct :: (IsExpr e)
          => Ctx.Index ctx tp
          -> e (StructType ctx)
          -> TypeRepr tp
          -> e tp
getStruct i s tp
  | Just (MkStruct _ asgn) <- asApp s = asgn Ctx.! i
  | Just (SetStruct _ s' i' x) <- asApp s =
      case testEquality i i' of
        Just Refl -> x
        Nothing -> getStruct i s' tp
  | otherwise = app (GetStruct s i tp)

setStruct :: IsExpr e
          => CtxRepr ctx
          -> e (StructType ctx)
          -> Ctx.Index ctx tp
          -> e tp
          -> e (StructType ctx)
setStruct tps s i x
  | Just (MkStruct _ asgn) <- asApp s = app (MkStruct tps (Ctx.update i x asgn))
  | otherwise = app (SetStruct tps s i x)



-------------------------------------------------------
-- Multibyte operations

bigEndianStore
   :: (IsExpr expr, 1 <= addrWidth, 1 <= valWidth, 1 <= cellWidth)
   => NatRepr addrWidth
   -> NatRepr cellWidth
   -> NatRepr valWidth
   -> Int -- ^ number of bytes to write
   -> expr (BVType addrWidth)
   -> expr (BVType valWidth)
   -> expr (WordMapType addrWidth (BaseBVType cellWidth))
   -> expr (WordMapType addrWidth (BaseBVType cellWidth))
bigEndianStore addrWidth cellWidth valWidth num basePtr v wordMap = go num
  where go 0 = wordMap
        go n
          | Just (Some idx) <- someNat $ (toInteger (num-n)) * (toInteger (natValue cellWidth))
          , Just LeqProof <- testLeq (addNat idx cellWidth) valWidth
            = app $ InsertWordMap addrWidth (BaseBVRepr cellWidth)
                  (app $ BVAdd addrWidth basePtr (app $ BVLit addrWidth (toInteger (n-1))))
                  (app $ BVSelect idx cellWidth valWidth v)
                  (go (n-1))
        go _ = error "bad size parameters in bigEndianStore!"

littleEndianStore
   :: (IsExpr expr, 1 <= addrWidth, 1 <= valWidth, 1 <= cellWidth)
   => NatRepr addrWidth
   -> NatRepr cellWidth
   -> NatRepr valWidth
   -> Int -- ^ number of bytes to write
   -> expr (BVType addrWidth)
   -> expr (BVType valWidth)
   -> expr (WordMapType addrWidth (BaseBVType cellWidth))
   -> expr (WordMapType addrWidth (BaseBVType cellWidth))
littleEndianStore addrWidth cellWidth valWidth num basePtr v wordMap = go num
  where go 0 = wordMap
        go n
          | Just (Some idx) <- someNat $ (toInteger (n-1)) * (toInteger (natValue cellWidth))
          , Just LeqProof <- testLeq (addNat idx cellWidth) valWidth
            = app $ InsertWordMap addrWidth (BaseBVRepr cellWidth)
                  (app $ BVAdd addrWidth basePtr (app $ BVLit addrWidth (toInteger (n-1))))
                  (app $ BVSelect idx cellWidth valWidth v)
                  (go (n-1))
        go _ = error "bad size parameters in littleEndianStore!"

concatExprs :: forall w a expr
            .  (IsExpr expr, 1 <= w)
            => NatRepr w
            -> [expr (BVType w)]
            -> (forall w'. (1 <= w') => NatRepr w' -> expr (BVType w') -> a)
            -> a

concatExprs _ [] = \_ -> error "Cannot concatenate 0 elements together"
concatExprs w (a:as) = go a as

 where go :: (1 <= w)
          => expr (BVType w)
          -> [expr (BVType w)]
          -> (forall w'. (1 <= w') => NatRepr w' -> expr (BVType w') -> a)
          -> a
       go x0 [] k     = k w x0
       go x0 (x:xs) k = go x xs (\(w'::NatRepr w') z ->
            withLeqProof (leqAdd LeqProof w' :: LeqProof 1 (w+w'))
              (k (addNat w w') (app $ BVConcat w w' x0 z)))

bigEndianLoad
   :: (IsExpr expr, 1 <= addrWidth, 1 <= valWidth, 1 <= cellWidth)
   => NatRepr addrWidth
   -> NatRepr cellWidth
   -> NatRepr valWidth
   -> Int -- ^ number of bytes to load
   -> expr (BVType addrWidth)
   -> expr (WordMapType addrWidth (BaseBVType cellWidth))
   -> expr (BVType valWidth)
bigEndianLoad addrWidth cellWidth valWidth num basePtr wordMap =
          let segs = [ app $ LookupWordMap (BaseBVRepr cellWidth)
                            (app $ BVAdd addrWidth basePtr
                                     (app $ BVLit addrWidth (toInteger i)))
                            wordMap
                     | i <- [0 .. num-1]
                     ] in
          concatExprs cellWidth segs $ \w x ->
            case testEquality w valWidth of
              Just Refl -> x
              Nothing -> error "bad size parameters in bigEndianLoad!"


bigEndianLoadDef
   :: (IsExpr expr, 1 <= addrWidth, 1 <= valWidth, 1 <= cellWidth)
   => NatRepr addrWidth
   -> NatRepr cellWidth
   -> NatRepr valWidth
   -> Int -- ^ number of bytes to load
   -> expr (BVType addrWidth)
   -> expr (WordMapType addrWidth (BaseBVType cellWidth))
   -> expr (BVType cellWidth)
   -> expr (BVType valWidth)
bigEndianLoadDef addrWidth cellWidth valWidth num basePtr wordMap defVal =
          let segs = [ app $ LookupWordMapWithDefault (BaseBVRepr cellWidth)
                            (app $ BVAdd addrWidth basePtr
                                      (app $ BVLit addrWidth (toInteger i)))
                            wordMap
                            defVal
                     | i <- [0 .. num-1]
                     ] in
          concatExprs cellWidth segs $ \w x ->
            case testEquality w valWidth of
              Just Refl -> x
              Nothing -> error "bad size parameters in bigEndianLoadDef!"

littleEndianLoad
   :: (IsExpr expr, 1 <= addrWidth, 1 <= valWidth, 1 <= cellWidth)
   => NatRepr addrWidth
   -> NatRepr cellWidth
   -> NatRepr valWidth
   -> Int -- ^ number of bytes to load
   -> expr (BVType addrWidth)
   -> expr (WordMapType addrWidth (BaseBVType cellWidth))
   -> expr (BVType valWidth)
littleEndianLoad addrWidth cellWidth valWidth num basePtr wordMap =
          let segs = [ app $ LookupWordMap (BaseBVRepr cellWidth)
                            (app $ BVAdd addrWidth basePtr
                                   (app $ BVLit addrWidth (toInteger i)))
                            wordMap
                     | i <- reverse [0 .. num-1]
                     ] in
          concatExprs cellWidth segs $ \w x ->
            case testEquality w valWidth of
              Just Refl -> x
              Nothing -> error "bad size parameters in littleEndianLoad!"

littleEndianLoadDef
   :: (IsExpr expr, 1 <= addrWidth, 1 <= valWidth, 1 <= cellWidth)
   => NatRepr addrWidth
   -> NatRepr cellWidth
   -> NatRepr valWidth
   -> Int -- ^ number of bytes to load
   -> expr (BVType addrWidth)
   -> expr (WordMapType addrWidth (BaseBVType cellWidth))
   -> expr (BVType cellWidth)
   -> expr (BVType valWidth)
littleEndianLoadDef addrWidth cellWidth valWidth num basePtr wordMap defVal =
          let segs = [ app $ LookupWordMapWithDefault (BaseBVRepr cellWidth)
                            (app $ BVAdd addrWidth basePtr
                                      (app $ BVLit addrWidth (toInteger i)))
                            wordMap
                            defVal
                     | i <- reverse [0 .. num-1]
                     ] in
          concatExprs cellWidth segs $ \w x ->
            case testEquality w valWidth of
              Just Refl -> x
              Nothing -> error "bad size parameters in littleEndianLoadDef!"
