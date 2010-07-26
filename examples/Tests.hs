import Control.Concurrent
import Control.Moio
import Control.Monad
import Control.Monad.Fix
import Data.Monoid

-- | A single shot producer that emits the given value at the given
-- time (in microseconds).
singleP :: Int -> a -> Producer a
singleP t x = mkP $ \s -> do
  threadDelay t
  s (Just x)
  s Nothing

-- | A pure producer that emits the given list of values at the given
-- absolute times (in microseconds).  Note that it starts up a
-- separate thread for each value...
listP :: [(Int, a)] -> Producer a
listP = mconcat . map (uncurry singleP)

-- | Execute a producer in IO and print its outputs as they arrive.
embedPrint :: (Show a) => Producer a -> IO ()
embedPrint e = embed (e >>= ioP . print)

-- Test #1: compare using actors and variables to create a stateful
-- computation (note that sharing with subscribe).
test1 :: IO (Sink Integer)
test1 = do
  (p, s) <- mkSink
  let p' input = do
        let count = countFrom 1
              where countFrom n = get $ \x -> put (n, x) (countFrom $! n+1)
            printPositive = get $ \(n, x) -> ioA $ do
              putStrLn $ "Fired (e'): " ++ show n ++ "."
              when (x > 0) $ print x
              return printPositive
        input >-> count >-> printPositive

      p'' input = do
        v <- ioP $ newMVar 1
        x <- input
        ioP $ do
          c <- takeMVar v
          putStrLn $ "Fired (e''): " ++ show c ++ "."
          putMVar v $! c+1
        guard (x > 0)
        ioP $ print x

  forkIO $ embed (subscribe p >>= \sp -> p' sp `mplus` p'' sp)
  return s

-- Test #2: merging producers.
test2 :: IO (Sink Integer, Sink Integer, Producer String)
test2 = do
  (p1, s1) <- mkSink
  (p2, s2) <- mkSink
  return (s1, s2, fmap (("p1 " ++).show) p1 `mplus` fmap (("p2 " ++).show) p2)

-- Test #3: starting parallel countdown timers.
test3 :: IO (Sink (String, Integer))
test3 = do
  (e, s) <- mkSink
  let e' = do
        (n, x) <- e
        t <- mkP $ \s -> do
          flip fix x $ \loop n -> do
            s (Just n)
            threadDelay 1000000
            if n > 0 then loop (n-1) else s Nothing
        return (n, t)
  forkIO $ embedPrint e'
  return s

-- Test #4: sharing the output of a countdown timer with subscribe.
test4 :: IO ThreadId
test4 = do
  let e = do
        let cnt = mkP $ \s -> do
              flip fix 5 $ \loop n -> do
                s (Just n)
                threadDelay 1000000
                if n > 0 then loop (n-1) else s Nothing
        cnt' <- subscribe cnt
        mconcat [fmap (showString "Producer " . shows n . showChar ' ' . show) cnt' | n <- [1..10]]
  forkIO $ embedPrint e

-- Test #5: performing dynamic actor application.
test5 :: IO ()
test5 = do
  let ets = listP [(1000000,fix (get . flip put)),(3000000,fix (get . flip (put . (+1000))))]
      xs = listP [(500000,1),(1500000,2),(2500000,3),(3500000,4),(4500000,5)]
  embedPrint $ xs ->> ets

{-

 Running tests in ghci:

 1.

 s <- test1
 s (Just 5)
 s (Just 12)
 s (Just (-4))
 s (Just 6)
 s Nothing
 s (Just 2)
 s (Just (-8))

 2.

 (s1,s2,e) <- test2
 forkIO $ embed e putStrLn
 s1 (Just 4)
 s1 (Just 2)
 s2 (Just 9)
 s2 (Just 3)
 s1 (Just 6)
 s2 (Just 5)
 s2 Nothing
 s1 (Just 10)
 s2 (Just 12)
 s1 Nothing
 s1 (Just 1)

 3.

 s <- test3
 s (Just ("First",20))
 s (Just ("Second",20))
 s (Just ("Third",30))
 s (Just ("Fourth",15))
 s Nothing
 s (Just ("Fifth",20))

 4.

 test4

 5.

 test5

-}
