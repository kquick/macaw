This is the main repository for the Macaw binary analysis framework.
This framework is implemented to offer extensible support for
architectures.

# Overview

The main algorithm implemented so far is a code discovery procedure
which will discover reachable code in the binary given one or more
entry points such as `_start` or the current symbols.

The Macaw libraries are:

* macaw-base -- The core architecture-independent operations and
  algorithms.
* macaw-symbolic -- Library that provides symbolic simulation of Macaw
  programs via Crucible.
* macaw-x86 -- Provides definitions enabling Macaw to be used on
  X86_64 programs.
* macaw-x86-symbolic -- Adds Macaw-symbolic extensions needed to
  support x86.
* macaw-semmc -- Contains the architecture-independent components of
  the translation from semmc semantics into macaw IR.  This provides
  the shared infrastructure for all of our backends; this will include
  the Template Haskell function to create a state transformer function
  from learned semantics files provided by the _semmc_ library.
* macaw-arm -- Enables macaw for ARM (32-bit) binaries by reading the
  semantics files generated by _semmc_ and using Template Haskell to
  generate a function that transforms machine states according to the
  learned semantics.
* macaw-arm-symbolic -- Enables macaw/crucible symbolic simulation for
  ARM (32-bit) architectures.
* macaw-ppc -- Enables macaw for PPC (32-bit and 64-bit) binaries by reading the
  semantics files generated by _semmc_ and using Template Haskell to
  generate a function that transforms machine states according to the
  learned semantics..
* macaw-ppc-symbolic -- Enables macaw/crucible symbolic simulation for
  PPC architectures
* macaw-refinement -- Enables additional architecture-independent
  refinement of code discovery.  This can enable discovery of more
  functionality than is revealed by the analysis in macaw-base.

The libraries that make up Macaw are released under the BSD license.

These Macaw core libraries depend on a number of different supporting libraries, including:

* elf-edit -- loading and parsing of ELF binary files
* galois-dwarf -- retrieval of Dwarf debugging information from binary files
* flexdis86 -- disassembly and semantics for x86 architectures
* dismantle -- disassembly for ARM and PPC architectures
* semmc -- semantics definitions for ARM and PPC architectures
* crucible -- Symbolic execution and analysis
* what4 -- Symbolic representation for the crucible backend
* parameterized-utils -- utilities for working with parameterized types

# Building

## Preparation

Dependencies for building Macaw that are not obtained from Hackage are
supported via Git submodules:

    $ git submodule update --init


## Building with Cabal

The Macaw libraries can be individually built with Cabal v1, but as a
group and more easily with Cabal v2:

    $ ln -s cabal.project.dist cabal.project
    $ cabal v2-configure
    $ cabal v2-build all

To build a single library, either specify that library name instaed of
`all`, or change to that library's subdirectory before building:

    $ cabal v2-build macaw-refinement

 or

    $ cd refinement
    $ cabal v2-build

## Building with Stack

To build with Stack, first create a top-level `stack.yaml` file by
symlinking to one of the provided `stack-ghc-<version>.yaml`
files. E.g.

    $ ln -s stack-ghc-8.6.3.yaml stack.yaml
    $ stack build

# Status

This codebase is a work in progress.  Support for PowerPC support
(both 32 and 64 bit) and X86_64 is reasonably robust.  Support for ARM
is ongoing.

# Notes on Freeze Files

We use the `cabal.project.freeze.ghc-*` files to constrain dependency versions
in CI. We recommand using the following command for best results before building
locally:

```
ln -s cabal.GHC-<VER>.config cabal.project.freeze
```

These freeze files were generated using the `.github/update-freeze` script.
Note that at present, these configuration files assume a Unix-like operating
system, as we do not currently test Windows on CI. If you would like to use
these configuration files on Windows, you will need to make some manual changes
to remove certain packages and flags:

```
regex-posix
tasty +unix
unix
unix-compat
```

# License

This code is made available under the BSD3 license and without any support.
