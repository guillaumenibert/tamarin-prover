{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PatternGuards #-}
-- Copyright   : (c) 2019 Robert Künnemann 
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Robert Künnemann <robert@kunnemann.de>
-- Portability : GHC only
--
-- Utilities for processes
module Sapic.ProcessUtils (
   processAt 
,  processContains
,  isLookup
,  isEq
,  isDelete
,  isLock
,  isUnlock
) where
-- import Data.Maybe
-- import Data.Foldable
-- import Control.Exception
-- import Control.Monad.Fresh
import Data.Typeable
import Control.Monad.Catch
import qualified Data.Monoid            as M
-- import Sapic.Exceptions
-- import Theory
import Theory.Sapic
import Sapic.Exceptions
-- import Theory.Model.Rule
-- import Data.Typeable
-- import qualified Data.Set                   as S
-- import Control.Monad.Trans.FastFresh

-- | Return subprocess at position p. Throw exceptions if p is an invalid
-- positions. 
processAt :: forall ann m v. (Show ann, MonadThrow m, MonadCatch m, Typeable ann, Typeable v, Show v) =>  Process ann v -> ProcessPosition -> m (Process ann v)
processAt p [] = return p
processAt (ProcessNull _) (x:xs) = throwM (InvalidPosition (x:xs) :: SapicException (Process ann v))
processAt pro pos 
    | (ProcessAction _ _ p ) <- pro,  1:xl <- pos =  catch (processAt p xl) (h pos)
    | (ProcessComb _ _ pl _) <- pro,  1:xl <- pos =  catch (processAt pl xl) (h pos)
    | (ProcessComb _ _ _ pr) <- pro,  2:xl <- pos =  catch (processAt pr xl) (h pos)
    where --- report original position by catching exception at each level in error case.
        h:: ProcessPosition -> SapicException (Process ann v) -> m (Process ann v)
        h p (InvalidPosition _) = throwM ( InvalidPosition p :: SapicException (Process ann v))
        h _ e = throwM e
processAt _ p = throwM (InvalidPosition p :: SapicException (Process ann v))

processContains :: Process ann v -> (Process ann v -> Bool) -> Bool
processContains anP f = M.getAny $ pfoldMap  (M.Any . f) anP

isLookup :: Process ann v -> Bool
isLookup (ProcessComb (Lookup _ _) _ _ _) = True
isLookup _  = False

isDelete :: Process ann v -> Bool
isDelete (ProcessAction (Delete _) _ _) = True
isDelete _  = False

isLock :: Process ann v -> Bool
isLock (ProcessAction (Lock _) _ _) = True
isLock _  = False

isUnlock :: Process ann v -> Bool
isUnlock (ProcessAction (Unlock _) _ _) = True
isUnlock _  = False

isEq :: Process ann v -> Bool
isEq (ProcessComb (CondEq _ _) _ _ _) = True
isEq _  = False

