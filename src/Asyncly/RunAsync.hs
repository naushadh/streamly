{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : Asyncly.Threads
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : MIT-style
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
module Asyncly.RunAsync
    ( AsynclyT
    , runAsyncly
    , toList
    , each
    , threads
    , runAsynclyRecorded
--    , toListRecorded
    , playRecordings
    )
where

import           Control.Applicative         (Alternative (..))
import           Control.Concurrent.STM      (atomically, newTChan)
import           Control.Monad               (liftM)
import           Control.Monad.Catch         (MonadThrow)
import           Control.Monad.IO.Class      (MonadIO (..))
import           Control.Monad.Trans.Class   (MonadTrans (lift))
import           Control.Monad.State         (StateT(..), runStateT)
import           Data.IORef                  (IORef, newIORef, readIORef)

import           Control.Monad.Trans.Recorder (MonadRecorder(..), RecorderT,
                                               Recording, blank, runRecorderT)
import           Asyncly.Threads
import           Asyncly.AsyncT

-- This transformer runs AsyncT under a state to manage the threads.
-- Separating the state from the pure ListT transformer is cleaner but it
-- results in 2x performance degradation. At some point if that performance is
-- really needed we can combine the two.

newtype AsynclyT m a = AsynclyT { runAsynclyT :: AsyncT (StateT Context m) a }

deriving instance Monad m => Functor (AsynclyT m)
deriving instance Monad m => Applicative (AsynclyT m)
deriving instance Monad m => Alternative (AsynclyT m)
deriving instance Monad m => Monad (AsynclyT m)
deriving instance MonadIO m => MonadIO (AsynclyT m)
deriving instance MonadThrow m => MonadThrow (AsynclyT m)
instance MonadTrans (AsynclyT) where
    lift mx = AsynclyT $ AsyncT $ \_ k -> lift mx >>= (\a -> (k a Nothing))

-- XXX orphan instance, use a newtype instead?
instance (Monad m, MonadRecorder m)
    => MonadRecorder (StateT Context m) where
    getJournal = lift getJournal
    putJournal = lift . putJournal
    play = lift . play

deriving instance (Monad m, MonadRecorder m)
    => MonadRecorder (AsynclyT m)

------------------------------------------------------------------------------
-- Running the monad
------------------------------------------------------------------------------

getContext :: Maybe (IORef [Recording]) -> IO Context
getContext lref = do
    childChan  <- atomically newTChan
    pendingRef <- newIORef []
    credit     <- newIORef maxBound
    return $ initContext childChan pendingRef credit lref

-- | Run an 'AsynclyT m' computation, wait for it to finish and discard the
-- results.
{-# INLINABLE runAsynclyLogged #-}
runAsynclyLogged :: MonadAsync m
    => Maybe (IORef [Recording]) -> AsynclyT m a -> m ()
runAsynclyLogged lref (AsynclyT m) = do
    ctx <- liftIO $ getContext lref
    _ <- runStateT (run m) ctx
    return ()

    where

    stop = return ()
    run mx = (runAsyncT mx) stop (\_ r -> maybe stop run r)

runAsyncly :: MonadAsync m => AsynclyT m a -> m ()
runAsyncly m = runAsynclyLogged Nothing m

data Step a r = Stop | Done a | Yield a r

-- | Run an 'AsynclyT m' computation and collect the results generated by each
-- thread of the computation in a list.
{-# INLINABLE toList #-}
toList :: MonadAsync m => AsynclyT m a -> m [a]
toList (AsynclyT m) = liftIO (getContext Nothing) >>= run m

    where

    stop = return Stop
    done a = return (Done a)
    yield a x = return $ Yield a x

    run ma ctx = do
        (res, ctx') <- runStateT
            ((runAsyncT ma) stop (\a r -> maybe (done a) (\x -> yield a x) r))
            ctx
        case res of
            Yield x mb -> liftM (x :) (run mb ctx')
            Stop -> return []
            Done x -> return (x : [])

{-# INLINABLE each #-}
each :: MonadAsync m => [a] -> AsynclyT m a
each xs = foldr (<|>) empty $ map return xs

------------------------------------------------------------------------------
-- Controlling thread quota
------------------------------------------------------------------------------

-- | Runs a computation under a given thread limit.  A limit of 0 means all new
-- tasks start synchronously in the current thread unless overridden by
-- 'async'.
threads :: MonadAsync m => Int -> AsynclyT m a -> AsynclyT m a
threads n action = AsynclyT $ AsyncT $ \stp yld ->
    threadCtl n ((runAsyncT $ runAsynclyT action) stp yld)

------------------------------------------------------------------------------
-- Logging
------------------------------------------------------------------------------

-- | Compose a computation using previously captured logs
playRecording :: (MonadAsync m, MonadRecorder m)
    => AsynclyT m a -> Recording -> AsynclyT m a
playRecording m recording = play recording >> m

-- | Resume an 'AsyncT' computation using previously recorded logs. The
-- recording consists of a list of journals one for each thread in the
-- computation.
playRecordings :: (MonadAsync m, MonadRecorder m)
    => AsynclyT m a -> [Recording] -> AsynclyT m a
playRecordings m logs = each logs >>= playRecording m

{-
-- | Run an 'AsyncT' computation with recording enabled, wait for it to finish
-- returning results for completed threads and recordings for paused threads.
toListRecorded :: (MonadAsync m, MonadCatch m)
    => AsynclyT m a -> m ([a], [Recording])
toListRecorded m = do
    resultsRef <- liftIO $ newIORef []
    lref <- liftIO $ newIORef []
    waitAsync (gatherResult resultsRef) (Just lref) m
    res <- liftIO $ readIORef resultsRef
    logs <- liftIO $ readIORef lref
    return (res, logs)
    -}

-- | Run an 'AsyncT' computation with recording enabled, wait for it to finish
-- and discard the results and return the recordings for paused threads, if
-- any.
runAsynclyRecorded :: MonadAsync m => AsynclyT (RecorderT m) a -> m [Recording]
runAsynclyRecorded m = do
    lref <- liftIO $ newIORef []
    runRecorderT blank (runAsynclyLogged (Just lref) m)
    logs <- liftIO $ readIORef lref
    return logs