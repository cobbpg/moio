{-|

Moio (Multiple-Occurrence IO) is a library of composable imperative
producers.  Its main goal is to allow the description of event-driven
systems without using explicit concurrency constructs, and to provide
a uniform way to deal with imperative libraries that might otherwise
require different programming styles.

-}

{-# OPTIONS_GHC -fno-warn-unused-do-bind -fno-warn-unused-binds #-}

module Control.Moio
  ( Sink
  , nop
  -- * Producers
  , Producer
  , subscribe
  , until
  , ioP
  , mkP
  -- ** Embedding producers into IO
  , embed
  , mkSink
  -- * Actors
  , Actor
  , done
  , put
  , get
  , ioA
  , mkA
  -- * Monadic actors
  , ActorM
  , halt
  , emit
  , fetch
  , ioAM
  -- * Interaction of actors and producers
  , (>->)
  , (<-<)
  , (>--)
  , (--<)
  , pToA
  , amToA
  , aToAM
  -- * Other derived combinators
  , (>*<)
  , (<<-)
  , (->>)
  ) where

import Control.Applicative
import Control.Category
import Control.Concurrent
import Control.Monad
import Control.Monad.Fix
import Data.IORef
import Data.Maybe
import Data.Monoid
import Prelude hiding (until, id, (.))

-- | An event sink. Passing @Nothing@ means end of transmission, and
-- after that the sink should behave as a nop.
type Sink a = Maybe a -> IO ()

-- | No operation.
nop :: IO ()
nop = return ()

-- | An effectful computation emitting a discrete stream of values.
-- It can be thought of as a variation of 'IO' that doesn't produce
-- just one value at the end of its execution, but keeps emitting
-- results during its life.
--
-- The meanings of the class instances:
--
-- * 'Monoid': @mempty@ is the empty producer that never emits
-- anything, and @mappend@ interleaves the output of two producers.
-- @mconcat@ is optimised.
--
-- * 'Functor': @fmap f p@ behaves the same way as @p@, but every
-- outgoing value is transformed by @f@.
--
-- * 'Applicative': @pure x@ is a single-shot producer that emits @x@
-- as soon as it is executed, then terminates. @pf \<*\> px@ applies
-- all the occurrences of @pf@ to the later occurrences of @px@.
-- Consequently, @f \<$\> p1 \<*\> p2 \<*\> p3 \<*\> ...@ is a
-- producer whose occurrences are the results of all the execution
-- paths where the occurrences of @p1@, @p2@, @p3@ and so on are in
-- increasing order of time.
--
-- * 'Monad': @return@ is the same as @pure@.  @p \>\>= k@ is a stream
-- of values obtained by applying @k@ to each occurrence of @p@,
-- forgetting about the outputs of the resulting producer that would
-- come before its creation time (i.e. the moment of applying @k@ to
-- the corresponding output of @p@), and interleaving all these
-- producers as they are created.  Alternatively, we can think of
-- @join p@ as a continuous merger, which interleaves every producer
-- coming from @p@ to create the final output.
--
-- * 'MonadPlus': @mzero@ is the same as @mempty@ and @mplus@ is the
-- same as @mappend@.  This instance allows the use of 'guard'.  Note
-- that @msum@ is not optimised, so @mconcat@ should always be used to
-- merge a list of producers.
newtype Producer a = P { unP :: Sink a -> IO () }

instance Functor Producer where
  fmap f (P p) = P $ \s -> p (s . fmap f)

instance Applicative Producer where
  pure = return
  pf <*> px = pf >>= flip fmap px

instance Monad Producer where
  return x = P $ \s -> s (Just x) >> s Nothing
  P p >>= k = P $ \s -> p (maybe (s Nothing) (($ s) . unP . k))
  fail _ = mzero

instance MonadPlus Producer where
  mzero = mempty
  mplus = mappend

instance Monoid (Producer a) where
  mempty = P ($ Nothing)
  P p1 `mappend` P p2 = P $ \s -> do
    v <- newEmptyMVar
    forkIO $ p1 (putMVar v)
    forkIO $ p2 (putMVar v)
    flip fix (2 :: Int) $ \loop n -> when (n > 0) $ do
      mx <- takeMVar v
      when (isJust mx || n == 1) (s mx)
      loop $! if isNothing mx then n-1 else n
  mconcat [] = mempty
  mconcat [p] = p
  mconcat ps = P $ \s -> do
    v <- newEmptyMVar
    forM_ ps $ \(P p) -> forkIO $ p (putMVar v)
    flip fix (length ps) $ \loop n -> when (n > 0) $ do
      mx <- takeMVar v
      when (isJust mx || n == 1) (s mx)
      loop $! if isNothing mx then n-1 else n

-- | Execute a producer in an IO context and ignore its output.
embed :: Producer x -> IO ()
embed (P p) = p (const nop)

-- | Create a producer with a corresponding sink to trigger it with.
mkSink :: IO (Producer a, Sink a)
mkSink = do
  v <- newEmptyMVar
  a <- newIORef (putMVar v)
  return (P $ \s -> fix $ \loop -> do
           mx <- takeMVar v
           forkIO $ s mx
           if isJust mx then loop else writeIORef a (const nop)
         ,\x -> readIORef a >>= ($ x)
         )

-- | A single-shot producer returning a copy of the given producer
-- without the side effects, just sharing the output of the original.
subscribe :: Producer a -> Producer (Producer a)
subscribe (P p) = mkP $ \s -> do
  c <- newChan
  forkIO $ p (writeChan c)
  let p' = mkP $ \s' -> do
        c' <- dupChan c
        fix $ \loop -> do
          mx <- readChan c'
          s' mx
          when (isJust mx) loop
  s (Just p')
  s Nothing

-- | A producer that acts like the second argument until the first
-- argument fires, which causes it to terminate instantly and drop
-- references to both constituent producers.  An alternative
-- definition with the same output (but keeping the constituents alive
-- until their termination):
--
-- @
--  until c p = (Just \<$\> p) \`mappend\` (Nothing \<$ c) \>-\> cutoff
--    where cutoff = get $ maybe done (flip put cutoff)
-- @
until :: Producer x -> Producer a -> Producer a
until (P c) (P p) = P $ \s -> do
  v <- newEmptyMVar
  tid <- forkIO $ p s
  c $ \_ -> do
    killThread tid
    s Nothing
    killThread =<< myThreadId

-- | A single-shot producer derived from an IO computation.  Can be
-- used as @liftIO@ in the Producer monad.
ioP :: IO a -> Producer a
ioP act = P $ \s -> act >>= \x -> s (Just x) >> s Nothing

-- | A possibly multiple-occurrence producer derived from an IO
-- computation that is given a sink to send values to.
mkP :: (Sink a -> IO ()) -> Producer a
mkP f = P $ \s -> do
  (P p, s') <- mkSink
  forkIO $ f s'
  p s

-- | Actor, i.e. event stream transformer, combinator style
-- (cf. fudgets).  Superficially, it can be thought of as a function
-- of type @Producer a -\> Producer b@.
newtype Actor a b = A { unA :: Chan (Maybe a) -> Sink b -> IO () }

instance Category Actor where
  id = A $ \i o -> fix $ \loop -> do
    mx <- readChan i
    o mx
    when (isJust mx) loop
  A f . A g = A $ \i o -> do
    c <- newChan
    forkIO $ f c o
    g i (writeChan c)

-- | The empty actor that terminates immediately.
done :: Actor a b
done = A $ \_ o -> o Nothing

-- | An actor that outputs its first argument and continues as its
-- second.
put :: b -> Actor a b -> Actor a b
put x (A a) = A $ \i o -> o (Just x) >> a i o

-- | An actor that waits for an input and calculates its continuation
-- from it using the given function.
get :: (a -> Actor a b) -> Actor a b
get f = A $ \i o -> do
  mx <- readChan i
  case mx of
    Nothing -> o Nothing
    Just x -> unA (f x) i o

-- | An actor that performs some IO action and continues as the result
-- of the action.
ioA :: IO (Actor a b) -> Actor a b
ioA act = A $ \i o -> act >>= \(A a) -> a i o

-- | A stoppable imperative source.  The function passed to 'mkA'
-- must return a pair of actions: the actual producer (as in 'mkP')
-- and a clean-up action to be executed when the stop signal (any
-- value) arrives on the input.  If the input to the resulting
-- transformer terminates without any occurrence, the clean-up action
-- is never invoked.
mkA :: (Sink a -> IO (IO (), IO ())) -> Actor x a
mkA f = A $ \i o -> do
  (P p, s) <- mkSink
  (go, stop) <- f s
  tid <- forkIO go
  forkIO $ do
    mx <- readChan i
    when (isJust mx) $ do
      stop
      killThread tid
      o Nothing
  p o

-- | An imperative actor that can be composed with producers and
-- constructed with monadic combinators.  It's basically
-- interchangeable with Actor, as shown by the existence of the
-- 'amToA' and 'aToAM' functions.
newtype ActorM i o a = AM { unAM :: Chan (Maybe i) -> Sink o -> (a -> IO ()) -> IO () }

instance Functor (ActorM i o) where
  fmap f (AM am) = AM $ \i o s -> am i o (s . f)

instance Applicative (ActorM i o) where
  pure = return
  amf <*> amx = amf >>= flip fmap amx

instance Monad (ActorM i o) where
  return x = AM $ \i o s -> s x
  AM am >>= k = AM $ \i o s -> am i o (\x -> unAM (k x) i o s)

-- | Wait for an input in the actor.  If the producer terminates, so
-- does the transformer.
fetch :: ActorM i o i
fetch = AM $ \i o s -> do
  mx <- readChan i
  case mx of
    Nothing -> o Nothing
    Just x -> s x

-- | Send an output in the actor.
emit :: o -> ActorM i o ()
emit x = AM $ \i o s -> o (Just x) >>= s

-- | Stop the transformer and signal its termination to the consumer.
halt :: ActorM i o ()
halt = AM $ \i o s -> o Nothing

-- | Perform IO in an actor.  Can be used as @liftIO@ in the (ActorM i
-- o) monad.
ioAM :: IO a -> ActorM i o a
ioAM act = AM $ \i o s -> act >>= s

-- | Converting monadic actors to simple ones that ignore the final
-- answer of the monad.
amToA :: ActorM a b x -> Actor a b
amToA (AM am) = A $ \i o -> am i o (const nop)

-- | Converting simple actors to monadic ones.
aToAM :: Actor a b -> ActorM a b x
aToAM (A a) = AM $ \i o s -> a i o

-- | Converting producers to actors that ignore their input.
pToA :: Producer a -> Actor x a
pToA (P p) = A $ \i o -> p o

infixl 1 >--
infixl 1 >->
infixr 1 --<
infixr 1 <-<

-- | Compose a producer with a monadic actor.  The actor automatically
-- halts when it requests a value after the producer is done.  The two
-- components will run in parallel.
(>--) :: Producer a -> ActorM a b x -> Producer b
P p >-- AM t = P $ \s -> do
  c <- newChan
  forkIO $ t c s (const nop)
  p (writeChan c)

-- | '>--' with its arguments flipped.  Fits nicely in do notation.
(--<) :: ActorM a b x -> Producer a -> Producer b
(--<) = flip (>--)

-- | Compose a producer with a simple actor.  The actor automatically
-- halts when it requests a value after the producer is done.  The two
-- components will run in parallel.
(>->) :: Producer a -> Actor a b -> Producer b
P p >-> A a = P $ \s -> do
  c <- newChan
  forkIO $ a c s
  p (writeChan c)

-- | '>->' with its arguments flipped.  Fits nicely in do notation.
(<-<) :: Actor a b -> Producer a -> Producer b
(<-<) = flip (>->)

-- | Parallel application: given a producer of functions and a
-- producer of values, create a producer that emits the results of
-- always applying the latest function to the latest value.
(>*<) :: Producer (a -> b) -> Producer a -> Producer b
pf >*< px = (Left <$> pf) `mappend` (Right <$> px) >-> apply Nothing Nothing
  where apply mf mx = get $ \efx -> case efx of
          Left f -> maybe id (put . f) mx (apply (Just f) mx)
          Right x -> maybe id (put . ($ x)) mf (apply mf (Just x))

-- | Dynamic application: given a producer of actors and a producer
-- that can be the input of those actors, emit the results of always
-- running the latest actor on the input stream.
(<<-) :: Producer (Actor a b) -> Producer a -> Producer b
pf <<- px = do
  pf' <- subscribe pf
  px' <- subscribe px
  f <- pf
  until pf' (px' >-> f)

-- | '<<-' with its arguments flipped.
(->>) :: Producer a -> Producer (Actor a b) -> Producer b
(->>) = flip (<<-)
