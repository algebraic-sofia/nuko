
-- | This module is useful for storing occourence of things inside an enviroment
-- So i can use it for local scopes and for tracking opened things inside the 
-- current module
module Nuko.Resolver.Occourence (
  OccName(..),
  NameKind(..),
  OccEnv(..),
  lookupEnv,
  insertEnv,
  updateEnvWith
) where

import Relude           (Generic, HashMap, Semigroup, Monoid, Functor)
import Relude.Base      (Eq)
import Relude.String    (Text)
import Relude.Container (Hashable)
import Relude.Monad     (Maybe, maybe)

import qualified Data.HashMap.Strict as HashMap

data NameKind
  = VarName
  | TyName
  | ConsName
  | FieldName
  deriving (Eq, Generic)

-- | Name that is not qualified
data OccName = OccName
  { name :: Text
  , kind :: NameKind
  } deriving (Eq, Generic)

instance Hashable NameKind where
instance Hashable OccName where

-- | Useful to store things like visibility of an name inside a module
newtype OccEnv a = OccEnv (HashMap OccName a)
  deriving newtype (Semigroup, Monoid, Functor)

lookupEnv :: OccName -> OccEnv a -> Maybe a
lookupEnv name (OccEnv map) = HashMap.lookup name map

insertEnv :: OccName -> a -> OccEnv a -> OccEnv a
insertEnv name val (OccEnv map) = OccEnv (HashMap.insert name val map)

updateEnvWith :: OccName -> (a -> a) -> a -> OccEnv a -> OccEnv a
updateEnvWith name update cur (OccEnv env) = 
  let val = maybe cur update (HashMap.lookup name env) in
  OccEnv (HashMap.insert name val env)