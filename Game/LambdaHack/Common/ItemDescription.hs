-- | Descripitons of items.
module Game.LambdaHack.Common.ItemDescription
  ( partItemN, partItem, partItemWs, partItemAW, partItemMediumAW, partItemWownW
  , viewItem, show64With2
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Data.Int (Int64)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Common.Actor
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Dice as Dice
import Game.LambdaHack.Common.EffectDescription
import Game.LambdaHack.Common.Flavour
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Time
import qualified Game.LambdaHack.Content.ItemKind as IK

show64With2 :: Int64 -> Text
show64With2 n =
  let k = 100 * n `div` oneM
      l = k `div` 100
      x = k - l * 100
  in tshow l
     <> if | x == 0 -> ""
           | x < 10 -> ".0" <> tshow x
           | otherwise -> "." <> tshow x

-- | The part of speech describing the item parameterized by the number
-- of effects/aspects to show..
partItemN :: Int -> Int -> CStore -> Time -> ItemFull
          -> (Bool, MU.Part, MU.Part)
partItemN fullInfo n cstore localTime itemFull =
  let genericName = jname $ itemBase itemFull
  in case itemDisco itemFull of
    Nothing ->
      let flav = flavourToName $ jflavour $ itemBase itemFull
      in (False, MU.Text $ flav <+> genericName, "")
    Just iDisco ->
      let timeout = aTimeout $ aspectRecordFull itemFull
          timeoutTurns = timeDeltaScale (Delta timeTurn) timeout
          charging startT = timeShift startT timeoutTurns > localTime
          it1 = filter charging (itemTimer itemFull)
          len = length it1
          chargingAdj | timeout == 0 = "temporary"
                      | otherwise = "charging"
          timer | len == 0 = ""
                | itemK itemFull == 1 && len == 1 = "(" <> chargingAdj <> ")"
                | otherwise = "(" <> tshow len <+> chargingAdj <> ")"
          skipRecharging = fullInfo <= 4 && len >= itemK itemFull
          effTs = filter (not . T.null)
                  $ textAllAE fullInfo skipRecharging cstore itemFull
          ts = take n effTs
               ++ ["(...)" | length effTs > n]
               ++ [timer]
          unique = IK.Unique `elem` IK.ieffects (itemKind iDisco)
          capName = if unique
                    then MU.Capitalize $ MU.Text genericName
                    else MU.Text genericName
      in (unique, capName, MU.Phrase $ map MU.Text ts)

-- | The part of speech describing the item.
partItem :: CStore -> Time -> ItemFull -> (Bool, MU.Part, MU.Part)
partItem = partItemN 5 4

textAllAE :: Int -> Bool -> CStore -> ItemFull -> [Text]
textAllAE fullInfo skipRecharging cstore ItemFull{itemBase, itemDisco} =
  let features | fullInfo >= 9 = map featureToSuff $ sort $ jfeature itemBase
               | otherwise = []
  in case itemDisco of
    Nothing -> features
    Just ItemDisco{itemKind, itemAspect} ->
      let timeoutAspect :: IK.Aspect -> Bool
          timeoutAspect IK.Timeout{} = True
          timeoutAspect _ = False
          hurtMeleeAspect :: IK.Aspect -> Bool
          hurtMeleeAspect IK.AddHurtMelee{} = True
          hurtMeleeAspect _ = False
          noEffect :: IK.Effect -> Bool
          noEffect IK.ELabel{} = True
          noEffect _ = False
          rawDmgEffect :: IK.Effect -> Bool
          rawDmgEffect (IK.Burn _) = True
          rawDmgEffect _ = False
          notDetail :: IK.Effect -> Bool
          notDetail IK.Explode{} = fullInfo >= 6
          notDetail _ = True
          active = cstore `elem` [CEqp, COrgan]
                   || cstore == CGround && IK.Equipable `elem` jfeature itemBase
          splitAE :: [IK.Aspect] -> [IK.Effect] -> [Text]
          splitAE aspects effects =
            let ppA = kindAspectToSuffix
                ppE = effectToSuffix
                reduce_a = maybe "?" tshow . Dice.reduceDice
                periodic = IK.Periodic `elem` IK.ieffects itemKind
                mtimeout = find timeoutAspect aspects
                restAs = sort aspects
                (rawDmgEs, restEs) = partition rawDmgEffect $ sort
                                   $ filter notDetail effects
                aes = if active
                      then map ppA restAs ++ map ppE restEs
                      else map ppE restEs ++ map ppA restAs
                rechargingTs = T.intercalate (T.singleton ' ')
                               $ filter (not . T.null)
                               $ map ppE $ stripRecharging restEs
                onSmashTs = T.intercalate (T.singleton ' ')
                            $ filter (not . T.null)
                            $ map ppE $ stripOnSmash restEs
                durable = IK.Durable `elem` jfeature itemBase
                periodicOrTimeout = case periodic of
                  _ | skipRecharging || T.null rechargingTs -> ""
                  True ->
                    case mtimeout of
                      Nothing | not durable ->
                        "(each turn until gone:"
                        <+> rechargingTs <> ")"
                      Just (IK.Timeout t) ->
                        "(every" <+> reduce_a t <> ":"
                        <+> rechargingTs <> ")"
                      _ -> ""
                  _ -> case mtimeout of
                    Just (IK.Timeout t) ->
                      "(timeout" <+> reduce_a t <> ":"
                      <+> rechargingTs <> ")"
                    _ -> ""
                onSmash = if T.null onSmashTs then ""
                          else "(on smash:" <+> onSmashTs <> ")"
                noEff = case find noEffect effects of
                  Just (IK.ELabel t) -> [t]
                  _ -> []
                damage = case find hurtMeleeAspect aspects of
                  Just (IK.AddHurtMelee hurtMelee) ->
                    (if jdamage itemBase <= 0
                     then "0d0"
                     else tshow (jdamage itemBase))
                    <> affixDice hurtMelee <> "%"
                  _ -> if jdamage itemBase <= 0
                       then ""
                       else tshow (jdamage itemBase)
            in noEff ++ if fullInfo >= 5 || fullInfo >= 2 && null noEff
                        then [periodicOrTimeout] ++ [damage]
                             ++ map ppE rawDmgEs ++ aes
                             ++ [onSmash | fullInfo >= 7]
                        else damage : map ppE rawDmgEs
          aets = case itemAspect of
            Just aspectRecord ->
              splitAE (aspectRecordToList aspectRecord) (IK.ieffects itemKind)
            Nothing ->
              splitAE (IK.iaspects itemKind) (IK.ieffects itemKind)
          IK.ThrowMod{IK.throwVelocity} = strengthToThrow itemBase
          speed = speedFromWeight (jweight itemBase) throwVelocity
          meanDmg = Dice.meanDice (jdamage itemBase)
          minDeltaHP = xM meanDmg `divUp` 100
          aHurtMeleeOfItem = case itemAspect of
            Just aspectRecord -> aHurtMelee aspectRecord
            Nothing -> case find hurtMeleeAspect (IK.iaspects itemKind) of
              Just (IK.AddHurtMelee d) -> Dice.meanDice d
              _ -> 0
          pmult = 100 + min 99 (max (-99) aHurtMeleeOfItem)
          prawDeltaHP = fromIntegral pmult * minDeltaHP
          pdeltaHP = modifyDamageBySpeed prawDeltaHP speed
          rangedDamage = if pdeltaHP == 0
                         then []
                         else ["{avg" <+> show64With2 pdeltaHP <+> "ranged}"]
          -- Note that avg melee damage would be too complex to display here,
          -- because in case of @MOwned@ the owner is different than leader,
          -- so the value would be different than when viewing the item.
      in aets ++ features ++ rangedDamage

-- TODO: use kit
partItemWs :: Int -> CStore -> Time -> ItemFull -> MU.Part
partItemWs count c localTime itemFull =
  let (unique, name, stats) = partItem c localTime itemFull
  in if unique && count == 1
     then MU.Phrase ["the", name, stats]
     else MU.Phrase [MU.CarWs count name, stats]

partItemAW :: CStore -> Time -> ItemFull -> MU.Part
partItemAW c localTime itemFull =
  let (unique, name, stats) = partItemN 4 4 c localTime itemFull
  in if unique
     then MU.Phrase ["the", name, stats]
     else MU.AW $ MU.Phrase [name, stats]

partItemMediumAW :: CStore -> Time -> ItemFull -> MU.Part
partItemMediumAW c localTime itemFull =
  let (unique, name, stats) = partItemN 5 100 c localTime itemFull
  in if unique
     then MU.Phrase ["the", name, stats]
     else MU.AW $ MU.Phrase [name, stats]

partItemWownW :: MU.Part -> CStore -> Time -> ItemFull -> MU.Part
partItemWownW partA c localTime itemFull =
  let (_, name, stats) = partItemN 4 4 c localTime itemFull
  in MU.WownW partA $ MU.Phrase [name, stats]

viewItem :: Item -> Color.AttrCharW32
{-# INLINE viewItem #-}
viewItem item =
  Color.attrChar2ToW32 (flavourToColor $ jflavour item) (jsymbol item)
