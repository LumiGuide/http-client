{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Similar to Data.Pool from resource-pool, but resources are
-- identified by some key.
module Data.KeyedPool
    ( KeyedPool
    , createKeyedPool
    , takeKeyedPool
    , Managed
    , managedResource
    , managedReused
    , managedRelease
    , Reuse (..)
    , dummyManaged
    ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (mask_, catch, SomeException)
import Control.Monad (join, unless)
import Data.Map (Map)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, getCurrentTime, addUTCTime)
import Data.IORef (IORef, newIORef, mkWeakIORef)
import qualified Data.Foldable as F
import GHC.Conc (unsafeIOToSTM)
import System.IO.Unsafe (unsafePerformIO)

data KeyedPool key resource = KeyedPool
    { kpCreate :: !(key -> IO resource)
    , kpDestroy :: !(resource -> IO ())
    , kpMaxPerKey :: !Int
    , kpMaxTotal :: !Int
    , kpVar :: !(TVar (PoolMap key resource))
    , kpAlive :: !(IORef ())
    }

data PoolMap key resource
    = PoolClosed
    | PoolOpen
        {-# UNPACK #-} !Int
        -- ^ Total number of resources in the pool
        !(Map key (PoolList resource))
    deriving F.Foldable

-- | A non-empty list which keeps track of its own length and when
-- each resource was created.
data PoolList a
    = One a {-# UNPACK #-} !UTCTime
    | Cons
        a
        {-# UNPACK #-} !Int
        -- ^ size of the list from this point and on
        {-# UNPACK #-} !UTCTime
        !(PoolList a)
    deriving F.Foldable

plistToList :: PoolList a -> [(UTCTime, a)]
plistToList (One a t) = [(t, a)]
plistToList (Cons a _ t plist) = (t, a) : plistToList plist

plistFromList :: [(UTCTime, a)] -> Maybe (PoolList a)
plistFromList [] = Nothing
plistFromList [(t, a)] = Just (One a t)
plistFromList xs =
    Just . snd . go $ xs
  where
    go [] = error "plistFromList.go []"
    go [(t, a)] = (2, One a t)
    go ((t, a):rest) =
        let (i, rest') = go rest
            i' = i + 1
         in i' `seq` (i', Cons a i t rest')

-- | Create a new 'KeyedPool' which will automatically clean up after
-- itself when all referenced to the 'KeyedPool' are gone. It will
-- also fork a reaper thread to regularly kill off unused resource.
createKeyedPool
    :: Ord key
    => (key -> IO resource) -- ^ create a new resource
    -> (resource -> IO ()) -- ^ destroy a resource
    -> Int -- ^ number of resources per key to allow in the pool
    -> Int -- ^ number of resources to allow in the pool across all keys
    -> IO (KeyedPool key resource)
createKeyedPool create destroy maxPerKey maxTotal = do
    var <- newTVarIO $ PoolOpen 0 Map.empty
    _ <- forkIO $ reap destroy var

    -- We use a different IORef for the weak ref instead of the var
    -- above since the reaper thread will always be holding onto a
    -- reference.
    alive <- newIORef ()
    mkWeakIORef alive $ destroyKeyedPool' destroy var
    return KeyedPool
        { kpCreate = create
        , kpDestroy = destroy
        , kpMaxPerKey = maxPerKey
        , kpMaxTotal = maxTotal
        , kpVar = var
        , kpAlive = alive
        }

-- | Make a 'KeyedPool' inactive and destroy all idle resources.
destroyKeyedPool' :: (resource -> IO ())
                  -> TVar (PoolMap key resource)
                  -> IO ()
destroyKeyedPool' destroy var = do
    m <- atomically $ swapTVar var PoolClosed
    F.mapM_ destroy m

-- | Run a reaper thread, which will destroy old resources. It will
-- stop running once our pool switches to PoolClosed, which is handled
-- via the mkWeakIORef in the creation of the pool.
reap :: forall key resource.
        Ord key
     => (resource -> IO ())
     -> TVar (PoolMap key resource)
     -> IO ()
reap destroy var =
    loop
  where
    loop = do
        threadDelay (5 * 1000 * 1000)
        join $ atomically $ do
            m <- readTVar var
            case m of
                PoolClosed -> return (return ())
                PoolOpen idleCount m
                    | Map.null m -> retry
                    | otherwise -> do
                        (m', toDestroy) <- findStale idleCount m
                        writeTVar var m'
                        return $ do
                            mask_ (mapM_ safeDestroy toDestroy)
                            loop

    findStale :: Int
              -> Map key (PoolList resource)
              -> STM (PoolMap key resource, [resource])
    findStale idleCount m = do
        -- We want to make sure to get the time _after_ any delays
        -- occur due to the retry call above. Since getCurrentTime has
        -- no side effects outside of the STM block, this is a safe
        -- usage.
        now <- unsafeIOToSTM getCurrentTime
        let isNotStale time = 30 `addUTCTime` time >= now
        let findStale' toKeep toDestroy [] =
                (Map.fromList (toKeep []), toDestroy [])
            findStale' toKeep toDestroy ((key, plist):rest) =
                findStale' toKeep' toDestroy' rest
              where
                -- Note: By definition, the timestamps must be in
                -- descending order, so we don't need to traverse the
                -- whole list.
                (notStale, stale) = span (isNotStale . fst) $ plistToList plist
                toDestroy' = toDestroy . (map snd stale++)
                toKeep' =
                    case plistFromList notStale of
                        Nothing -> toKeep
                        Just x -> toKeep . ((key, x):)
        let (toKeep, toDestroy) = findStale' id id (Map.toList m)
        let idleCount' = idleCount - length toDestroy
        return (PoolOpen idleCount' toKeep, toDestroy)

    safeDestroy x = destroy x `catch` \(_ :: SomeException) -> return ()

-- | Check out a value from the 'KeyedPool' with the given key.
--
-- This function will internally call 'mask_' to ensure async safety,
-- and will return a value which uses weak references to ensure that
-- the value is cleaned up. However, if you want to ensure timely
-- resource cleanup, you should bracket this operation together with
-- 'managedRelease'.
takeKeyedPool :: Ord key => KeyedPool key resource -> key -> IO (Managed resource)
takeKeyedPool kp key = mask_ $ join $ atomically $ do
    (m, mresource) <- fmap go $ readTVar (kpVar kp)
    writeTVar (kpVar kp) $! m
    return $ do
        resource <- maybe (kpCreate kp key) return mresource
        alive <- newIORef ()
        isReleasedVar <- newTVarIO False

        let release action = mask_ $ do
                isReleased <- atomically $ swapTVar isReleasedVar True
                unless isReleased $
                    case action of
                        Reuse -> putResource kp key resource
                        DontReuse -> kpDestroy kp resource

        _ <- mkWeakIORef alive $ release DontReuse
        return Managed
            { _managedResource = resource
            , _managedReused = isJust mresource
            , _managedRelease = release
            , _managedAlive = alive
            }
  where
    go PoolClosed = (PoolClosed, Nothing)
    go pcOrig@(PoolOpen idleCount m) =
        case Map.lookup key m of
            Nothing -> (pcOrig, Nothing)
            Just (One a _) ->
                (PoolOpen (idleCount - 1) (Map.delete key m), Just a)
            Just (Cons a _ _ rest) ->
                (PoolOpen (idleCount - 1) (Map.insert key rest m), Just a)

-- | Try to return a resource to the pool. If too many resources
-- already exist, then just destroy it.
putResource :: Ord key => KeyedPool key resource -> key -> resource -> IO ()
putResource kp key resource = do
    now <- getCurrentTime
    join $ atomically $ do
        (m, action) <- fmap (go now) (readTVar (kpVar kp))
        writeTVar (kpVar kp) $! m
        return action
  where
    go _ PoolClosed = (PoolClosed, kpDestroy kp resource)
    go now pc@(PoolOpen idleCount m)
        | idleCount >= kpMaxTotal kp = (pc, kpDestroy kp resource)
        | otherwise = case Map.lookup key m of
            Nothing ->
                let cnt' = idleCount + 1
                    m' = PoolOpen cnt' (Map.insert key (One resource now) m)
                 in (m', return ())
            Just l ->
                let (l', mx) = addToList now (kpMaxPerKey kp) resource l
                    cnt' = idleCount + maybe 1 (const 0) mx
                    m' = PoolOpen cnt' (Map.insert key l' m)
                 in (m', maybe (return ()) (kpDestroy kp) mx)

-- | Add a new element to the list, up to the given maximum number. If we're
-- already at the maximum, return the new value as leftover.
addToList :: UTCTime -> Int -> a -> PoolList a -> (PoolList a, Maybe a)
addToList _ i x l | i <= 1 = (l, Just x)
addToList now _ x l@One{} = (Cons x 2 now l, Nothing)
addToList now maxCount x l@(Cons _ currCount _ _)
    | maxCount > currCount = (Cons x (currCount + 1) now l, Nothing)
    | otherwise = (l, Just x)

data Managed resource = Managed
    { _managedResource :: !resource
    , _managedReused :: !Bool
    , _managedRelease :: !(Reuse -> IO ())
    , _managedAlive :: !(IORef ())
    }

-- | Get the raw resource from the 'Managed' value.
managedResource :: Managed resource -> resource
managedResource = _managedResource

-- | Was this value taken from the pool?
managedReused :: Managed resource -> Bool
managedReused = _managedReused

-- | Release the resource, after which it is invalid to use the
-- 'managedResource' value. 'Reuse' returns the resource to the
-- pool; 'DontReuse' destroys it.
managedRelease :: Managed resource -> Reuse -> IO ()
managedRelease = _managedRelease

data Reuse = Reuse | DontReuse

-- | For testing purposes only: create a dummy Managed wrapper
dummyManaged :: resource -> Managed resource
dummyManaged resource = Managed
    { _managedResource = resource
    , _managedReused = False
    , _managedRelease = const (return ())
    , _managedAlive = unsafePerformIO (newIORef ())
    }
