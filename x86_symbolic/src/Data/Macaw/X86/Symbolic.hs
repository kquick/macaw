{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ImplicitParams #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Data.Macaw.X86.Symbolic
  ( x86_64MacawSymbolicFns
  , x86_64MacawEvalFn
  , SymFuns(..), newSymFuns
  , X86StmtExtension(..)

  , lookupX86Reg
  , updateX86Reg
  , freshX86Reg

  , RegAssign
  , getReg
  , IP, GP, Flag, X87Status, X87Top, X87Tag, FPReg, YMM
  ) where

import           Control.Lens ((^.),(%~),(&))
import           Control.Monad ( void )
import           Control.Monad.IO.Class ( liftIO )
import           Data.Functor.Identity (Identity(..))
import           Data.Kind
import           Data.Parameterized.Context as Ctx
import           Data.Parameterized.Map as MapF
import           Data.Parameterized.TraversableF
import           Data.Parameterized.TraversableFC
import           GHC.TypeLits

import qualified Data.Macaw.CFG as M
import           Data.Macaw.Symbolic
import           Data.Macaw.Symbolic.Backend
import qualified Data.Macaw.Types as M
import qualified Data.Macaw.X86 as M
import qualified Data.Macaw.X86.X86Reg as M
import           Data.Macaw.X86.Crucible
import qualified Flexdis86.Register as F

import qualified What4.Interface as WI
import qualified What4.InterpretedFloatingPoint as WIF
import qualified What4.Symbol as C

import qualified Lang.Crucible.Backend as C
import qualified Lang.Crucible.CFG.Extension as C
import qualified Lang.Crucible.CFG.Reg as C
import qualified Lang.Crucible.CFG.Expr as CE
import qualified Lang.Crucible.Simulator as C
import qualified Lang.Crucible.Types as C
import qualified Lang.Crucible.LLVM.MemModel as MM

------------------------------------------------------------------------
-- Utilities for generating a type-level context with repeated elements.

type family CtxRepeat (n :: Nat) (c :: k) :: Ctx k where
  CtxRepeat  0 c = EmptyCtx
  CtxRepeat  n c = CtxRepeat  (n-1) c ::> c

class RepeatAssign (tp :: k) (ctx :: Ctx k) where
  repeatAssign :: (Int -> f tp) -> Assignment f ctx

instance RepeatAssign tp EmptyCtx where
  repeatAssign _ = Empty

instance RepeatAssign tp ctx => RepeatAssign tp (ctx ::> tp) where
  repeatAssign f =
    let r = repeatAssign f
     in r :> f (sizeInt (Ctx.size r))

------------------------------------------------------------------------
-- X86 Registers

type instance ArchRegContext M.X86_64
   =   (EmptyCtx ::> M.BVType 64)   -- IP
   <+> CtxRepeat 16 (M.BVType 64)   -- GP regs
   <+> CtxRepeat 9  M.BoolType      -- Flags
   <+> CtxRepeat 12  M.BoolType     -- X87 Status regs (x87 status word)
   <+> (EmptyCtx ::> M.BVType 3)    -- X87 top of the stack (x87 status word)
   <+> CtxRepeat 8 (M.BVType 2)     -- X87 tags
   <+> CtxRepeat 8 (M.BVType 80)    -- FP regs
   <+> CtxRepeat 16 (M.BVType 512)  -- ZMM regs

type RegAssign f = Assignment f (ArchRegContext M.X86_64)

type IP          = 0        -- 1
type GP n        = 1 + n    -- 16
type Flag n      = 17 + n   -- 9
type X87Status n = 26 + n   -- 12
type X87Top      = 38       -- 1
type X87Tag n    = 39 + n   -- 8
type FPReg n     = 47 + n   -- 8
type YMM n       = 55 + n   -- 16

getReg ::
  forall n t f. (Idx n (ArchRegContext M.X86_64) t) => RegAssign f -> f t
getReg x = x ^. (field @n)

x86RegName' :: M.X86Reg tp -> String
x86RegName' M.X86_IP     = "ip"
x86RegName' (M.X86_GP r) = show $ F.reg64No r
x86RegName' (M.X86_FlagReg r) = show r
x86RegName' (M.X87_StatusReg r) = show r
x86RegName' M.X87_TopReg = "x87Top"
x86RegName' (M.X87_TagReg r) = "x87Tag" ++ show r
x86RegName' (M.X87_FPUReg r) = show $ F.mmxRegNo r
x86RegName' (M.X86_ZMMReg r) = "zmm" ++ show r

x86RegName :: M.X86Reg tp -> C.SolverSymbol
x86RegName r = C.systemSymbol $ "r!" ++ x86RegName' r

gpReg :: Int -> M.X86Reg (M.BVType 64)
gpReg = M.X86_GP . F.Reg64 . fromIntegral

-- | The x86 flag registers that are directly supported by Macw.
flagRegs :: Assignment M.X86Reg (CtxRepeat 9 M.BoolType)
flagRegs =
  Empty :> M.CF :> M.PF :> M.AF :> M.ZF :> M.SF :> M.TF :> M.IF :> M.DF :> M.OF

x87_statusRegs :: Assignment M.X86Reg (CtxRepeat 12 M.BoolType)
x87_statusRegs =
     (repeatAssign (M.X87_StatusReg . fromIntegral)
        :: Assignment M.X86Reg (CtxRepeat 11 M.BoolType))
  :> M.X87_StatusReg 14

-- | This contains an assignment that stores the register associated with each index in the
-- X86 register structure.
x86RegAssignment :: Assignment M.X86Reg (ArchRegContext M.X86_64)
x86RegAssignment =
  Empty :> M.X86_IP
  <++> (repeatAssign gpReg :: Assignment M.X86Reg (CtxRepeat 16 (M.BVType 64)))
  <++> flagRegs
  <++> x87_statusRegs
  <++> (Empty :> M.X87_TopReg)
  <++> (repeatAssign (M.X87_TagReg . fromIntegral)    :: Assignment M.X86Reg (CtxRepeat  8 (M.BVType 2)))
  <++> (repeatAssign (M.X87_FPUReg . F.mmxReg . fromIntegral) :: Assignment M.X86Reg (CtxRepeat  8 (M.BVType 80)))
  <++> (repeatAssign (M.X86_ZMMReg . fromIntegral)
        :: Assignment M.X86Reg (CtxRepeat 16 (M.BVType 512)))


x86RegStructType :: C.TypeRepr (ArchRegStruct M.X86_64)
x86RegStructType =
  C.StructRepr (typeCtxToCrucible $ fmapFC M.typeRepr x86RegAssignment)

regIndexMap :: RegIndexMap M.X86_64
regIndexMap = mkRegIndexMap x86RegAssignment
            $ Ctx.size $ crucArchRegTypes x86_64MacawSymbolicFns


{- | Lookup a Macaw register in a Crucible assignemnt.
This function returns "Nothing" if the input register is not represented
in the assignment.  This means that either the input register is malformed,
or we haven't modelled this register for some reason. -}
lookupX86Reg ::
  M.X86Reg t                                    {- ^ Lookup this register -} ->
  Assignment f (MacawCrucibleRegTypes M.X86_64) {- ^ Assignment -} ->
  Maybe (f (ToCrucibleType t))  {- ^ The value of the register -}
lookupX86Reg r asgn =
  do pair <- MapF.lookup r regIndexMap
     return (asgn Ctx.! crucibleIndex pair)

updateX86Reg ::
  M.X86Reg t ->
  (f (ToCrucibleType t) -> f (ToCrucibleType t)) ->
  Assignment f (MacawCrucibleRegTypes M.X86_64) {- ^Update this assignment -} ->
  Maybe (Assignment f (MacawCrucibleRegTypes M.X86_64))
updateX86Reg r upd asgn =
  do pair <- MapF.lookup r regIndexMap
     return (asgn & ixF (crucibleIndex pair) %~ upd)
     -- return (adjust upd (crucibleIndex pair) asgn)

freshX86Reg :: C.IsSymInterface sym =>
  sym -> M.X86Reg t -> IO (C.RegValue' sym (ToCrucibleType t))
freshX86Reg sym r =
  C.RV <$> freshValue sym (show r) (Just (C.knownNat @64))  (M.typeRepr r)

freshValue ::
  (C.IsSymInterface sym, 1 <= ptrW) =>
  sym ->
  String {- ^ Name for fresh value -} ->
  Maybe (C.NatRepr ptrW) {- ^ Width of pointers; if nothing, allocate as bits -} ->
  M.TypeRepr tp {- ^ Type of value -} ->
  IO (C.RegValue sym (ToCrucibleType tp))
freshValue sym str w ty =
  case ty of
    M.BVTypeRepr y ->
      case testEquality y =<< w of

        Just Refl ->
          do nm_base <- symName (str ++ "_base")
             nm_off  <- symName (str ++ "_off")
             base    <- WI.freshNat sym nm_base
             offs    <- WI.freshConstant sym nm_off (C.BaseBVRepr y)
             return (MM.LLVMPointer base offs)

        Nothing ->
          do nm   <- symName str
             base <- WI.natLit sym 0
             offs <- WI.freshConstant sym nm (C.BaseBVRepr y)
             return (MM.LLVMPointer base offs)

    M.FloatTypeRepr fi -> do
      nm <- symName str
      WIF.freshFloatConstant sym nm $ floatInfoToCrucible fi

    M.BoolTypeRepr ->
      do nm <- symName str
         WI.freshConstant sym nm C.BaseBoolRepr

    M.TupleTypeRepr {} -> crash [ "Unexpected symbolic tuple:", show str ]
    M.VecTypeRepr {} -> crash [ "Unexpected symbolic vector:", show str ]

  where
  symName x =
    case C.userSymbol ("macaw_" ++ x) of
      Left err -> crash [ "Invalid symbol name:", show x, show err ]
      Right a -> return a

  crash xs =
    case xs of
      [] -> crash ["(unknown)"]
      y : ys -> fail $ unlines $ ("[freshX86Reg] " ++ y)
                               : [ "*** " ++ z | z <- ys ]

------------------------------------------------------------------------
-- Other X86 specific


-- | We currently make a type like this, we could instead a generic
-- X86PrimFn function
data X86StmtExtension (f :: C.CrucibleType -> Type) (ctp :: C.CrucibleType) where
  -- | To reduce clutter, but potentially increase clutter, we just make every
  -- Macaw X86PrimFn a Macaw-Crucible statement extension.
  X86PrimFn :: !(M.X86PrimFn (AtomWrapper f) t) ->
                                        X86StmtExtension f (ToCrucibleType t)
  X86PrimStmt :: !(M.X86Stmt (AtomWrapper f))
              -> X86StmtExtension f C.UnitType
  X86PrimTerm :: !(M.X86TermStmt (AtomWrapper f)) -> X86StmtExtension f C.UnitType

instance C.PrettyApp X86StmtExtension where
  ppApp ppSub (X86PrimFn x) = d
    where Identity d = M.ppArchFn (Identity . liftAtomIn ppSub) x
  ppApp ppSub (X86PrimStmt stmt) = M.ppArchStmt (liftAtomIn ppSub) stmt
  ppApp ppSub (X86PrimTerm term) = M.ppArchTermStmt (liftAtomIn ppSub) term

instance C.TypeApp X86StmtExtension where
  appType (X86PrimFn x) = typeToCrucible (M.typeRepr x)
  appType (X86PrimStmt _) = C.UnitRepr
  appType (X86PrimTerm _) = C.UnitRepr

instance FunctorFC X86StmtExtension where
  fmapFC f (X86PrimFn x) = X86PrimFn (fmapFC (liftAtomMap f) x)
  fmapFC f (X86PrimStmt stmt) = X86PrimStmt (fmapF (liftAtomMap f) stmt)
  fmapFC f (X86PrimTerm term) = X86PrimTerm (fmapF (liftAtomMap f) term)

instance FoldableFC X86StmtExtension where
  foldMapFC f (X86PrimFn x) = foldMapFC (liftAtomIn f) x
  foldMapFC f (X86PrimStmt stmt) = foldMapF (liftAtomIn f) stmt
  -- There are no contents in terminator statements for now
  foldMapFC _f (X86PrimTerm _term) = mempty

instance TraversableFC X86StmtExtension where
  traverseFC f (X86PrimFn x) = X86PrimFn <$> traverseFC (liftAtomTrav f) x
  traverseFC f (X86PrimStmt stmt) = X86PrimStmt <$> traverseF (liftAtomTrav f) stmt
  traverseFC f (X86PrimTerm term) = X86PrimTerm <$> traverseF (liftAtomTrav f) term

type instance MacawArchStmtExtension M.X86_64 = X86StmtExtension


crucGenX86Fn :: forall ids s tp. M.X86PrimFn (M.Value M.X86_64 ids) tp
             -> CrucGen M.X86_64 ids s (C.Atom s (ToCrucibleType tp))
crucGenX86Fn fn =
  case fn of
    M.X86Syscall w v1 v2 v3 v4 v5 v6 v7 -> do
      -- This is the key mechanism for our system call handling. See Note
      -- [Syscalls] for details
      a1 <- valueToCrucible v1
      a2 <- valueToCrucible v2
      a3 <- valueToCrucible v3
      a4 <- valueToCrucible v4
      a5 <- valueToCrucible v5
      a6 <- valueToCrucible v6
      a7 <- valueToCrucible v7

      let syscallArgs = Ctx.Empty Ctx.:> a1 Ctx.:> a2 Ctx.:> a3 Ctx.:> a4 Ctx.:> a5 Ctx.:> a6 Ctx.:> a7
      let argTypes = Ctx.Empty Ctx.:> MM.LLVMPointerRepr w Ctx.:> MM.LLVMPointerRepr w Ctx.:> MM.LLVMPointerRepr w Ctx.:> MM.LLVMPointerRepr w Ctx.:> MM.LLVMPointerRepr w Ctx.:> MM.LLVMPointerRepr w Ctx.:> MM.LLVMPointerRepr w
      let retTypes = Ctx.Empty Ctx.:> MM.LLVMPointerRepr w Ctx.:> MM.LLVMPointerRepr w
      let retRepr = C.StructRepr retTypes
      syscallArgStructAtom <- evalAtom (C.EvalApp (CE.MkStruct argTypes syscallArgs))
      let lookupHdlStmt = MacawLookupSyscallHandle argTypes retTypes syscallArgStructAtom
      hdlAtom <- evalMacawStmt lookupHdlStmt
      evalAtom $ C.Call hdlAtom syscallArgs retRepr
    _ -> do
      let f :: forall arch a . M.Value arch ids a -> CrucGen arch ids s (AtomWrapper (C.Atom s) a)
          f x = AtomWrapper <$> valueToCrucible x
      r <- traverseFC f fn
      evalArchStmt (X86PrimFn r)


crucGenX86Stmt :: forall ids s
                . M.X86Stmt (M.Value M.X86_64 ids)
               -> CrucGen M.X86_64 ids s ()
crucGenX86Stmt stmt = do
  let f :: M.Value M.X86_64 ids a -> CrucGen M.X86_64 ids s (AtomWrapper (C.Atom s) a)
      f x = AtomWrapper <$> valueToCrucible x
  stmt' <- traverseF f stmt
  void (evalArchStmt (X86PrimStmt stmt'))

crucGenX86TermStmt :: forall ids s
                    . M.X86TermStmt (M.Value M.X86_64 ids)
                   -> M.RegState M.X86Reg (M.Value M.X86_64 ids)
                   -> Maybe (C.Label s)
                   -> CrucGen M.X86_64 ids s ()
crucGenX86TermStmt tstmt _regs _fallthrough = do
  tstmt' <- traverseF f tstmt
  void (evalArchStmt (X86PrimTerm tstmt'))
  where
    f :: M.Value M.X86_64 ids a -> CrucGen M.X86_64 ids s (AtomWrapper (C.Atom s) a)
    f x = AtomWrapper <$> valueToCrucible x

-- | X86_64 specific functions for translation Macaw into Crucible.
x86_64MacawSymbolicFns :: MacawSymbolicArchFunctions M.X86_64
x86_64MacawSymbolicFns =
  MacawSymbolicArchFunctions
  { crucGenArchConstraints = \x -> x
  , crucGenRegAssignment = x86RegAssignment
  , crucGenRegStructType = x86RegStructType
  , crucGenArchRegName  = x86RegName
  , crucGenArchFn = crucGenX86Fn
  , crucGenArchStmt = crucGenX86Stmt
  , crucGenArchTermStmt = crucGenX86TermStmt
  }


-- | X86_64 specific function for evaluating a Macaw X86_64 program in Crucible.
x86_64MacawEvalFn
  :: (C.IsSymInterface sym, MM.HasLLVMAnn sym, ?memOpts :: MM.MemOptions)
  => SymFuns sym
  -> MacawArchStmtExtensionOverride M.X86_64
  -> MacawArchEvalFn sym MM.Mem M.X86_64
x86_64MacawEvalFn fs (MacawArchStmtExtensionOverride override) =
  MacawArchEvalFn $ \global_var_mem globals ext_stmt crux_state -> do
    mRes <- override ext_stmt crux_state
    case mRes of
      Nothing ->
        case ext_stmt of
          X86PrimFn x -> funcSemantics fs x crux_state
          X86PrimStmt stmt -> stmtSemantics fs global_var_mem globals stmt crux_state
          X86PrimTerm term -> termSemantics fs term crux_state
      Just res -> return res

x86LookupReg
  :: C.RegEntry sym (ArchRegStruct M.X86_64)
  -> M.X86Reg tp
  -> C.RegEntry sym (ToCrucibleType tp)
x86LookupReg reg_struct_entry macaw_reg =
  case lookupX86Reg macaw_reg (C.regValue reg_struct_entry) of
    Just (C.RV val) -> C.RegEntry (typeToCrucible $ M.typeRepr macaw_reg) val
    Nothing -> error $ "unexpected register: " ++ showF macaw_reg

x86UpdateReg
  :: C.RegEntry sym (ArchRegStruct M.X86_64)
  -> M.X86Reg tp
  -> C.RegValue sym (ToCrucibleType tp)
  -> C.RegEntry sym (ArchRegStruct M.X86_64)
x86UpdateReg reg_struct_entry macaw_reg val =
  case updateX86Reg macaw_reg (\_ -> C.RV val) (C.regValue reg_struct_entry) of
    Just res_reg_struct -> reg_struct_entry { C.regValue = res_reg_struct }
    Nothing -> error $ "unexpected register: " ++ showF macaw_reg

instance GenArchInfo LLVMMemory M.X86_64 where
  genArchVals _ _ mOverride = Just $ GenArchVals
    { archFunctions = x86_64MacawSymbolicFns
    , withArchEval = \sym k -> do
        sfns <- liftIO $ newSymFuns sym
        let override = case mOverride of
                         Nothing -> defaultMacawArchStmtExtensionOverride
                         Just ov -> ov
        k $ x86_64MacawEvalFn sfns override
    , withArchConstraints = \x -> x
    , lookupReg = x86LookupReg
    , updateReg = x86UpdateReg
    }

{- Note [Syscalls]

While most of the extension functions can be translated directly by embedding them in
macaw symbolic wrappers (e.g., X86PrimFn), system calls are different. We cannot
symbolically branch (and thus cannot invoke overrides) from extension
statement/expression handlers, which is significantly limiting when modeling
operating system behavior.

To work around this, we translate the literal system call extension function
into a sequence that gives us more flexibility:

1. Inspect the machine state and return the function handle that corresponds to
   the requested syscall
2. Invoke the syscall

Note that the ability of system calls to modify the register state (i.e., return
values), the translation of the machine instruction must arrange for the
returned values to flow back into the required registers. For example, it means
that the two return registers (rax and rdi) have to be updated with the new
values returned by the overrides on Linux/x86_64. macaw-x86 arranges for that to
happen when it generates an 'X86Syscall' instruction.

This subtle coupling is required because register identities are lost at this
stage in the translation, and this code cannot force an update on a machine
register.

Note that after this stage, there are no more 'X86Syscall' expressions.

-}
