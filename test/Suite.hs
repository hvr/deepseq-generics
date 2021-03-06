{-# LANGUAGE CPP, TupleSections, DeriveDataTypeable, DeriveGeneric #-}

module Main (main) where

import Control.Concurrent.MVar
import Control.DeepSeq
import Control.Exception
import Control.Monad
import Data.Bits
import Data.IORef
import Data.Typeable
import Data.Word
import GHC.Generics
import System.IO.Unsafe (unsafePerformIO)

-- import Test.Framework (defaultMain, testGroup, testCase)
import Test.Framework
import Test.Framework.Providers.HUnit
import Test.HUnit

-- IUT
import Control.DeepSeq.Generics

-- needed for GHC-7.4 compatibility
#if !MIN_VERSION_base(4,6,0)
atomicModifyIORef' :: IORef a -> (a -> (a,b)) -> IO b
atomicModifyIORef' ref f = do
    b <- atomicModifyIORef ref
            (\x -> let (a, b) = f x
                    in (a, a `seq` b))
    b `seq` return b
#endif

----------------------------------------------------------------------------
-- simple hacky abstraction for testing forced evaluation via `rnf`-like functions

seqStateLock :: MVar ()
seqStateLock = unsafePerformIO $ newMVar ()
{-# NOINLINE seqStateLock #-}

withSeqState :: Word64 -> IO () -> IO ()
withSeqState expectedState act = withMVar seqStateLock $ \() -> do
    0  <- resetSeqState
    () <- act
    st <- resetSeqState
    unless (st == expectedState) $
        assertFailure ("withSeqState: actual seq-state ("++show st++") doesn't match expected value ("++
                       show expectedState++")")

seqState :: IORef Word64
seqState = unsafePerformIO $ newIORef 0
{-# NOINLINE seqState #-}

resetSeqState :: IO Word64
resetSeqState = atomicModifyIORef' seqState (0,)

-- |Set flag and raise exception is flag already set
setSeqState :: Int -> IO ()
setSeqState i | 0 <= i && i < 64 = atomicModifyIORef' seqState go
              | otherwise        = error "seqSeqState: flag index must be in [0..63]"
  where
    go x | testBit x i = error ("setSeqState: flag #"++show i++" already set")
         | otherwise   = (setBit x i, ())

-- weird type whose NFData instacne calls 'setSeqState' when rnf-ed
data SeqSet = SeqSet !Int | SeqIgnore
              deriving Show

instance NFData SeqSet where
    rnf (SeqSet i)  = unsafePerformIO $ setSeqState i
    rnf (SeqIgnore) = ()
    {-# NOINLINE rnf #-}

-- |Exception to be thrown for testing 'seq'/'rnf'
data RnfEx = RnfEx deriving (Eq, Show, Typeable)

instance Exception RnfEx

instance NFData RnfEx where rnf e = throw e

assertRnfEx :: () -> IO ()
assertRnfEx v = handleJust isWanted (const $ return ()) $ do
    () <- evaluate v
    assertFailure "failed to trigger expected RnfEx exception"
  where isWanted = guard . (== RnfEx)

----------------------------------------------------------------------------

case_1, case_2, case_3, case_4_1, case_4_2, case_4_3, case_4_4 :: Test.Framework.Test

newtype Case1 = Case1 Int
              deriving Generic
case_1 = testCase "Case1" $ do
    assertRnfEx $ genericRnf $ (Case1 (throw RnfEx))

----

data Case2 = Case2 Int
           deriving Generic
case_2 = testCase "Case2" $ do
    assertRnfEx $ genericRnf $ (Case2 (throw RnfEx))

----

data Case3 = Case3 RnfEx
           deriving Generic
case_3 = testCase "Case3" $ do
    assertRnfEx $ genericRnf $ Case3 RnfEx

----

data Case4 a = Case4a
             | Case4b a a
             | Case4c a (Case4 a)
             deriving Generic
instance NFData a => NFData (Case4 a) where rnf = genericRnf

case_4_1 = testCase "Case4.1" $ withSeqState 0x0 $ do
    evaluate $ rnf $ (Case4a :: Case4 SeqSet)

case_4_2 = testCase "Case4.2" $ withSeqState 0x3 $ do
    evaluate $ rnf $ (Case4b (SeqSet 0) (SeqSet 1) :: Case4 SeqSet)

case_4_3 = testCase "Case4.3" $ withSeqState (bit 55) $ do
    evaluate $ rnf $ (Case4b SeqIgnore (SeqSet 55) :: Case4 SeqSet)

case_4_4 = testCase "Case4.4" $ withSeqState 0xffffffffffffffff $ do
    evaluate $ rnf $ (genCase 63)
  where
    genCase n | n > 1      = Case4c (SeqSet n) (genCase (n-1))
              | otherwise  = Case4b (SeqSet 0) (SeqSet 1)

----------------------------------------------------------------------------

main :: IO ()
main = defaultMain [tests]
  where
    tests = testGroup "" [case_1, case_2, case_3, case_4_1, case_4_2, case_4_3, case_4_4]
