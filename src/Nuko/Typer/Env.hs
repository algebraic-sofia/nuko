module Nuko.Typer.Env (
  DataConsInfo(..),
  FieldInfo(..),
  TypeSpace(..),
  DefInfo(..),
  TyInfo(..),
  TyInfoKind(..),
  TypingEnv(..),
  MonadTyper,
  emptyTypeSpace,
  addFieldToEnv,
  getKind,
  addTy,
  qualifyLocal,
  updateTyKind,
  addTyKind,
  qualifyPath,
  eagerInstantiate,
  newKindHole,
  newTyHole,
  genTyHole,
  getLocal,
  addLocals,
  constructorTy,
  parameters,
  fiResultType,
  tsConstructors,
  tsVars,
  seScope,
  seTyEnv,
  addLocalTy,
  getKindMaybe,
  getTy,
  runInst,
  newTyHoleWithScope,
  tsTypeFields,
  runToIO,
  genKindHole,
  addLocalTypes,
) where

import Relude                  (Generic, Int, MonadIO, pure, (.), (<$>), ($), Monad ((>>=)), fst, Num ((+)), IO, Endo (appEndo), Bifunctor (first))
import Relude.Monad            (MonadState, MonadReader (local), Maybe (..), asks, maybe)
import Relude.Monoid           ((<>))
import Relude.Lifted           (newIORef)

import Nuko.Names              (Name, ConsName, TyName, ValName, ModName (..), Label (..), Path (..), mkQualified, Qualified(..), getPathInfo, NameKind (TyName), mkName, genIdent, Attribute (Untouched), Ident, mkModName)
import Nuko.Utils              (terminate)
import Nuko.Typer.Types        (TTy (..), Relation (..), TKind, derefTy)
import Nuko.Typer.Types        (Hole (..), TKind (..))
import Nuko.Typer.Error        (TypeError(NameResolution))
import Nuko.Report.Range       (getPos)
import Nuko.Resolver.Tree      ()

import Pretty.Tree             (PrettyTree)
import Data.HashMap.Strict     (HashMap)
import Data.These              (These)
import Lens.Micro.Platform     (makeLenses, over, Lens', use, (%=), at)
import Control.Monad.Chronicle (MonadChronicle)

import qualified Data.HashMap.Strict as HashMap
import qualified Control.Monad.Trans.Chronicle as Chronicle
import qualified Control.Monad.State.Strict as State
import qualified Control.Monad.Reader as Reader

data TyInfoKind
  = IsTySyn
  | IsTyDef
  deriving Generic

data TyInfo = TyInfo
  { _resultantType :: TTy 'Real
  , _label   :: Name TyName
  , _tyNames :: [(Name TyName, TKind)]
  , _tyKind  :: TyInfoKind
  } deriving Generic

data DefInfo = DefInfo
  { _diResultType :: TTy 'Virtual
  , _polymorphics :: [(Name TyName, TKind)]
  , _argTypes     :: [TTy 'Real]
  , _retType      :: TTy 'Real
  } deriving Generic

data FieldInfo = FieldInfo
  { _fiResultType :: TTy 'Virtual
  } deriving Generic

data DataConsInfo = DataConsInfo
  { _constructorTy :: TTy 'Virtual
  , _parameters    :: Int
  } deriving Generic

data TypeSpace = TypeSpace
  { _tsTypes        :: HashMap (Qualified (Name TyName)) (TKind, TyInfo)
  , _tsConstructors :: HashMap (Qualified (Name ConsName)) DataConsInfo
  , _tsVars         :: HashMap (Qualified (Name ValName)) (TTy 'Virtual, DefInfo)
  , _tsTypeFields   :: HashMap (Qualified (Name TyName)) (HashMap (Name ValName) FieldInfo)
  } deriving Generic

data TypingEnv = TypingEnv
  { _teCurModule     :: ModName
  , _globalTypingEnv :: TypeSpace
  } deriving Generic

data ScopeEnv = ScopeEnv
  { _seVars     :: HashMap (Name ValName) (TTy 'Virtual)
  , _seTyEnv    :: [(Name TyName, TKind)]
  , _seScope    :: Int
  } deriving Generic

makeLenses ''DataConsInfo
makeLenses ''FieldInfo
makeLenses ''TypeSpace
makeLenses ''TypingEnv
makeLenses ''ScopeEnv

instance PrettyTree TypingEnv where
instance PrettyTree FieldInfo where
instance PrettyTree TyInfoKind where
instance PrettyTree DataConsInfo where
instance PrettyTree DefInfo where
instance PrettyTree TypeSpace where
instance PrettyTree TyInfo where

type MonadTyper m =
  ( MonadIO m
  , MonadState TypingEnv m
  , MonadReader ScopeEnv m
  , MonadChronicle (Endo [TypeError]) m
  )

emptyScopeEnv :: ScopeEnv
emptyScopeEnv = ScopeEnv HashMap.empty [] 0

emptyTypeSpace :: TypeSpace
emptyTypeSpace = TypeSpace HashMap.empty HashMap.empty HashMap.empty HashMap.empty

runToIO :: TypeSpace -> ModName -> (forall m. MonadTyper m => m a) -> IO (These [TypeError] (a, TypingEnv))
runToIO typeSpace modName action = do
  let env = TypingEnv modName typeSpace
  let res = Reader.runReaderT action emptyScopeEnv
  first (`appEndo` [])
    <$> Chronicle.runChronicleT (State.runStateT res env)

runInst :: MonadTyper m => m (b, TTy 'Virtual) -> m (b, TTy 'Virtual)
runInst fun = do
  (resE, resTy) <- fun
  instTy <- eagerInstantiate resTy
  pure (resE, derefTy instTy)

addLocals :: MonadTyper m => HashMap (Name ValName) (TTy 'Virtual) -> m a -> m a
addLocals newLocals = local (over seVars (<> newLocals))

getLocal :: MonadTyper m => Name ValName -> m (TTy 'Virtual)
getLocal name = do
  maybeRes <- asks (HashMap.lookup name . _seVars)
  case maybeRes of
    Just res -> pure res
    Nothing  -> terminate (NameResolution $ Label $ name)

newTyHole :: MonadTyper m => Name TyName -> m (TTy k)
newTyHole name = asks _seScope >>= newTyHoleWithScope name

newTyHoleWithScope :: MonadTyper m => Name TyName -> Int -> m (TTy k)
newTyHoleWithScope name scope = TyHole <$> newIORef (Empty name scope)

genTyHole :: MonadTyper m => m (TTy 'Virtual)
genTyHole = newTyHole (mkName TyName (genIdent "_") Untouched)

newKindHole :: MonadTyper m => Name TyName -> m TKind
newKindHole name = do
  curScope <- asks _seScope
  KiHole <$> newIORef (Empty name curScope)

genKindHole :: MonadTyper m => m TKind
genKindHole = newKindHole (mkName TyName (genIdent "_") Untouched)

eagerInstantiate :: MonadTyper m => TTy 'Virtual -> m (TTy 'Virtual)
eagerInstantiate = \case
  TyForall name f -> do
    hole <- newTyHole name
    eagerInstantiate (f hole)
  other -> pure other

qualifyLocal :: MonadTyper m => Name k -> m (Qualified (Name k))
qualifyLocal name = do
  modName <- use teCurModule
  pure (mkQualified modName name (getPos name))

qualifyPath :: MonadTyper m => Path (Name k) -> m (Qualified (Name k))
qualifyPath (Local _ name) = qualifyLocal name
qualifyPath (Full _ qualified) = pure qualified

addTyKind :: MonadTyper m => Name TyName -> TKind -> TyInfo -> m ()
addTyKind name ki info = qualifyLocal name >>= \name' -> globalTypingEnv . tsTypes %= HashMap.insert name' (ki, info)

updateTyKind :: MonadTyper m => Qualified (Name TyName) -> ((TKind, TyInfo) -> Maybe (TKind, TyInfo)) -> m ()
updateTyKind name f = globalTypingEnv . tsTypes %= HashMap.update f name

addTy :: MonadTyper m => Lens' TypeSpace (HashMap (Qualified (Name k)) b) -> Maybe Ident -> Name k -> b -> m ()
addTy lens tyName name ki = do
  qual@(Qualified _ (ModName _ e _) ident r') <- qualifyLocal name
  let name' = maybe qual (\tyName' -> mkQualified (mkModName (e <> pure tyName')) ident r') tyName
  globalTypingEnv . lens %= HashMap.insert name' ki

getTy :: MonadTyper m => Lens' TypeSpace (HashMap (Qualified (Name k)) b) -> Qualified (Name k) -> m b
getTy lens qualified = do
  result <- use (globalTypingEnv . lens . at qualified)
  case result of
    Just res -> pure res
    Nothing  -> terminate (NameResolution (Label $ qualified.qInfo))

getKindMaybe :: MonadTyper m => Path (Name TyName) -> m (Maybe TKind)
getKindMaybe path = do
  canon  <- qualifyPath path
  result <- use (globalTypingEnv . tsTypes . at canon)
  pure (fst <$> result)

getKind :: MonadTyper m => Path (Name TyName) -> m TKind
getKind path = do
  result <- getKindMaybe path
  maybe (terminate (NameResolution (Label $ getPathInfo path))) pure result

addFieldToEnv :: MonadTyper m => Name TyName -> Name ValName -> FieldInfo -> m ()
addFieldToEnv typeName fieldName fieldInfo = do
  qualified <- qualifyLocal typeName
  globalTypingEnv . tsTypeFields %= HashMap.insertWith ((<>)) qualified (HashMap.singleton fieldName fieldInfo)

addLocalTy :: MonadTyper m => Name TyName -> TKind -> m a -> m a
addLocalTy name ty = local (over seTyEnv ((name, ty) :) . over seScope (+ 1))

addLocalTypes :: MonadTyper m => [(Name TyName, TKind)] -> m a -> m a
addLocalTypes names = local (over seTyEnv (names <>))