module Nuko.Typer.Infer (
  initTypeDecl,
  inferTypeDecl,
  checkTypeSymLoop
) where

import Relude                (newIORef, snd, fst, Foldable (foldl'), writeIORef, Applicative ((*>)), ($), HashMap)
import Relude.String         (Text)
import Relude.Functor        (Functor(fmap), (<$>))
import Relude.Foldable       (Foldable(foldr), Traversable(traverse), traverse_, for_)
import Relude.Applicative    (Applicative(pure))

import Nuko.Typer.Tree       () -- Just to make the equality between XName Re and XName Tc works
import Nuko.Tree             (TypeDecl(..), Re, Tc, Ty, XName, XTy)
import Nuko.Typer.Env        (MonadTyper, addTyKind, tsFields, addTy, tsConstructors, TyInfo (IsTySyn, IsTyDef), generalizeTy)
import Nuko.Typer.Types      (Hole (..), TKind (..), TTy (..), Virtual, KiHole)
import Nuko.Resolver.Tree    (ReId(text), Path (Local))
import Nuko.Tree.TopLevel    (TypeDeclArg(..))
import Nuko.Typer.Infer.Type (inferTy, findCycle)
import Nuko.Typer.Unify      (unifyKind)

import qualified Data.HashMap.Strict as HashMap

data InitTypeData =
  InitTypeData
  { itBindings :: [(Text, TKind)]
  , itResTy    :: TTy Virtual
  , itResHole  :: KiHole
  }

checkTypeSymLoop :: MonadTyper m => [TypeDecl Re] -> m ()
checkTypeSymLoop decls = do
    let filtered = filterDec decls HashMap.empty
    for_ (HashMap.toList filtered) $ \(name, ty) ->
      findCycle name filtered ty
  where
    filterDec :: [TypeDecl Re] -> HashMap Text (Ty Re) -> HashMap Text (Ty Re)
    filterDec [] m  = m
    filterDec (TypeDecl name _ (TypeSym ty) : xs) m = filterDec xs (HashMap.insert name.text ty m)
    filterDec (_ : xs) m = filterDec xs m

initTypeDecl :: MonadTyper m => TypeDecl Re -> m InitTypeData
initTypeDecl decl = do
  bindings <- traverse (\name -> fmap (name.text,) (fmap KiHole (newIORef (Empty name.text 0)))) decl.tyArgs

  retHole <- newIORef (Empty decl.tyName.text 0)
  let curKind = foldr KiFun (KiHole retHole) (fmap snd bindings)

  tyInfo <-
    case decl.tyDecl of
      TypeSym _   -> pure IsTySyn
      _           -> writeIORef retHole (Filled KiStar) *> pure IsTyDef

  addTyKind decl.tyName.text curKind tyInfo

  let typeTy = (TyIdent (Local decl.tyName))
  let resultantType = foldl' TyApp typeTy ((\n -> TyIdent (Local n)) <$> decl.tyArgs)

  pure $ InitTypeData bindings resultantType retHole

inferTypeDecl :: MonadTyper m => TypeDecl Re -> InitTypeData -> m (TypeDecl Tc)
inferTypeDecl (TypeDecl name args body) initData = do
    decl <- inferDecl body
    res <- pure (TypeDecl name args decl)
    pure res
  where
    inferField :: MonadTyper m => (XName Re, Ty Re) -> m (XName Tc, TTy Virtual)
    inferField (fieldName, ty) = do
      (inferedTy, kind) <- inferTy initData.itBindings ty
      unifyKind kind KiStar
      let resTy = TyFun inferedTy initData.itResTy
      addTy tsFields fieldName.text resTy
      genTy <- generalizeTy inferedTy
      pure (fieldName, (foldr (\(n, _) b -> TyForall n (\_ -> b)) genTy initData.itBindings))

    inferSumField :: MonadTyper m => (XName Re, [XTy Re]) -> m (XName Tc, [TTy Virtual])
    inferSumField (fieldName, tys) = do
      list <- traverse (inferTy initData.itBindings) tys
      traverse_ (\ty -> unifyKind (snd ty) KiStar) list
      let resTy  = foldr TyFun initData.itResTy (fst <$> list)
      let resTy' = foldr (\(n,_) b -> TyForall n (\_ -> b)) resTy initData.itBindings
      addTy tsConstructors fieldName.text resTy'
      pure (fieldName, (fst <$> list))

    inferDecl :: MonadTyper m => TypeDeclArg Re -> m (TypeDeclArg Tc)
    inferDecl = \case
      TypeSym type'   -> do
        (resTy, resKind) <- inferTy initData.itBindings type'
        writeIORef initData.itResHole (Filled resKind)
        genTy <- generalizeTy resTy
        pure (TypeSym genTy)
      TypeProd fields -> TypeProd <$> traverse inferField fields
      TypeSum fields  -> TypeSum  <$> traverse inferSumField fields
