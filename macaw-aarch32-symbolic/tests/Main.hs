{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ElfEdit as Elf
import qualified Data.Foldable as F
import           Data.Maybe ( mapMaybe )
import qualified Data.Parameterized.Classes as PC
import qualified Data.Parameterized.Nonce as PN
import           Data.Parameterized.Some ( Some(..) )
import           Data.Proxy ( Proxy(..) )
import qualified Prettyprinter as PP
import           System.FilePath ( (</>), (<.>) )
import qualified System.FilePath.Glob as SFG
import qualified System.IO as IO
import qualified Test.Tasty as TT
import qualified Test.Tasty.HUnit as TTH
import qualified Test.Tasty.Options as TTO
import qualified Test.Tasty.Runners as TTR

import qualified Language.ASL.Globals as ASL
import qualified Data.Macaw.Architecture.Info as MAI

import           Data.Macaw.AArch32.Symbolic ()
import qualified Data.Macaw.ARM as MA
import qualified Data.Macaw.ARM.ARMReg as MAR
import qualified Data.Macaw.CFG as MC
import qualified Data.Macaw.Discovery as M
import qualified Data.Macaw.Symbolic as MS
import qualified Data.Macaw.Symbolic.Testing as MST
import qualified What4.Config as WC
import qualified What4.Interface as WI
import qualified What4.ProblemFeatures as WPF
import qualified What4.Solver as WS

import qualified Lang.Crucible.Backend as CB
import qualified Lang.Crucible.Backend.Online as CBO
import qualified Lang.Crucible.Simulator as CS
import qualified Lang.Crucible.LLVM.MemModel as LLVM

-- | A Tasty option to tell us to save SMT queries and responses to /tmp for debugging purposes
data SaveSMT = SaveSMT Bool
  deriving (Eq, Show)

instance TTO.IsOption SaveSMT where
  defaultValue = SaveSMT False
  parseValue v = SaveSMT <$> TTO.safeReadBool v
  optionName = pure "save-smt"
  optionHelp = pure "Save SMT sessions to files in /tmp for debugging"

-- | A tasty option to have the test suite save the macaw IR for each test case to /tmp for debugging purposes
data SaveMacaw = SaveMacaw Bool

instance TTO.IsOption SaveMacaw where
  defaultValue = SaveMacaw False
  parseValue v = SaveMacaw <$> TTO.safeReadBool v
  optionName = pure "save-macaw"
  optionHelp = pure "Save Macaw IR for each test case to /tmp for debugging"

ingredients :: [TTR.Ingredient]
ingredients = TT.includingOptions [ TTO.Option (Proxy @SaveSMT)
                                  , TTO.Option (Proxy @SaveMacaw)
                                  ] : TT.defaultIngredients

main :: IO ()
main = do
  -- These are pass/fail in that the assertions in the "pass" set are true (and
  -- the solver returns Unsat), while the assertions in the "fail" set are false
  -- (and the solver returns Sat).
  passTestFilePaths <- SFG.glob "tests/pass/*.exe"
  failTestFilePaths <- SFG.glob "tests/fail/*.exe"
  let passRes = MST.SimulationResult MST.Unsat
  let failRes = MST.SimulationResult MST.Sat
  let passTests = TT.testGroup "True assertions" (map (mkSymExTest passRes) passTestFilePaths)
  let failTests = TT.testGroup "False assertions" (map (mkSymExTest failRes) failTestFilePaths)
  TT.defaultMainWithIngredients ingredients (TT.testGroup "Binary Tests" [passTests, failTests])

hasTestPrefix :: Some (M.DiscoveryFunInfo arch) -> Maybe (BS8.ByteString, Some (M.DiscoveryFunInfo arch))
hasTestPrefix (Some dfi) = do
  bsname <- M.discoveredFunSymbol dfi
  if BS8.pack "test_" `BS8.isPrefixOf` bsname
    then return (bsname, Some dfi)
    else Nothing

-- | ARM functions with a single scalar return value return it in %r0
--
-- Since all test functions must return a value to assert as true, this is
-- straightforward to extract
armResultExtractor :: ( CB.IsSymInterface sym
                      )
                   => MS.ArchVals MA.ARM
                   -> MST.ResultExtractor sym MA.ARM
armResultExtractor archVals = MST.ResultExtractor $ \regs _sp _mem k -> do
  let re = MS.lookupReg archVals regs (MAR.ARMGlobalBV (ASL.knownGlobalRef @"_R0"))
  k PC.knownRepr (CS.regValue re)

mkSymExTest :: MST.SimulationResult -> FilePath -> TT.TestTree
mkSymExTest expected exePath = TT.askOption $ \saveSMT@(SaveSMT _) -> TT.askOption $ \saveMacaw@(SaveMacaw _) -> TTH.testCaseSteps exePath $ \step -> do
  bytes <- BS.readFile exePath
  case Elf.decodeElfHeaderInfo bytes of
    Left (_, msg) -> TTH.assertFailure ("Error parsing ELF header from file '" ++ show exePath ++ "': " ++ msg)
    Right (Elf.SomeElf ehi) -> do
      case Elf.headerClass (Elf.header ehi) of
        Elf.ELFCLASS32 ->
          symExTestSized expected exePath saveSMT saveMacaw step ehi MA.arm_linux_info
        Elf.ELFCLASS64 -> TTH.assertFailure "64 bit ARM is not supported"

symExTestSized :: MST.SimulationResult
               -> FilePath
               -> SaveSMT
               -> SaveMacaw
               -> (String -> IO ())
               -> Elf.ElfHeaderInfo 32
               -> MAI.ArchitectureInfo MA.ARM
               -> TTH.Assertion
symExTestSized expected exePath saveSMT saveMacaw step ehi archInfo = do
   (mem, funInfos) <- MST.runDiscovery ehi MST.toAddrSymMap archInfo
   let testEntryPoints = mapMaybe hasTestPrefix funInfos
   F.forM_ testEntryPoints $ \(name, Some dfi) -> do
     step ("Testing " ++ BS8.unpack name ++ " at " ++ show (M.discoveredFunAddr dfi))
     writeMacawIR saveMacaw (BS8.unpack name) dfi
     Some (gen :: PN.NonceGenerator IO t) <- PN.newIONonceGenerator
     CBO.withYicesOnlineBackend CBO.FloatRealRepr gen CBO.NoUnsatFeatures WPF.noFeatures $ \sym -> do
       -- We are using the z3 backend to discharge proof obligations, so
       -- we need to add its options to the backend configuration
       let solver = WS.z3Adapter
       let backendConf = WI.getConfiguration sym
       WC.extendConfig (WS.solver_adapter_config_options solver) backendConf

       execFeatures <- MST.defaultExecFeatures (MST.SomeOnlineBackend sym)
       let Just archVals = MS.archVals (Proxy @MA.ARM) Nothing
       let extract = armResultExtractor archVals
       logger <- makeGoalLogger saveSMT solver name exePath
       let ?memOpts = LLVM.defaultMemOptions
       simRes <- MST.simulateAndVerify solver logger sym execFeatures archInfo archVals mem extract dfi
       TTH.assertEqual "AssertionResult" expected simRes

writeMacawIR :: (MC.ArchConstraints arch) => SaveMacaw -> String -> M.DiscoveryFunInfo arch ids -> IO ()
writeMacawIR (SaveMacaw sm) name dfi
  | not sm = return ()
  | otherwise = writeFile (toSavedMacawPath name) (show (PP.pretty dfi))

toSavedMacawPath :: String -> FilePath
toSavedMacawPath testName = "/tmp" </> name <.> "macaw"
  where
    name = fmap escapeSlash testName

-- | Construct a solver logger that saves the SMT session for the goal solving
-- in /tmp (if requested by the save-smt option)
--
-- The adapter name is included so that, if the same test is solved with
-- multiple solvers, we can differentiate them.
makeGoalLogger :: SaveSMT -> WS.SolverAdapter st -> BS8.ByteString -> FilePath -> IO WS.LogData
makeGoalLogger (SaveSMT saveSMT) adapter funName p
  | not saveSMT = return WS.defaultLogData
  | otherwise = do
      hdl <- IO.openFile (toSavedSMTSessionPath adapter funName p) IO.WriteMode
      return (WS.defaultLogData { WS.logHandle = Just hdl })

-- | Construct a path in /tmp to save the SMT session to
--
-- Just take the original path name and turn all of the slashes into underscores to escape them
toSavedSMTSessionPath :: WS.SolverAdapter st -> BS8.ByteString -> FilePath -> FilePath
toSavedSMTSessionPath adapter funName p = "/tmp" </> filename <.> "smtlib2"
  where
    filename = concat [ fmap escapeSlash p
                      , "_"
                      , BS8.unpack funName
                      , "_"
                      , WS.solver_adapter_name adapter
                      ]

escapeSlash :: Char -> Char
escapeSlash '/' = '_'
escapeSlash c = c
