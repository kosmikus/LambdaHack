{-# LANGUAGE FlexibleContexts #-}
-- | Operations concerning dungeon level tiles.
--
-- Unlike for many other content types, there is no type @Tile@,
-- of particular concrete tiles in the dungeon,
-- corresponding to 'TileKind' (the type of kinds of terrain tiles).
-- This is because the tiles are too numerous and there's not enough
-- storage space for a well-rounded @Tile@ type, on one hand,
-- and on the other hand, tiles are accessed
-- too often in performance critical code
-- to try to compress their representation and/or recompute them.
-- Instead, of defining a @Tile@ type, we express various properties
-- of concrete tiles by arrays or sparse EnumMaps, as appropriate.
--
-- Actors at normal speed (2 m/s) take one turn to move one tile (1 m by 1 m).
module Game.LambdaHack.Common.Tile
  ( -- * Construction of tile property lookup speedup tables
    speedupTile
    -- * Sped up property lookups
  , isClear, isLit, isWalkable, isDoor, isChangable
  , isSuspect, isHideAs, consideredByAI, isExplorable
  , isOftenItem, isOftenActor, isNoItem, isNoActor, isEasyOpen
  , alterMinSkill, alterMinWalk
    -- * Slow property lookups
  , kindHasFeature, hasFeature, openTo, closeTo, embeddedItems, revealAs
  , obscureAs, hideAs, buildAs, isEasyOpenKind, isOpenable, isClosable
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , createTab, createTabWithKey, accessTab, alterMinSkillKind, alterMinWalkKind
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.Vector.Unboxed as U
import           Data.Word (Word8)

import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.Random
import           Game.LambdaHack.Content.ItemKind (ItemKind)
import           Game.LambdaHack.Content.TileKind (TileKind, TileSpeedup (..),
                                                   isUknownSpace)
import qualified Game.LambdaHack.Content.TileKind as TK

createTab :: U.Unbox a => ContentData TileKind -> (TileKind -> a) -> TK.Tab a
createTab cotile prop =
  let f _ t acc = prop t : acc
  in TK.Tab $ U.fromListN (fromEnum $ olength cotile)
     $ ofoldrWithKey cotile f []

createTabWithKey :: U.Unbox a
                 => ContentData TileKind -> (ContentId TileKind -> TileKind -> a)
                 -> TK.Tab a
createTabWithKey cotile prop =
  let f k t acc = prop k t : acc
  in TK.Tab $ U.fromListN (fromEnum $ olength cotile)
     $ ofoldrWithKey cotile f []

-- Unsafe indexing is pretty safe here, because we guard the vector
-- with the newtype.
accessTab :: U.Unbox a => TK.Tab a -> ContentId TileKind -> a
{-# INLINE accessTab #-}
accessTab (TK.Tab tab) ki = tab `U.unsafeIndex` fromEnum ki

speedupTile :: Bool -> ContentData TileKind -> TileSpeedup
speedupTile allClear cotile =
  -- Vectors pack bools as Word8 by default. No idea if the extra memory
  -- taken makes random lookups more or less efficient, so not optimizing
  -- further, until I have benchmarks.
  let isClearTab | allClear = createTab cotile
                              $ not . (== maxBound) . TK.talter
                 | otherwise = createTab cotile
                               $ kindHasFeature TK.Clear
      isLitTab = createTab cotile $ not . kindHasFeature TK.Dark
      isWalkableTab = createTab cotile $ kindHasFeature TK.Walkable
      isDoorTab = createTab cotile $ \tk ->
        let getTo TK.OpenTo{} = True
            getTo TK.CloseTo{} = True
            getTo _ = False
        in any getTo $ TK.tfeature tk
      isChangableTab = createTab cotile $ \tk ->
        let getTo TK.ChangeTo{} = True
            getTo _ = False
        in any getTo $ TK.tfeature tk
      isSuspectTab = createTab cotile TK.isSuspectKind
      isHideAsTab = createTab cotile $ \tk ->
        let getTo TK.HideAs{} = True
            getTo _ = False
        in any getTo $ TK.tfeature tk
      consideredByAITab = createTab cotile $ kindHasFeature TK.ConsideredByAI
      isOftenItemTab = createTab cotile $ kindHasFeature TK.OftenItem
      isOftenActorTab = createTab cotile $ kindHasFeature TK.OftenActor
      isNoItemTab = createTab cotile $ kindHasFeature TK.NoItem
      isNoActorTab = createTab cotile $ kindHasFeature TK.NoActor
      isEasyOpenTab = createTab cotile isEasyOpenKind
      alterMinSkillTab = createTabWithKey cotile alterMinSkillKind
      alterMinWalkTab = createTabWithKey cotile alterMinWalkKind
  in TileSpeedup {..}

-- Check that alter can be used, if not, @maxBound@.
-- For now, we assume only items with @Embed@ may have embedded items,
-- whether inserted at dungeon creation or later on.
-- This is used by UI and server to validate (sensibility of) altering.
-- See the comment for @alterMinWalkKind@ regarding @HideAs@.
alterMinSkillKind :: ContentId TileKind -> TileKind -> Word8
alterMinSkillKind _k tk =
  let getTo TK.OpenTo{} = True
      getTo TK.CloseTo{} = True
      getTo TK.ChangeTo{} = True
      getTo TK.HideAs{} = True  -- in case tile swapped, but server sends hidden
      getTo TK.RevealAs{} = True
      getTo TK.ObscureAs{} = True
      getTo TK.Embed{} = True
      getTo TK.ConsideredByAI = True
      getTo _ = False
  in if any getTo $ TK.tfeature tk then TK.talter tk else maxBound

-- How high alter skill is needed to make it walkable. If already
-- walkable, put @0@, if can't, put @maxBound@. Used only be AI and Bfs
-- We don't include @HideAs@, because it's very unlikely anybody swapped
-- the tile while AI was not looking so AI can assume it's still uninteresting.
-- Pathfinding in UI will also not show such tile as passable, which is OK.
-- If a human player has a suspicion the tile was swapped, he can check
-- it manually, disregarding the displayed path hints.
alterMinWalkKind :: ContentId TileKind -> TileKind -> Word8
alterMinWalkKind k tk =
  let getTo TK.OpenTo{} = True
      getTo TK.RevealAs{} = True
      getTo TK.ObscureAs{} = True
      getTo _ = False
  in if | kindHasFeature TK.Walkable tk -> 0
        | isUknownSpace k -> TK.talter tk
        | any getTo $ TK.tfeature tk -> TK.talter tk
        | otherwise -> maxBound

-- | Whether a tile does not block vision.
-- Essential for efficiency of "FOV", hence tabulated.
isClear :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isClear #-}
isClear TileSpeedup{isClearTab} = accessTab isClearTab

-- | Whether a tile has ambient light --- is lit on its own.
-- Essential for efficiency of "Perception", hence tabulated.
isLit :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isLit #-}
isLit TileSpeedup{isLitTab} = accessTab isLitTab

-- | Whether actors can walk into a tile.
-- Essential for efficiency of pathfinding, hence tabulated.
isWalkable :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isWalkable #-}
isWalkable TileSpeedup{isWalkableTab} = accessTab isWalkableTab

-- | Whether a tile is a door, open or closed.
-- Essential for efficiency of pathfinding, hence tabulated.
isDoor :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isDoor #-}
isDoor TileSpeedup{isDoorTab} = accessTab isDoorTab

-- | Whether a tile is changable.
isChangable :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isChangable #-}
isChangable TileSpeedup{isChangableTab} = accessTab isChangableTab

-- | Whether a tile is suspect.
-- Essential for efficiency of pathfinding, hence tabulated.
isSuspect :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isSuspect #-}
isSuspect TileSpeedup{isSuspectTab} = accessTab isSuspectTab

isHideAs :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isHideAs #-}
isHideAs TileSpeedup{isHideAsTab} = accessTab isHideAsTab

consideredByAI :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE consideredByAI #-}
consideredByAI TileSpeedup{consideredByAITab} = accessTab consideredByAITab

-- | Whether one can easily explore a tile, possibly finding a treasure,
-- either spawned there or dropped there by a (dying from poison) foe.
-- Doors can't be explorable since revealing a secret tile
-- should not change it's (walkable and) explorable status.
-- Door status should not depend on whether they are open or not
-- so that a foe opening a door doesn't force us to backtrack to explore it.
-- Still, a foe that digs through a wall will affect our exploration counter
-- and if content lets walls contain threasure, such backtraking makes sense.
isExplorable :: TileSpeedup -> ContentId TileKind -> Bool
isExplorable coTileSpeedup t =
  isWalkable coTileSpeedup t && not (isDoor coTileSpeedup t)

isOftenItem :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isOftenItem #-}
isOftenItem TileSpeedup{isOftenItemTab} = accessTab isOftenItemTab

isOftenActor :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isOftenActor #-}
isOftenActor TileSpeedup{isOftenActorTab} = accessTab isOftenActorTab

isNoItem :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isNoItem #-}
isNoItem TileSpeedup{isNoItemTab} = accessTab isNoItemTab

isNoActor :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isNoActor #-}
isNoActor TileSpeedup{isNoActorTab} = accessTab isNoActorTab

-- | Whether a tile kind (specified by its id) has an OpenTo feature
-- and reasonable alter min skill.
isEasyOpen :: TileSpeedup -> ContentId TileKind -> Bool
{-# INLINE isEasyOpen #-}
isEasyOpen TileSpeedup{isEasyOpenTab} = accessTab isEasyOpenTab

alterMinSkill :: TileSpeedup -> ContentId TileKind -> Int
{-# INLINE alterMinSkill #-}
alterMinSkill TileSpeedup{alterMinSkillTab} =
  fromEnum . accessTab alterMinSkillTab

alterMinWalk :: TileSpeedup -> ContentId TileKind -> Int
{-# INLINE alterMinWalk #-}
alterMinWalk TileSpeedup{alterMinWalkTab} =
  fromEnum . accessTab alterMinWalkTab

-- | Whether a tile kind has the given feature.
kindHasFeature :: TK.Feature -> TileKind -> Bool
{-# INLINE kindHasFeature #-}
kindHasFeature f t = f `elem` TK.tfeature t

-- | Whether a tile kind (specified by its id) has the given feature.
hasFeature :: ContentData TileKind -> TK.Feature -> ContentId TileKind -> Bool
{-# INLINE hasFeature #-}
hasFeature cotile f t = kindHasFeature f (okind cotile t)

openTo :: ContentData TileKind -> ContentId TileKind -> Rnd (ContentId TileKind)
openTo cotile t = do
  let getTo (TK.OpenTo grp) acc = grp : acc
      getTo _ acc = acc
  case foldr getTo [] $ TK.tfeature $ okind cotile t of
    [grp] -> fromMaybe (error $ "" `showFailure` grp)
             <$> opick cotile grp (const True)
    _ -> return t

closeTo :: ContentData TileKind -> ContentId TileKind
        -> Rnd (ContentId TileKind)
closeTo cotile t = do
  let getTo (TK.CloseTo grp) acc = grp : acc
      getTo _ acc = acc
  case foldr getTo [] $ TK.tfeature $ okind cotile t of
    [grp] -> fromMaybe (error $ "" `showFailure` grp)
             <$> opick cotile grp (const True)
    _ -> return t

embeddedItems :: ContentData TileKind -> ContentId TileKind
              -> [GroupName ItemKind]
embeddedItems cotile t =
  let getTo (TK.Embed igrp) acc = igrp : acc
      getTo _ acc = acc
  in foldr getTo [] $ TK.tfeature $ okind cotile t

revealAs :: ContentData TileKind -> ContentId TileKind
         -> Rnd (ContentId TileKind)
revealAs cotile t = do
  let getTo (TK.RevealAs grp) acc = grp : acc
      getTo _ acc = acc
  case foldr getTo [] $ TK.tfeature $ okind cotile t of
    [] -> return t
    groups -> do
      grp <- oneOf groups
      fromMaybe (error $ "" `showFailure` grp) <$> opick cotile grp (const True)

obscureAs :: ContentData TileKind -> ContentId TileKind
          -> Rnd (ContentId TileKind)
obscureAs cotile t = do
  let getTo (TK.ObscureAs grp) acc = grp : acc
      getTo _ acc = acc
  case foldr getTo [] $ TK.tfeature $ okind cotile t of
    [] -> return t
    groups -> do
      grp <- oneOf groups
      fromMaybe (error $ "" `showFailure` grp) <$> opick cotile grp (const True)

hideAs :: ContentData TileKind -> ContentId TileKind
       -> Maybe (ContentId TileKind)
hideAs cotile t =
  let getTo TK.HideAs{} = True
      getTo _ = False
  in case find getTo $ TK.tfeature $ okind cotile t of
       Just (TK.HideAs grp) ->
         let tHidden = ouniqGroup cotile grp
         in assert (tHidden /= t) $ Just tHidden
       _ -> Nothing

buildAs :: ContentData TileKind -> ContentId TileKind -> ContentId TileKind
buildAs cotile t =
  let getTo TK.BuildAs{} = True
      getTo _ = False
  in case find getTo $ TK.tfeature $ okind cotile t of
       Just (TK.BuildAs grp) -> ouniqGroup cotile grp
       _ -> t

isEasyOpenKind :: TileKind -> Bool
isEasyOpenKind tk =
  let getTo TK.OpenTo{} = True
      getTo TK.Walkable = True  -- very easy open
      getTo _ = False
  in TK.talter tk < 10 && any getTo (TK.tfeature tk)

-- | Whether a tile kind (specified by its id) has an OpenTo feature.
isOpenable :: ContentData TileKind -> ContentId TileKind -> Bool
isOpenable cotile t = TK.isOpenableKind $ okind cotile t

-- | Whether a tile kind (specified by its id) has a CloseTo feature.
isClosable :: ContentData TileKind -> ContentId TileKind -> Bool
isClosable cotile t = TK.isClosableKind $ okind cotile t
