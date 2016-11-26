{-# LANGUAGE DeriveFoldable, DeriveTraversable, TupleSections #-}
-- | AI strategies to direct actors not controlled directly by human players.
-- No operation in this module involves the 'State' or 'Action' type.
module Game.LambdaHack.Client.AI.Strategy
  ( Strategy, nullStrategy, liftFrequency
  , (.|), reject, (.=>), only, bestVariant, renameStrategy, returN, mapStrategyM
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Control.Applicative

import Game.LambdaHack.Common.Frequency as Frequency

-- | A strategy is a choice of (non-empty) frequency tables
-- of possible actions.
newtype Strategy a = Strategy { runStrategy :: [Frequency a] }
  deriving (Show, Foldable, Traversable)

-- | Strategy is a monad.
instance Monad Strategy where
  {-# INLINE return #-}
  return x = Strategy $ return $! uniformFreq "Strategy_return" [x]
  {-# INLINABLE (>>=) #-}
  m >>= f  = normalizeStrategy $ Strategy
    [ toFreq name [ (p * q, b)
                  | (p, a) <- runFrequency x
                  , y <- runStrategy (f a)
                  , (q, b) <- runFrequency y
                  ]
    | x <- runStrategy m
    , let name = "Strategy_bind (" <> nameFrequency x <> ")"]

instance Functor Strategy where
  {-# INLINABLE fmap #-}
  fmap f (Strategy fs) = Strategy (map (fmap f) fs)

instance Applicative Strategy where
  pure  = return
  (<*>) = ap

instance MonadPlus Strategy where
  {-# INLINABLE mzero #-}
  mzero = Strategy []
  {-# INLINABLE mplus #-}
  mplus (Strategy xs) (Strategy ys) = Strategy (xs ++ ys)

instance Alternative Strategy where
  (<|>) = mplus
  empty = mzero

normalizeStrategy :: Strategy a -> Strategy a
{-# INLINABLE normalizeStrategy #-}
normalizeStrategy (Strategy fs) = Strategy $ filter (not . nullFreq) fs

nullStrategy :: Strategy a -> Bool
{-# INLINABLE nullStrategy #-}
nullStrategy strat = null $ runStrategy strat

-- | Strategy where only the actions from the given single frequency table
-- can be picked.
liftFrequency :: Frequency a -> Strategy a
{-# INLINABLE liftFrequency #-}
liftFrequency f = normalizeStrategy $ Strategy $ return f

infixr 2 .|

-- | Strategy with the actions from both argument strategies,
-- with original frequencies.
(.|) :: Strategy a -> Strategy a -> Strategy a
(.|) = mplus

-- | Strategy with no actions at all.
reject :: Strategy a
reject = mzero

infix 3 .=>

-- | Conditionally accepted strategy.
(.=>) :: Bool -> Strategy a -> Strategy a
{-# INLINABLE (.=>) #-}
p .=> m | p         = m
        | otherwise = mzero

-- | Strategy with all actions not satisfying the predicate removed.
-- The remaining actions keep their original relative frequency values.
only :: (a -> Bool) -> Strategy a -> Strategy a
{-# INLINABLE only #-}
only p s = normalizeStrategy $ do
  x <- s
  p x .=> return x

-- | When better choices are towards the start of the list,
-- this is the best frequency of the strategy.
bestVariant :: Strategy a -> Frequency a
{-# INLINABLE bestVariant #-}
bestVariant (Strategy []) = mzero
bestVariant (Strategy (f : _)) = f

-- | Overwrite the description of all frequencies within the strategy.
renameStrategy :: Text -> Strategy a -> Strategy a
{-# INLINABLE renameStrategy #-}
renameStrategy newName (Strategy fs) = Strategy $ map (renameFreq newName) fs

-- | Like 'return', but pick a name of the single frequency.
returN :: Text -> a -> Strategy a
{-# INLINABLE returN #-}
returN name x = Strategy $ return $! uniformFreq name [x]

-- TODO: express with traverse?
mapStrategyM :: Monad m => (a -> m (Maybe b)) -> Strategy a -> m (Strategy b)
{-# INLINABLE mapStrategyM #-}
mapStrategyM f s = do
  let mapFreq freq = do
        let g (k, a) = do
              mb <- f a
              return $! (k,) <$> mb
        lbm <- mapM g $ runFrequency freq
        return $! toFreq "mapStrategyM" $ catMaybes lbm
      ls = runStrategy s
  lt <- mapM mapFreq ls
  return $! normalizeStrategy $ Strategy lt
