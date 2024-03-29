module Nuko.Typer.Infer.Pat (
  inferPat,
  checkPat
) where

import Relude

import Nuko.Names               (Attribute (Untouched), Name, NameKind (TyName),
                                 ValName, coerceTo, genIdent, mkName)
import Nuko.Resolver.Tree       ()
import Nuko.Tree                (Re, RecordBinder (..), Tc)
import Nuko.Tree.Expr           (Pat (..))
import Nuko.Typer.Env
import Nuko.Typer.Error         (TypeError (..))
import Nuko.Typer.Infer.Literal (inferLit)
import Nuko.Typer.Infer.Type    (inferClosedTy)
import Nuko.Typer.Tree          ()
import Nuko.Typer.Types         (Relation (..), TTy (..), evaluate, quote)
import Nuko.Typer.Unify         (destructFun, unify)

import Control.Monad.Reader     (foldM)
import Lens.Micro.Platform      (at, use, view)

import Control.Monad.State      qualified as State
import Data.HashMap.Strict      qualified as HashMap
import Data.Traversable         (for)
import Nuko.Report.Range        (HasPosition (getPos), Range)
import Nuko.Typer.Infer.Fields  (assertFields)

type InferPat m a = State.StateT (HashMap (Name ValName) (TTy 'Virtual)) m a

checkPat :: MonadTyper m => Pat Re -> TTy 'Virtual -> m (HashMap (Name ValName) (TTy 'Virtual))
checkPat pat ty = case (pat, ty) of
  (_, TyForall _ f) -> do
    ctxLvl <- view seScope
    checkPat pat (f (TyVar ctxLvl))
  _ -> do
    ((resPat, inferedTy), bindings) <- inferPat pat
    instTy <- eagerInstantiate inferedTy
    _ <- unify (getPos resPat) instTy ty
    pure bindings

inferPat :: MonadTyper m => Pat Re -> m ((Pat Tc, TTy 'Virtual), HashMap (Name ValName) (TTy 'Virtual))
inferPat pat =
    State.runStateT (go pat) HashMap.empty
  where
    newId :: MonadTyper m => Name ValName -> InferPat m (Name ValName, TTy 'Virtual)
    newId name = do
      resTy <- use (at name)
      case resTy of
        Just ty' -> pure (name, ty')
        Nothing  -> do
          resHole <- lift $ newTyHole (coerceTo TyName name)
          modify (HashMap.insert name resHole)
          pure (name, resHole)

    applyPat ::  MonadTyper m => Range -> ([Pat Tc], TTy 'Virtual) -> Pat Re -> InferPat m ([Pat Tc], TTy 'Virtual)
    applyPat range (args, fnTy) arg = do
      (argTy, retTy) <- lift $ destructFun range fnTy
      (argRes, argTy') <- go arg
      _ <- lift $ unify range argTy argTy'
      pure (argRes : args, retTy)

    go :: MonadTyper m => Pat Re -> InferPat m (Pat Tc, TTy 'Virtual)
    go = \case
      PWild ext -> do
        tyHole <- lift (newTyHole (mkName TyName (genIdent "_") Untouched))
        pure (PWild (quote 0 tyHole, ext), tyHole)
      PId place _ -> do
        (name, resTy) <- newId place
        pure (PId name (quote 0 resTy), resTy)
      PCons path args ext -> do
        qualified <- lift (qualifyPath path)
        (constRealTy, constInfo) <- lift (getTy tsConstructors qualified)
        when (constInfo._parameters /= length args) $
          lift (endDiagnostic (ExpectedConst (getPos path) constInfo._parameters (length args)) ext)
        let constTy = evaluate [] constRealTy
        let fnRange = getPos path
        (argsRes, resTy) <- foldM (applyPat fnRange) ([], constTy) args
        resTt <- lift $ eagerInstantiate resTy
        pure (PCons path (reverse argsRes) (quote 0 resTy, ext), resTt)
      PLit lit _ -> do
        (resLit, resTy) <- lift $ inferLit lit
        pure (PLit resLit (quote 0 resTy), resTy)
      PAnn pat' ty ext -> do
        (resPat, resPatTy) <- go pat'
        (resTy, _) <- lift $ inferClosedTy ty
        resTy' <- lift $ unify (getPos resPat) resPatTy resTy
        pure (PAnn resPat (quote 0 resTy) (quote 0 resTy, ext), resTy')
      POr pat' pat'' ext -> do
        (resPat, resPatTy) <- go pat'
        (resPat', resPatTy') <- go pat''
        resTy' <- lift $ unify (getPos resPat) resPatTy resPatTy'
        pure (POr resPat resPat' (quote 0 resPatTy, ext), resTy')
      PRec tyName' binders ext -> do
        qualified <- lift (qualifyPath tyName')
        resInfo <- lift (getTy tsTypeFields qualified)
        (binderRec, resTy) <- lift $ assertFields qualified ext resInfo binders
        newBinders' <- for binderRec $ \(binder, binderTy) -> do
          (resPat, resPatTy) <- go binder.rbVal
          _ <- lift $ unify (getPos binder) resPatTy binderTy
          pure (RecordBinder binder.rbName resPat (quote 0 resTy))
        pure (PRec tyName' newBinders' (quote 0 resTy, ext), resTy)
