Crucible is a language-agnostic library for performing forward
symbolic execution of imperative programs.  It provides a collection of
data-structures and APIs for expressing programs as control-flow
graphs.  Programs expressed as CFGs in this way can be automatically
explored by the symbolic execution engine.  In addition, new data
types and operations can be added to the symbolic simulator by
implementing fresh primitives directly in Haskell.  Crucible also
provides connections to a variety of SAT and SMT solvers that can be
used to perform verification and find counterexamples to logical
conditions computed from program simulation.

Crucible has been designed as a set of Haskell packages organized so that Crucible
itself has a minimal number of external dependencies, and functionality
independent of crucible can be separated into sub-libraries.

Currently, the repo consists of the following Haskell packages:

 * **`crucible`** provides the core Crucible definitions, the
   symbolic simulator, the `SimpleBackend` formula representation, interfaces
   between `SimpleBackend` and SMT solvers, and an LLVM-to-Crucible translator.
 * **`crucible-abc`** provides functionality for generating
   ABC networks from `SimpleBackend` expressions.
 * **`crucible-blt`** provides functionality for generating
   BLT problems from `SimpleBackend` expressions.
 * **`crucible-saw`** provides functionality for generating
   SAW Core terms from Crucible Control-Flow-Graphs.
 * **`galois-matlab`** provides a few data structures for working with
   MATLAB values.

In addition, there is the following library/executable package:

 * **`crucible-server`**, a standalone process that allows constructing
   and symbolically executing Crucible programs via [Protocol Buffers][pb].
   The crucible-server directory also contains a Java API for
   connecting to and working with the `crucible-server`.

[pb]: https://developers.google.com/protocol-buffers/ "Protocol Buffers"


The development of major features and additions to `crucible` is done in separate branches of the repository, all of which are based off `master` and merge back into it when completed. Minor features and bug fixes are done in the `master` branch. Naming of feature branches is free-form.

To use `stack` to build crucible, you can use the shell script
`scripts/build-sandbox.sh` to retrieve the appropriate repos for
building.

Each library is BSD-licensed (see the `LICENSE` file in a project directory for details).