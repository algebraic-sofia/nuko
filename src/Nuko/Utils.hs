module Nuko.Utils (
  flag,
  terminate
) where

import Control.Monad.Chronicle (MonadChronicle (confess, dictate))
import Relude

flag :: MonadChronicle (Endo [a]) m => a -> m ()
flag err = dictate $ Endo (err:)

terminate :: MonadChronicle (Endo [a]) m => a -> m b
terminate err = confess $ Endo (err:)

