{-# LANGUAGE TupleSections #-}
-- | Semantics of "Game.LambdaHack.Client.UI.HumanCmd"
-- client commands that do not return server requests,,
-- but only change internal client state.
-- None of such commands takes game time.
module Game.LambdaHack.Client.UI.HandleHumanLocalM
  ( -- * Meta commands
    macroHuman, macroHumanTransition
    -- * Local commands
  , chooseItemHuman, chooseItemDialogMode
  , chooseItemProjectHuman, chooseItemApplyHuman
  , psuitReq, triggerSymbols, pickLeaderHuman, pickLeaderWithPointerHuman
  , memberCycleHuman, memberCycleLevelHuman
  , selectActorHuman, selectNoneHuman, selectWithPointerHuman
  , repeatHuman, repeatHumanTransition
  , repeatLastHuman, repeatLastHumanTransition
  , recordHuman, recordHumanTransition
  , allHistoryHuman, lastHistoryHuman
  , markVisionHuman, markSmellHuman, markSuspectHuman, markAnimHuman
  , overrideTutHuman
  , printScreenHuman
    -- * Commands specific to aiming
  , cancelHuman, acceptHuman, detailCycleHuman
  , clearTargetIfItemClearHuman, itemClearHuman
  , moveXhairHuman, aimTgtHuman, aimFloorHuman, aimEnemyHuman, aimItemHuman
  , aimAscendHuman, epsIncrHuman
  , xhairUnknownHuman, xhairItemHuman, xhairStairHuman
  , xhairPointerFloorHuman, xhairPointerEnemyHuman
  , aimPointerFloorHuman, aimPointerEnemyHuman
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , permittedProjectClient, projectCheck, xhairLegalEps, posFromXhair
  , permittedApplyClient, selectAid, eitherHistory, endAiming, endAimingMsg
  , doLook, flashAiming
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import           Data.Either (fromRight)
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import           Game.LambdaHack.Client.BfsM
import           Game.LambdaHack.Client.CommonM
import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Client.UI.ActorUI
import           Game.LambdaHack.Client.UI.Animation
import           Game.LambdaHack.Client.UI.Content.Screen
import           Game.LambdaHack.Client.UI.ContentClientUI
import           Game.LambdaHack.Client.UI.DrawM
import           Game.LambdaHack.Client.UI.EffectDescription
import           Game.LambdaHack.Client.UI.Frame
import           Game.LambdaHack.Client.UI.FrameM
import           Game.LambdaHack.Client.UI.HandleHelperM
import qualified Game.LambdaHack.Client.UI.HumanCmd as HumanCmd
import           Game.LambdaHack.Client.UI.InventoryM
import           Game.LambdaHack.Client.UI.ItemSlot
import qualified Game.LambdaHack.Client.UI.Key as K
import           Game.LambdaHack.Client.UI.MonadClientUI
import           Game.LambdaHack.Client.UI.Msg
import           Game.LambdaHack.Client.UI.MsgM
import           Game.LambdaHack.Client.UI.Overlay
import           Game.LambdaHack.Client.UI.SessionUI
import           Game.LambdaHack.Client.UI.Slideshow
import           Game.LambdaHack.Client.UI.SlideshowM
import           Game.LambdaHack.Client.UI.UIOptions
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.ClientOptions
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Types
import           Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import qualified Game.LambdaHack.Content.ModeKind as MK
import qualified Game.LambdaHack.Content.PlaceKind as PK
import           Game.LambdaHack.Content.RuleKind
import qualified Game.LambdaHack.Definition.Ability as Ability
import qualified Game.LambdaHack.Definition.Color as Color
import           Game.LambdaHack.Definition.Defs

-- * Macro

macroHuman :: (MonadClient m, MonadClientUI m) => [String] -> m ()
macroHuman ks = do
  modifySession $ \sess ->
    let kms = K.mkKM <$> ks
        (smacroFrameNew, smacroStackMew) =
           macroHumanTransition kms (smacroFrame sess) (smacroStack sess)
    in sess { smacroFrame = smacroFrameNew
            , smacroStack = smacroStackMew }
  msgAdd MsgMacroOperation $ "Macro activated:" <+> T.pack (intercalate " " ks)

-- | Push a new macro frame to the stack whenever repeating a macro.
macroHumanTransition :: [K.KM] -> KeyMacroFrame -> [KeyMacroFrame]
                     -> (KeyMacroFrame, [KeyMacroFrame])
macroHumanTransition kms macroFrame macroFrames =
  let smacroFrameNew = emptyMacroFrame {keyPending = KeyMacro kms}
  in (smacroFrameNew, macroFrame : macroFrames)

-- * ChooseItem

-- | Display items from a given container store and possibly let the user
-- chose one.
chooseItemHuman :: (MonadClient m, MonadClientUI m)
                => ItemDialogMode -> m MError
chooseItemHuman c = either Just (const Nothing) <$> chooseItemDialogMode c

chooseItemDialogMode :: (MonadClient m, MonadClientUI m)
                     => ItemDialogMode -> m (FailOrCmd ItemDialogMode)
chooseItemDialogMode c = do
  CCUI{coscreen=ScreenContent{rwidth, rheight}} <- getsSession sccui
  COps{coitem} <- getsState scops
  FontSetup{..} <- getFontSetup
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  mstash <- getsState $ \s -> gstash $ sfactionD s EM.! side
  let prompt :: Actor -> ActorUI -> Ability.Skills -> ItemDialogMode -> State
             -> Text
      prompt body bodyUI actorCurAndMaxSk c2 s =
        let (tIn, t) = ppItemDialogMode c2
            subject = partActor bodyUI
            f (k, _) acc = k + acc
            countItems store = EM.foldr' f 0 $ getBodyStoreBag body store s
        in case c2 of
        MStore CGround ->
          let n = countItems CGround
              nItems = MU.CarAWs n "item"
              verbGround = if mstash == Just (blid body, bpos body)
                           then "fondle greedily"
                           else "notice"
          in makePhrase
               [ MU.Capitalize $ MU.SubjectVerbSg subject verbGround
               , nItems, "at"
               , MU.WownW (MU.Text $ bpronoun bodyUI) $ MU.Text "feet" ]
        MStore CEqp ->
          let n = countItems CEqp
              (verbEqp, nItems) =
                if | n == 0 -> ("find nothing", "")
                   | calmEnough body actorCurAndMaxSk ->
                       ("find", MU.CarAWs n "item")
                   | otherwise -> ("paw distractedly at", MU.CarAWs n "item")
          in makePhrase
               [ MU.Capitalize $ MU.SubjectVerbSg subject verbEqp
               , nItems, MU.Text tIn
               , MU.WownW (MU.Text $ bpronoun bodyUI) $ MU.Text t ]
        MStore cstore ->
          let n = countItems cstore
              nItems = MU.CarAWs n "item"
              (verb, onLevel) = case cstore of
                COrgan -> ("feel", [])
                CStash ->
                  ( "notice"
                  , case gstash fact of
                      Just (lid, _) ->
                        map MU.Text ["on level", tshow $ abs $ fromEnum lid]
                      Nothing -> [] )
                _ -> ("see", [])
              ownObject = case cstore of
                CStash -> ["our", MU.Text t]
                _ -> [MU.WownW (MU.Text $ bpronoun bodyUI) $ MU.Text t]
          in makePhrase $
               [ MU.Capitalize $ MU.SubjectVerbSg subject verb
               , nItems, MU.Text tIn ] ++ ownObject ++ onLevel
        MOrgans ->
          makePhrase
            [ MU.Capitalize $ MU.SubjectVerbSg subject "feel"
            , MU.Text tIn
            , MU.WownW (MU.Text $ bpronoun bodyUI) $ MU.Text t ]
        MOwned ->
          -- We assume "gold grain", not "grain" with label "of gold":
          let currencyName = IK.iname $ okind coitem
                             $ ouniqGroup coitem IK.S_CURRENCY
              dungeonTotal = sgold s
              (_, total) = calculateTotal side s
              n = countItems CStash
              verbOwned = if | n == 0 -> "find nothing among"
                             | otherwise -> "review"
          in makePhrase
               [ MU.Text $ spoilsBlurb currencyName total dungeonTotal
               , MU.Capitalize $ MU.SubjectVerbSg subject verbOwned
               , MU.Text t ]
        MSkills ->
          makePhrase
            [ MU.Capitalize $ MU.SubjectVerbSg subject "estimate"
            , MU.WownW (MU.Text $ bpronoun bodyUI) $ MU.Text t ]
        MLore slore ->
          makePhrase
            [ MU.Capitalize $ MU.Text $
                if slore == SEmbed
                then "terrain (including crafting recipes)"
                else t ]
        MPlaces ->
          makePhrase
            [ MU.Capitalize $ MU.Text t ]
        MModes ->
          makePhrase
            [ MU.Capitalize $ MU.Text t ]
  ggi <- getStoreItem prompt c
  recordHistory  -- item chosen, wipe out already shown msgs
  leader <- getLeaderUI
  actorCurAndMaxSk <- leaderSkillsClientUI
  let meleeSkill = Ability.getSk Ability.SkHurtMelee actorCurAndMaxSk
  bUI <- getsSession $ getActorUI leader
  case ggi of
    Right result -> case result of
      RStore fromCStore [iid] -> do
        modifySession $ \sess ->
          sess {sitemSel = Just (iid, fromCStore, False)}
        return $ Right $ MStore fromCStore
      RStore{} -> error $ "" `showFailure` result
      ROrgans iid itemBag lSlots -> do
        let blurb itemFull =
              if IA.checkFlag Ability.Condition $ aspectRecordFull itemFull
              then "condition"
              else "organ"
            promptFun _ itemFull _ =
              makeSentence [ partActor bUI, "is aware of"
                           , MU.AW $ blurb itemFull ]
            ix0 = fromMaybe (error $ "" `showFailure` result)
                  $ findIndex (== iid) $ EM.elems lSlots
        go <- displayItemLore itemBag meleeSkill promptFun ix0 lSlots
        if go then chooseItemDialogMode MOrgans else failWith "never mind"
      ROwned iid -> do
        found <- getsState $ findIid leader side iid
        let (newAid, bestStore) = case leader `lookup` found of
              Just (_, store) -> (leader, store)
              Nothing -> case found of
                (aid, (_, store)) : _ -> (aid, store)
                [] -> error $ "" `showFailure` result
        modifySession $ \sess ->
          sess {sitemSel = Just (iid, bestStore, False)}
        arena <- getArenaUI
        b2 <- getsState $ getActorBody newAid
        let (autoDun, _) = autoDungeonLevel fact
        if | newAid == leader -> return $ Right MOwned
           | blid b2 /= arena && autoDun ->
             failSer NoChangeDunLeader
           | otherwise -> do
             -- We switch leader only here, not in lore screens, because
             -- lore is only about inspecting items, no activation submenu.
             void $ pickLeader True newAid
             return $ Right MOwned
      RSkills slotIndex0 -> do
        let slotListBound = length skillSlots - 1
            displayOneSlot slotIndex = do
              b <- getsState $ getActorBody leader
              let skill = skillSlots !! slotIndex
                  valueText = skillToDecorator skill b
                              $ Ability.getSk skill actorCurAndMaxSk
                  prompt2 = makeSentence
                    [ MU.WownW (partActor bUI) (MU.Text $ skillName skill)
                    , "is", MU.Text valueText ]
                  ov0 = EM.singleton propFont
                        $ offsetOverlay
                        $ indentSplitAttrString rwidth
                        $ textToAS $ skillDesc skill
                  keys = [K.spaceKM, K.escKM]
                         ++ [K.upKM | slotIndex /= 0]
                         ++ [K.downKM | slotIndex /= slotListBound]
              msgAdd MsgPromptGeneric prompt2
              slides <- overlayToSlideshow (rheight - 2) keys (ov0, [])
              km <- getConfirms ColorFull keys slides
              case K.key km of
                K.Space -> chooseItemDialogMode MSkills
                K.Up -> displayOneSlot $ slotIndex - 1
                K.Down -> displayOneSlot $ slotIndex + 1
                K.Esc -> failWith "never mind"
                _ -> error $ "" `showFailure` km
        displayOneSlot slotIndex0
      RLore slore iid itemBag lSlots -> do
        let ix0 = fromMaybe (error $ "" `showFailure` result)
                  $ findIndex (== iid) $ EM.elems lSlots
            promptFun _ _ _ =
              makeSentence [ MU.SubjectVerbSg (partActor bUI) "remember"
                           , MU.AW $ MU.Text (headingSLore slore) ]
        go <- displayItemLore itemBag meleeSkill promptFun ix0 lSlots
        if go then chooseItemDialogMode (MLore slore) else failWith "never mind"
      RPlaces slotIndex0 -> do
        COps{coplace} <- getsState scops
        soptions <- getsClient soptions
        places <- getsState $ EM.assocs . placesFromState coplace soptions
        let slotListBound = length places - 1
            displayOneSlot slotIndex = do
              let (pk, (es, ne, na, _)) = places !! slotIndex
                  pkind = okind coplace pk
                  prompt2 = makeSentence
                    [ MU.SubjectVerbSg (partActor bUI) "remember"
                    , MU.Text $ PK.pname pkind ]
                  freqsText = "Frequencies:" <+> T.intercalate " "
                    (map (\(grp, n) -> "(" <> fromGroupName grp
                                       <> ", " <> tshow n <> ")")
                     $ PK.pfreq pkind)
                  onLevels | ES.null es = []
                           | otherwise =
                    [makeSentence
                       [ "Appears on"
                       , MU.CarWs (ES.size es) "level" <> ":"
                       , MU.WWandW $ map MU.Car $ sort
                                   $ map (abs . fromEnum) $ ES.elems es ]]
                  placeParts = ["it has" | ne > 0 || na > 0]
                               ++ [MU.CarWs ne "entrance" | ne > 0]
                               ++ ["and" | ne > 0 && na > 0]
                               ++ [MU.CarWs na "surrounding" | na > 0]
                  partsSentence | null placeParts = ""
                                | otherwise = makeSentence placeParts
                  -- Ideally, place layout would be in SquareFont and the rest
                  -- in PropFont, but this is mostly a debug screen, so KISS.
                  ov0 = EM.singleton monoFont
                        $ offsetOverlay
                        $ concatMap (indentSplitAttrString rwidth . textToAS)
                        $ ["", partsSentence]
                          ++ (if sexposePlaces soptions
                              then [ "", freqsText
                                   , "" ] ++ PK.ptopLeft pkind
                              else [])
                          ++ [""] ++ onLevels
                  keys = [K.spaceKM, K.escKM]
                         ++ [K.upKM | slotIndex /= 0]
                         ++ [K.downKM | slotIndex /= slotListBound]
              msgAdd MsgPromptGeneric prompt2
              slides <- overlayToSlideshow (rheight - 2) keys (ov0, [])
              km <- getConfirms ColorFull keys slides
              case K.key km of
                K.Space -> chooseItemDialogMode MPlaces
                K.Up -> displayOneSlot $ slotIndex - 1
                K.Down -> displayOneSlot $ slotIndex + 1
                K.Esc -> failWith "never mind"
                _ -> error $ "" `showFailure` km
        displayOneSlot slotIndex0
      RModes slotIndex0 -> do
        COps{comode} <- getsState scops
        svictories <- getsClient svictories
        nxtChal <- getsClient snxtChal
          -- mark victories only for current difficulty
        let f !acc _p !i !a = (i, a) : acc
            campaignModes = ofoldlGroup' comode MK.CAMPAIGN_SCENARIO f []
            slotListBound = length campaignModes - 1
            displayOneSlot slotIndex = do
              let (gameModeId, gameMode) = campaignModes !! slotIndex
              modeOKX <- describeMode False gameModeId
              let victories = case EM.lookup gameModeId svictories of
                    Nothing -> 0
                    Just cm -> fromMaybe 0 (M.lookup nxtChal cm)
                  verb = if victories > 0 then "remember" else "forsee"
                  prompt2 = makeSentence
                    [ MU.SubjectVerbSg (partActor bUI) verb
                    , MU.Text $ "the '" <> MK.mname gameMode <> "' adventure" ]
                  keys = [K.spaceKM, K.escKM]
                         ++ [K.upKM | slotIndex /= 0]
                         ++ [K.downKM | slotIndex /= slotListBound]
              msgAdd MsgPromptGeneric prompt2
              slides <- overlayToSlideshow rheight keys (modeOKX, [])
              ekm2 <- displayChoiceScreen "" ColorFull True slides keys
              let km = either id (error $ "" `showFailure` ekm2) ekm2
              case K.key km of
                K.Space -> chooseItemDialogMode MModes
                K.Up -> displayOneSlot $ slotIndex - 1
                K.Down -> displayOneSlot $ slotIndex + 1
                K.Esc -> failWith "never mind"
                _ -> error $ "" `showFailure` km
        displayOneSlot slotIndex0
    Left err -> failWith err

-- * ChooseItemProject

chooseItemProjectHuman :: forall m. (MonadClient m, MonadClientUI m)
                       => [HumanCmd.TriggerItem] -> m MError
chooseItemProjectHuman ts = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  mstash <- getsState $ \s -> gstash $ sfactionD s EM.! bfid b
  let overStash = mstash == Just (blid b, bpos b)
      storesBase = [CStash, CEqp]
      stores | overStash = storesBase ++ [CGround]
             | otherwise = CGround : storesBase
      (verb1, object1) = case ts of
        [] -> ("aim", "item")
        tr : _ -> (HumanCmd.tiverb tr, HumanCmd.tiobject tr)
      verb = makePhrase [verb1]
      triggerSyms = triggerSymbols ts
  mpsuitReq <- psuitReq
  case mpsuitReq of
    -- If xhair aim invalid, no item is considered a (suitable) missile.
    Left err -> failMsg err
    Right psuitReqFun -> do
      itemSel <- getsSession sitemSel
      case itemSel of
        Just (_, _, True) -> return Nothing
        Just (iid, fromCStore, False) -> do
          -- We don't validate vs @ts@ here, because player has selected
          -- this item, so he knows what he's doing (unless really absurd).
          itemFull <- getsState $ itemToFull iid
          bag <- getsState $ getBodyStoreBag b fromCStore
          case iid `EM.lookup` bag of
            Just _ | either (const False) snd (psuitReqFun itemFull) ->
              return Nothing
            _ -> do
              modifySession $ \sess -> sess {sitemSel = Nothing}
              chooseItemProjectHuman ts
        Nothing -> do
          let psuit =
                return $ SuitsSomething $ \_ itemFull _kit ->
                  either (const False) snd (psuitReqFun itemFull)
                  && (null triggerSyms
                      || IK.isymbol (itemKind itemFull) `elem` triggerSyms)
              prompt = makePhrase ["What", object1, "to"]
              promptGeneric = "What to"
          ggi <- getGroupItem psuit prompt promptGeneric verb "fling" stores
          case ggi of
            Right (fromCStore, iid) -> do
              modifySession $ \sess ->
                sess {sitemSel = Just (iid, fromCStore, False)}
              return Nothing
            Left err -> failMsg err

permittedProjectClient :: MonadClientUI m
                       => m (ItemFull -> Either ReqFailure Bool)
permittedProjectClient = do
  leader <- getLeaderUI
  actorCurAndMaxSk <- leaderSkillsClientUI
  b <- getsState $ getActorBody leader
  let skill = Ability.getSk Ability.SkProject actorCurAndMaxSk
      calmE = calmEnough b actorCurAndMaxSk
  return $ permittedProject False skill calmE

projectCheck :: MonadClientUI m => Point -> m (Maybe ReqFailure)
projectCheck tpos = do
  COps{corule=RuleContent{rXmax, rYmax}, coTileSpeedup} <- getsState scops
  leader <- getLeaderUI
  eps <- getsClient seps
  sb <- getsState $ getActorBody leader
  let lid = blid sb
      spos = bpos sb
  -- Not @ScreenContent@, because not drawing here.
  case bla rXmax rYmax eps spos tpos of
    Nothing -> return $ Just ProjectAimOnself
    Just [] -> error $ "project from the edge of level"
                       `showFailure` (spos, tpos, sb)
    Just (pos : _) -> do
      lvl <- getLevel lid
      let t = lvl `at` pos
      if not $ Tile.isWalkable coTileSpeedup t
        then return $ Just ProjectBlockTerrain
        else if occupiedBigLvl pos lvl
             then return $ Just ProjectBlockActor
             else return Nothing

-- | Check whether one is permitted to aim (for projecting) at a target.
-- The check is stricter for actor targets, assuming the player simply wants
-- to hit a single actor. In order to fine tune trick-shots, e.g., piercing
-- many actors, other aiming modes should be used.
-- Returns a different @seps@ if needed to reach the target.
--
-- Note: Simple Perception check is not enough for the check,
-- e.g., because the target actor can be obscured by a glass wall.
xhairLegalEps :: MonadClientUI m => m (Either Text Int)
xhairLegalEps = do
  cops@COps{corule=RuleContent{rXmax, rYmax}} <- getsState scops
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  lidV <- viewedLevelUI
  let !_A = assert (lidV == blid b) ()
      findNewEps onlyFirst pos = do
        lvl <- getLevel (blid b)
        oldEps <- getsClient seps
        return $! case makeLine onlyFirst b pos oldEps cops lvl of
          Just newEps -> Right newEps
          Nothing -> Left $ if onlyFirst
                            then "aiming blocked at the first step"
                            else "aiming line blocked somewhere"
  xhair <- getsSession sxhair
  case xhair of
    Nothing -> return $ Left "no aim designated"
    Just (TEnemy a) -> do
      body <- getsState $ getActorBody a
      let pos = bpos body
      if blid body == lidV
      then findNewEps False pos
      else return $ Left "can't fling at an enemy on remote level"
    Just (TNonEnemy a) -> do
      body <- getsState $ getActorBody a
      let pos = bpos body
      if blid body == lidV
      then findNewEps False pos
      else return $ Left "can't fling at a non-enemy on remote level"
    Just (TPoint TEnemyPos{} _ _) ->
      return $ Left "selected opponent not visible"
    Just (TPoint _ lid pos) ->
      if lid == lidV
      then findNewEps True pos  -- @True@ to help pierce many foes, etc.
      else return $ Left "can't fling at a target on remote level"
    Just (TVector v) -> do
      -- Not @ScreenContent@, because not drawing here.
      let shifted = shiftBounded rXmax rYmax (bpos b) v
      if shifted == bpos b && v /= Vector 0 0
      then return $ Left "selected translation is void"
      else findNewEps True shifted  -- @True@, because the goal is vague anyway

posFromXhair :: (MonadClient m, MonadClientUI m) => m (Either Text Point)
posFromXhair = do
  canAim <- xhairLegalEps
  case canAim of
    Right newEps -> do
      -- Modify @seps@, permanently.
      modifyClient $ \cli -> cli {seps = newEps}
      mpos <- xhairToPos
      case mpos of
        Nothing -> error $ "" `showFailure` mpos
        Just pos -> do
          munit <- projectCheck pos
          case munit of
            Nothing -> return $ Right pos
            Just reqFail -> return $ Left $ showReqFailure reqFail
    Left cause -> return $ Left cause

-- | On top of @permittedProjectClient@, it also checks legality
-- of aiming at the target and projection range. It also modifies @eps@.
psuitReq :: (MonadClient m, MonadClientUI m)
         => m (Either Text (ItemFull -> Either ReqFailure (Point, Bool)))
psuitReq = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  lidV <- viewedLevelUI
  if lidV /= blid b
  then return $ Left "can't fling on remote level"
  else do
    mpos <- posFromXhair
    p <- permittedProjectClient
    case mpos of
      Left err -> return $ Left err
      Right pos -> return $ Right $ \itemFull ->
        case p itemFull of
          Left err -> Left err
          Right False -> Right (pos, False)
          Right True ->
            let arItem = aspectRecordFull itemFull
            in Right (pos, 1 + IA.totalRange arItem (itemKind itemFull)
                           >= chessDist (bpos b) pos)

triggerSymbols :: [HumanCmd.TriggerItem] -> [Char]
triggerSymbols [] = []
triggerSymbols (HumanCmd.TriggerItem{tisymbols} : ts) =
  tisymbols ++ triggerSymbols ts

-- * ChooseItemApply

chooseItemApplyHuman :: forall m. (MonadClient m, MonadClientUI m)
                     => [HumanCmd.TriggerItem] -> m MError
chooseItemApplyHuman ts = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  mstash <- getsState $ \s -> gstash $ sfactionD s EM.! bfid b
  let overStash = mstash == Just (blid b, bpos b)
      storesBase = [CStash, CEqp, COrgan]
      stores | overStash = storesBase ++ [CGround]
             | otherwise = CGround : storesBase
      (verb1, object1) = case ts of
        [] -> ("trigger", "item")
        tr : _ -> (HumanCmd.tiverb tr, HumanCmd.tiobject tr)
      verb = makePhrase [verb1]
      triggerSyms = triggerSymbols ts
      prompt = makePhrase ["What", object1, "to"]
      promptGeneric = "What to"
  itemSel <- getsSession sitemSel
  case itemSel of
    Just (_, _, True) -> return Nothing
    Just (iid, fromCStore, False) -> do
      -- We don't validate vs @ts@ here, because player has selected
      -- this item, so he knows what he's doing (unless really absurd).
      itemFull <- getsState $ itemToFull iid
      bag <- getsState $ getBodyStoreBag b fromCStore
      mp <- permittedApplyClient
      case iid `EM.lookup` bag of
        Just kit | either (const False) id
                          (mp (Just fromCStore) itemFull kit) ->
          return Nothing
        _ -> do
          modifySession $ \sess -> sess {sitemSel = Nothing}
          chooseItemApplyHuman ts
    Nothing -> do
      let psuit :: m Suitability
          psuit = do
            mp <- permittedApplyClient
            return $ SuitsSomething $ \cstore itemFull kit ->
              either (const False) id (mp cstore itemFull kit)
              && (null triggerSyms
                  || IK.isymbol (itemKind itemFull) `elem` triggerSyms)
      ggi <- getGroupItem psuit prompt promptGeneric verb "trigger" stores
      case ggi of
        Right (fromCStore, iid) -> do
          modifySession $ \sess ->
            sess {sitemSel = Just (iid, fromCStore, False)}
          return Nothing
        Left err -> failMsg err

permittedApplyClient :: MonadClientUI m
                     => m (Maybe CStore -> ItemFull -> ItemQuant
                           -> Either ReqFailure Bool)
permittedApplyClient = do
  leader <- getLeaderUI
  actorCurAndMaxSk <- leaderSkillsClientUI
  b <- getsState $ getActorBody leader
  let skill = Ability.getSk Ability.SkApply actorCurAndMaxSk
      calmE = calmEnough b actorCurAndMaxSk
  localTime <- getsState $ getLocalTime (blid b)
  return $ permittedApply localTime skill calmE

-- * PickLeader

pickLeaderHuman :: (MonadClient m, MonadClientUI m) => Int -> m MError
pickLeaderHuman k = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  arena <- getArenaUI
  sactorUI <- getsSession sactorUI
  mhero <- getsState $ tryFindHeroK sactorUI side k
  allOurs <- getsState $ fidActorNotProjGlobalAssocs side -- not only on level
  let allOursUI = map (\(aid, b) -> (aid, b, sactorUI EM.! aid)) allOurs
      hs = sortOn keySelected allOursUI
      mactor = case drop k hs of
                 [] -> Nothing
                 (aid, b, _) : _ -> Just (aid, b)
      mchoice = if MK.fhasGender (gplayer fact) then mhero else mactor
      (autoDun, _) = autoDungeonLevel fact
  case mchoice of
    Nothing -> failMsg "no such member of the party"
    Just (aid, b)
      | blid b /= arena && autoDun ->
          failMsg $ showReqFailure NoChangeDunLeader
      | otherwise -> do
          void $ pickLeader True aid
          return Nothing

-- * PickLeaderWithPointer

pickLeaderWithPointerHuman :: (MonadClient m, MonadClientUI m) => m MError
pickLeaderWithPointerHuman = pickLeaderWithPointer

-- * MemberCycle

-- | Switch current member to the next on the viewed level, if any, wrapping.
memberCycleLevelHuman :: (MonadClient m, MonadClientUI m)
                      => Direction -> m MError
memberCycleLevelHuman = memberCycleLevel True

-- * MemberBack

-- | Switch current member to the previous in the whole dungeon, wrapping.
memberCycleHuman :: (MonadClient m, MonadClientUI m) => Direction -> m MError
memberCycleHuman = memberCycle True

-- * SelectActor

selectActorHuman :: (MonadClient m, MonadClientUI m) => m ()
selectActorHuman = do
  leader <- getLeaderUI
  selectAid leader

selectAid :: (MonadClient m, MonadClientUI m) => ActorId -> m ()
selectAid leader = do
  bodyUI <- getsSession $ getActorUI leader
  wasMemeber <- getsSession $ ES.member leader . sselected
  let upd = if wasMemeber
            then ES.delete leader  -- already selected, deselect instead
            else ES.insert leader
  modifySession $ \sess -> sess {sselected = upd $ sselected sess}
  let subject = partActor bodyUI
  msgAdd MsgActionAlert $ makeSentence [subject, if wasMemeber
                                                 then "deselected"
                                                 else "selected"]

-- * SelectNone

selectNoneHuman :: (MonadClient m, MonadClientUI m) => m ()
selectNoneHuman = do
  side <- getsClient sside
  lidV <- viewedLevelUI
  oursIds <- getsState $ fidActorRegularIds side lidV
  let ours = ES.fromDistinctAscList oursIds
  oldSel <- getsSession sselected
  let wasNone = ES.null $ ES.intersection ours oldSel
      upd = if wasNone
            then ES.union  -- already all deselected; select all instead
            else ES.difference
  modifySession $ \sess -> sess {sselected = upd (sselected sess) ours}
  let subject = "all party members on the level"
  msgAdd MsgActionAlert $ makeSentence [subject, if wasNone
                                                 then "selected"
                                                 else "deselected"]

-- * SelectWithPointer

selectWithPointerHuman :: (MonadClient m, MonadClientUI m) => m MError
selectWithPointerHuman = do
  COps{corule=RuleContent{rYmax}} <- getsState scops
  lidV <- viewedLevelUI
  -- Not @ScreenContent@, because not drawing here.
  side <- getsClient sside
  ours <- getsState $ filter (not . bproj . snd)
                      . actorAssocs (== side) lidV
  sactorUI <- getsSession sactorUI
  let oursUI = map (\(aid, b) -> (aid, b, sactorUI EM.! aid)) ours
      viewed = sortOn keySelected oursUI
  K.PointUI x y <- getsSession spointer
  let (px, py) = (x `div` 2, y - K.mapStartY)
  -- Select even if no space in status line for the actor's symbol.
  if | py == rYmax + 1 && px == 0 -> selectNoneHuman >> return Nothing
     | py == rYmax + 1 ->
         case drop (px - 1) viewed of
           [] -> failMsg "not pointing at an actor"
           (aid, _, _) : _ -> selectAid aid >> return Nothing
     | otherwise ->
         case find (\(_, b) -> bpos b == Point px py) ours of
           Nothing -> failMsg "not pointing at an actor"
           Just (aid, _) -> selectAid aid >> return Nothing

-- * Repeat

-- Note that walk followed by repeat should not be equivalent to run,
-- because the player can really use a command that does not stop
-- at terrain change or when walking over items.
repeatHuman :: MonadClientUI m => Int -> m ()
repeatHuman n =
  modifySession $ \sess ->
    let (smacroFrameNew, smacroStackMew) =
           repeatHumanTransition n (smacroFrame sess) (smacroStack sess)
    in sess { smacroFrame = smacroFrameNew
            , smacroStack = smacroStackMew }

repeatHumanTransition :: Int -> KeyMacroFrame -> [KeyMacroFrame]
                      -> (KeyMacroFrame, [KeyMacroFrame])
repeatHumanTransition n macroFrame macroFrames =
  let kms = concat . replicate n . unKeyMacro . fromRight mempty
            $ keyMacroBuffer macroFrame
  in macroHumanTransition kms macroFrame macroFrames

-- * RepeatLast

-- Note that walk followed by repeat should not be equivalent to run,
-- because the player can really use a command that does not stop
-- at terrain change or when walking over items.
repeatLastHuman :: MonadClientUI m => Int -> m ()
repeatLastHuman n = modifySession $ \sess ->
  sess {smacroFrame = repeatLastHumanTransition n (smacroFrame sess) }

repeatLastHumanTransition :: Int -> KeyMacroFrame -> KeyMacroFrame
repeatLastHumanTransition n macroFrame =
  let macro = KeyMacro . concat . replicate n . maybeToList $ keyLast macroFrame
  in macroFrame { keyPending = macro <> keyPending macroFrame }

-- * Record

-- | Starts and stops recording of macros.
recordHuman :: (MonadClient m, MonadClientUI m) => m ()
recordHuman = do
  smacroFrameOld <- getsSession smacroFrame
  let (smacroFrameNew, msg) = recordHumanTransition smacroFrameOld
  modifySession $ \sess -> sess {smacroFrame = smacroFrameNew}
  macroStack <- getsSession smacroStack
  unless (T.null msg || not (null macroStack)) $ msgAdd MsgPromptGeneric msg

recordHumanTransition :: KeyMacroFrame -> (KeyMacroFrame, Text)
recordHumanTransition macroFrame =
  let (buffer, msg) = case keyMacroBuffer macroFrame of
        Right _ ->
          -- Start recording in-game macro.
          (Left [], "Recording a macro. Stop recording with the same key.")
        Left xs ->
          -- Stop recording in-game macro.
          (Right . KeyMacro . reverse $ xs, "Macro recording stopped.")
      smacroFrameNew = macroFrame {keyMacroBuffer = buffer}
  in (smacroFrameNew, msg)

-- * AllHistory

allHistoryHuman :: (MonadClient m, MonadClientUI m) => m ()
allHistoryHuman = eitherHistory True

eitherHistory :: forall m. (MonadClient m, MonadClientUI m) => Bool -> m ()
eitherHistory showAll = do
  CCUI{coscreen=ScreenContent{rwidth, rheight}} <- getsSession sccui
  UIOptions{uHistory1PerLine} <- getsSession sUIOptions
  history <- getsSession shistory
  arena <- getArenaUI
  localTime <- getsState $ getLocalTime arena
  global <- getsState stime
  FontSetup{..} <- getFontSetup
  let renderedHistoryRaw = renderHistory uHistory1PerLine history
      histBoundRaw = length renderedHistoryRaw
      placeholderLine = textFgToAS Color.BrBlack
        "Newest_messages_are_at_the_bottom._Press_END_to_get_there."
      placeholderCount =
        (- histBoundRaw `mod` (rheight - 4)) `mod` (rheight - 4)
      renderedHistory = replicate placeholderCount placeholderLine
                        ++ renderedHistoryRaw
      histBound = placeholderCount + histBoundRaw
      splitRow al =
        let (spNo, spYes) = span (/= Color.spaceAttrW32) al
            par1 = case linesAttr spYes of
              [] -> emptyAttrLine
              [l] -> l
              ls -> attrStringToAL $ intercalate [Color.spaceAttrW32]
                                   $ map attrLine ls
        in (attrStringToAL spNo, (textSize monoFont spNo, par1))
      (histLab, histDesc) = unzip $ map splitRow renderedHistory
      rhLab = EM.singleton monoFont $ offsetOverlay histLab
      rhDesc = EM.singleton propFont $ offsetOverlayX histDesc
      turnsGlobal = global `timeFitUp` timeTurn
      turnsLocal = localTime `timeFitUp` timeTurn
      msg = makeSentence
        [ "You survived for"
        , MU.CarWs turnsGlobal "half-second turn"
        , "(this level:"
        , MU.Car turnsLocal <> ")" ]
      kxs = [ (Right sn, ( K.PointUI 0 (slotPrefix sn)
                         , ButtonWidth propFont 1000 ))
            | sn <- take histBound intSlots ]
  msgAdd MsgPromptGeneric msg
  let keysAllHistory =
        K.returnKM
#ifndef USE_JSFILE
        : K.mkChar '.'
#endif
        : [K.escKM]
  okxs <- overlayToSlideshow (rheight - 2) keysAllHistory
                             (EM.unionWith (++) rhLab rhDesc, kxs)
  let maxIx = length (concatMap snd $ slideshow okxs) - 1
      menuName = "history"
  modifySession $ \sess ->
    sess {smenuIxMap = M.insert menuName maxIx $ smenuIxMap sess}
  let displayAllHistory = do
        ekm <- displayChoiceScreen menuName ColorFull False okxs keysAllHistory
        case ekm of
          Left km | km == K.mkChar '.' -> do
            let t = T.unlines $ map (T.pack . map Color.charFromW32)
                                    renderedHistory
            path <- dumpTextFile t "history.txt"
            msgAdd MsgPromptGeneric $ "All of history dumped to file" <+> T.pack path <> "."
          Left km | km == K.escKM ->
            msgAdd MsgPromptGeneric "Try to survive a few seconds more, if you can."
          Left km | km == K.spaceKM ->  -- click in any unused space
            msgAdd MsgPromptGeneric "Steady on."
          Right SlotChar{..} | slotChar == 'a' ->
            displayOneReport $ max 0 $ slotPrefix - placeholderCount
          _ -> error $ "" `showFailure` ekm
      displayOneReport :: Int -> m ()
      displayOneReport histSlot = do
        let timeReport = case drop histSlot renderedHistoryRaw of
              [] -> error $ "" `showFailure` histSlot
              tR : _ -> tR
            ov0 =
              let (spNo, spYes) = span (/= Color.spaceAttrW32) timeReport
                  lenNo = textSize monoFont spNo
                  spYesX = case splitAttrString (rwidth - lenNo - 1) rwidth
                                                spYes of
                    [] -> []
                    l : ls ->
                      ( lenNo
                      , firstParagraph $ Color.spaceAttrW32 : attrLine l )
                      : map (0,) ls
              in EM.insertWith (++) monoFont
                               (offsetOverlay [attrStringToAL spNo])
                 $ EM.singleton propFont $ offsetOverlayX spYesX
            prompt = makeSentence
              [ "the", MU.Ordinal $ histSlot + 1
              , "most recent record follows" ]
            keys = [K.spaceKM, K.escKM]
                   ++ [K.upKM | histSlot /= 0]
                   ++ [K.downKM | histSlot /= histBoundRaw - 1]
        msgAdd MsgPromptGeneric prompt
        slides <- overlayToSlideshow (rheight - 2) keys (ov0, [])
        km <- getConfirms ColorFull keys slides
        case K.key km of
          K.Space -> displayAllHistory
          K.Up -> displayOneReport $ histSlot - 1
          K.Down -> displayOneReport $ histSlot + 1
          K.Esc -> msgAdd MsgPromptGeneric "Try to learn from your previous mistakes."
          _ -> error $ "" `showFailure` km
  if showAll
  then displayAllHistory
  else displayOneReport (histBoundRaw - 1)

-- * LastHistory

lastHistoryHuman :: (MonadClient m, MonadClientUI m) => m ()
lastHistoryHuman = eitherHistory False

-- * MarkVision

markVisionHuman :: MonadClientUI m => m ()
markVisionHuman = modifySession toggleMarkVision

-- * MarkSmell

markSmellHuman :: MonadClientUI m => m ()
markSmellHuman = modifySession toggleMarkSmell

-- * MarkSuspect

markSuspectHuman :: MonadClient m => m ()
markSuspectHuman = do
  -- @condBFS@ depends on the setting we change here.
  invalidateBfsAll
  modifyClient cycleMarkSuspect

-- * MarkAnim

markAnimHuman :: MonadClient m => m ()
markAnimHuman = do
  noAnim <- getsClient $ fromMaybe False . snoAnim . soptions
  modifyClient $ \cli ->
    cli {soptions = (soptions cli) {snoAnim = Just $ not noAnim}}

-- * OverrideTut

overrideTutHuman :: MonadClientUI m => m ()
overrideTutHuman = modifySession cycleOverrideTut

-- * PrintScreen

printScreenHuman :: (MonadClient m, MonadClientUI m) => m ()
printScreenHuman = do
  msgAdd MsgActionAlert "Screenshot printed."
  printScreen

-- * Cancel

-- | End aiming mode, rejecting the current position.
cancelHuman :: MonadClientUI m => m ()
cancelHuman = do
  saimMode <- getsSession saimMode
  when (isJust saimMode) clearAimMode

-- * Accept

-- | Accept the current crosshair position as target, ending
-- aiming mode, if active.
acceptHuman :: (MonadClient m, MonadClientUI m) => m ()
acceptHuman = do
  endAiming
  endAimingMsg
  clearAimMode

-- | End aiming mode, accepting the current position.
endAiming :: (MonadClient m, MonadClientUI m) => m ()
endAiming = do
  leader <- getLeaderUI
  sxhair <- getsSession sxhair
  modifyClient $ updateTarget leader $ const sxhair

endAimingMsg :: (MonadClient m, MonadClientUI m) => m ()
endAimingMsg = do
  leader <- getLeaderUI
  subject <- partActorLeader leader
  tgt <- getsClient $ getTarget leader
  (mtargetMsg, _) <- targetDesc tgt
  msgAdd MsgActionAlert $ case mtargetMsg of
    Nothing ->
      makeSentence [MU.SubjectVerbSg subject "clear target"]
    Just targetMsg ->
      makeSentence [MU.SubjectVerbSg subject "target", MU.Text targetMsg]

-- * DetailCycle

-- | Cycle detail level of aiming mode descriptions, starting up.
detailCycleHuman :: (MonadClient m, MonadClientUI m) => m ()
detailCycleHuman = do
  modifySession $ \sess -> sess {saimMode =
    (\aimMode -> aimMode {detailLevel = detailCycle $ detailLevel aimMode})
                 <$> saimMode sess}
  doLook

detailCycle :: DetailLevel -> DetailLevel
detailCycle detail = if detail == minBound then maxBound else pred detail

-- * ClearTargetIfItemClear

clearTargetIfItemClearHuman :: (MonadClient m, MonadClientUI m) => m ()
clearTargetIfItemClearHuman = do
  itemSel <- getsSession sitemSel
  when (isNothing itemSel) $ do
    setXHairFromGUI Nothing
    leader <- getLeaderUI
    modifyClient $ updateTarget leader (const Nothing)
    doLook

-- | Perform look around in the current position of the xhair.
-- Does nothing outside aiming mode.
doLook :: (MonadClient m, MonadClientUI m) => m ()
doLook = do
  saimMode <- getsSession saimMode
  case saimMode of
    Nothing -> return ()
    Just aimMode -> do
      leader <- getLeaderUI
      let lidV = aimLevelId aimMode
      mxhairPos <- xhairToPos
      b <- getsState $ getActorBody leader
      let xhairPos = fromMaybe (bpos b) mxhairPos
      blurb <- lookAtPosition lidV xhairPos
      mapM_ (uncurry msgAdd) blurb

-- * ItemClear

itemClearHuman :: MonadClientUI m => m ()
itemClearHuman = modifySession $ \sess -> sess {sitemSel = Nothing}

-- * MoveXhair

-- | Move the xhair. Assumes aiming mode.
moveXhairHuman :: (MonadClient m, MonadClientUI m) => Vector -> Int -> m MError
moveXhairHuman dir n = do
  COps{corule=RuleContent{rXmax, rYmax}} <- getsState scops
  leader <- getLeaderUI
  saimMode <- getsSession saimMode
  let lidV = maybe (error $ "" `showFailure` leader) aimLevelId saimMode
  -- Not @ScreenContent@, because not drawing here.
  lpos <- getsState $ bpos . getActorBody leader
  xhair <- getsSession sxhair
  mxhairPos <- xhairToPos
  let xhairPos = fromMaybe lpos mxhairPos
      shiftB pos = shiftBounded rXmax rYmax pos dir
      newPos = iterate shiftB xhairPos !! n
  if newPos == xhairPos then failMsg "never mind"
  else do
    let sxhair = case xhair of
          Just TVector{} -> Just $ TVector $ newPos `vectorToFrom` lpos
          _ -> Just $ TPoint TKnown lidV newPos
    setXHairFromGUI sxhair
    doLook
    return Nothing

-- * AimTgt

-- | Start aiming.
aimTgtHuman :: (MonadClient m, MonadClientUI m) => m ()
aimTgtHuman = do
  -- (Re)start aiming at the current level.
  lidV <- viewedLevelUI
  modifySession $ \sess -> sess {saimMode =
    let newDetail = maybe defaultDetailLevel detailLevel (saimMode sess)
    in Just $ AimMode lidV newDetail}
  doLook
  msgAdd MsgPromptAction "*flinging started; press again to project*"

-- * AimFloor

-- | Cycle aiming mode. Do not change position of the xhair,
-- switch among things at that position.
aimFloorHuman :: (MonadClient m, MonadClientUI m) => m ()
aimFloorHuman = do
  lidV <- viewedLevelUI
  leader <- getLeaderUI
  lpos <- getsState $ bpos . getActorBody leader
  mxhairPos <- xhairToPos
  xhair <- getsSession sxhair
  saimMode <- getsSession saimMode
  bsAll <- getsState $ actorAssocs (const True) lidV
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  let xhairPos = fromMaybe lpos mxhairPos
      sxhair = case xhair of
        _ | isNothing saimMode ->  -- first key press: keep target
          xhair
        Just TEnemy{} -> Just $ TPoint TKnown lidV xhairPos
        Just TNonEnemy{} -> Just $ TPoint TKnown lidV xhairPos
        Just TPoint{} | xhairPos /= lpos ->
          Just $ TVector $ xhairPos `vectorToFrom` lpos
        Just TVector{} ->
          -- If many actors, we pick here the first that would be picked
          -- by '*', so that all other projectiles on the tile come next,
          -- when pressing '*', without any intervening actors from other tiles.
          -- This is why we use @actorAssocs@ above instead of @posToAidAssocs@.
          case find (\(_, b) -> Just (bpos b) == mxhairPos) bsAll of
            Just (aid, b) -> Just $ if isFoe side fact (bfid b)
                                    then TEnemy aid
                                    else TNonEnemy aid
            Nothing -> Just $ TPoint TUnknown lidV xhairPos
        _ -> xhair
  modifySession $ \sess -> sess {saimMode =
    let newDetail = maybe defaultDetailLevel detailLevel saimMode
    in Just $ AimMode lidV newDetail}
  setXHairFromGUI sxhair
  doLook

-- * AimEnemy

aimEnemyHuman :: (MonadClient m, MonadClientUI m) => m ()
aimEnemyHuman = do
  lidV <- viewedLevelUI
  leader <- getLeaderUI
  lpos <- getsState $ bpos . getActorBody leader
  mxhairPos <- xhairToPos
  xhair <- getsSession sxhair
  saimMode <- getsSession saimMode
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  bsAll <- getsState $ actorAssocs (const True) lidV
  let -- On the same position, big actors come before projectiles.
      ordPos (_, b) = (chessDist lpos $ bpos b, bpos b, bproj b)
      dbs = sortOn ordPos bsAll
      pickUnderXhair =  -- switch to the actor under xhair, if any
        fromMaybe (-1) $ findIndex ((== mxhairPos) . Just . bpos . snd) dbs
      (pickEnemies, i) = case xhair of
        Just (TEnemy a) | isJust saimMode ->  -- pick next enemy
          (True, 1 + fromMaybe (-1) (findIndex ((== a) . fst) dbs))
        Just (TEnemy a) ->  -- first key press, retarget old enemy
          (True, fromMaybe (-1) $ findIndex ((== a) . fst) dbs)
        Just (TNonEnemy a) | isJust saimMode ->  -- pick next non-enemy
          (False, 1 + fromMaybe (-1) (findIndex ((== a) . fst) dbs))
        Just (TNonEnemy a) ->  -- first key press, retarget old non-enemy
          (False, fromMaybe (-1) $ findIndex ((== a) . fst) dbs)
        _ -> (True, pickUnderXhair)
      (lt, gt) = splitAt i dbs
      isEnemy b = isFoe side fact (bfid b)
                  && not (bproj b)
                  && bhp b > 0
      cond = if pickEnemies then isEnemy else not . isEnemy
      lf = filter (cond . snd) $ gt ++ lt
      sxhair = case lf of
        (a, _) : _ -> Just $ if pickEnemies then TEnemy a else TNonEnemy a
        [] -> xhair  -- no seen foes in sight, stick to last target
  -- Register the chosen enemy, to pick another on next invocation.
  modifySession $ \sess -> sess {saimMode =
    let newDetail = maybe defaultDetailLevel detailLevel saimMode
    in Just $ AimMode lidV newDetail}
  setXHairFromGUI sxhair
  doLook

-- * AimItem

aimItemHuman :: (MonadClient m, MonadClientUI m) => m ()
aimItemHuman = do
  side <- getsClient sside
  lidV <- viewedLevelUI
  leader <- getLeaderUI
  lpos <- getsState $ bpos . getActorBody leader
  mxhairPos <- xhairToPos
  xhair <- getsSession sxhair
  saimMode <- getsSession saimMode
  Level{lfloor} <- getLevel lidV
  mstash <- getsState $ \s -> gstash $ sfactionD s EM.! side
  -- Don't consider own stash an ordinary pile of items.
  let lfloorBarStash = case mstash of
        Just (lid, pos) | lid == lidV -> EM.delete pos lfloor
        _ -> lfloor
      bsAll = EM.keys lfloorBarStash
      ordPos p = (chessDist lpos p, p)
      dbs = sortOn ordPos bsAll
      pickUnderXhair =  -- switch to the item under xhair, if any
        let i = fromMaybe (-1)
                $ findIndex ((== mxhairPos) . Just) dbs
        in splitAt i dbs
      (lt, gt) = case xhair of
        Just (TPoint _ lid pos)
          | isJust saimMode && lid == lidV ->  -- pick next item
            let i = fromMaybe (-1) $ findIndex (== pos) dbs
            in splitAt (i + 1) dbs
        Just (TPoint _ lid pos)
          | lid == lidV ->  -- first key press, retarget old item
            let i = fromMaybe (-1) $ findIndex (== pos) dbs
            in splitAt i dbs
        _ -> pickUnderXhair
      gtlt = gt ++ lt
      sxhair = case gtlt of
        p : _ -> Just $ TPoint TKnown lidV p  -- don't force AI to collect it
        [] -> xhair  -- no items remembered, stick to last target
  -- Register the chosen enemy, to pick another on next invocation.
  modifySession $ \sess -> sess {saimMode =
    let newDetail = maybe defaultDetailLevel detailLevel saimMode
    in Just $ AimMode lidV newDetail}
  setXHairFromGUI sxhair
  doLook

-- * AimAscend

-- | Change the displayed level in aiming mode to (at most)
-- k levels shallower. Enters aiming mode, if not already in one.
aimAscendHuman :: (MonadClient m, MonadClientUI m) => Int -> m MError
aimAscendHuman k = do
  dungeon <- getsState sdungeon
  lidV <- viewedLevelUI
  let up = k > 0
  case ascendInBranch dungeon up lidV of
    [] -> failMsg "no more levels in this direction"
    _ : _ -> do
      let ascendOne lid = case ascendInBranch dungeon up lid of
            [] -> lid
            nlid : _ -> nlid
          lidK = iterate ascendOne lidV !! abs k
      leader <- getLeaderUI
      lpos <- getsState $ bpos . getActorBody leader
      mxhairPos <- xhairToPos
      let xhairPos = fromMaybe lpos mxhairPos
          sxhair = Just $ TPoint TKnown lidK xhairPos
      modifySession $ \sess -> sess {saimMode =
        let newDetail = maybe defaultDetailLevel detailLevel (saimMode sess)
        in Just $ AimMode lidK newDetail}
      setXHairFromGUI sxhair
      doLook
      return Nothing

-- * EpsIncr

-- | Tweak the @eps@ parameter of the aiming digital line.
epsIncrHuman :: (MonadClient m, MonadClientUI m) => Direction -> m ()
epsIncrHuman d = do
  -- Perform the change:
  let sepsDelta = case d of
        Forward -> 1
        Backward -> -1
  modifyClient $ \cli -> cli {seps = seps cli + sepsDelta}
  invalidateBfsPathAll
  -- Provide UI feedback:
  -- Hack @sreportNull@ to display the new line even if no earlier messages.
  modifySession $ \sess -> sess {sreportNull = False}
  saimMode <- getsSession saimMode
  lidV <- viewedLevelUI
  modifySession $ \sess -> sess {saimMode =
    let newDetail = maybe DetailLow detailLevel saimMode
    in Just $ AimMode lidV newDetail}
  flashAiming
  modifySession $ \sess -> sess {saimMode}
  -- The change may not affect the line shape, hence 'possibly'.
  msgAdd MsgPromptAction "Aiming line (possibly) modified."

-- Flash the aiming line and path.
flashAiming :: MonadClientUI m => m ()
flashAiming = do
  lidV <- viewedLevelUI
  animate lidV pushAndDelay

-- * XhairUnknown

xhairUnknownHuman :: (MonadClient m, MonadClientUI m) => m MError
xhairUnknownHuman = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  mpos <- closestUnknown leader
  case mpos of
    Nothing -> failMsg "no more unknown spots left"
    Just p -> do
      let sxhair = Just $ TPoint TUnknown (blid b) p
      setXHairFromGUI sxhair
      doLook
      return Nothing

-- * XhairItem

xhairItemHuman :: (MonadClient m, MonadClientUI m) => m MError
xhairItemHuman = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  items <- closestItems leader
  case items of
    [] -> failMsg "no more reachable items remembered or visible"
    _ -> do
      let (_, (p, bag)) = maximumBy (comparing fst) items
          sxhair = Just $ TPoint (TItem bag) (blid b) p
      setXHairFromGUI sxhair
      doLook
      return Nothing

-- * XhairStair

xhairStairHuman :: (MonadClient m, MonadClientUI m) => Bool -> m MError
xhairStairHuman up = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  stairs <- closestTriggers (if up then ViaStairsUp else ViaStairsDown) leader
  case stairs of
    [] -> failMsg $ "no reachable stairs" <+> if up then "up" else "down"
    _ -> do
      let (_, (p, (p0, bag))) = maximumBy (comparing fst) stairs
          sxhair = Just $ TPoint (TEmbed bag p0) (blid b) p
      setXHairFromGUI sxhair
      doLook
      return Nothing

-- * XhairPointerFloor

xhairPointerFloorHuman :: (MonadClient m, MonadClientUI m) => m ()
xhairPointerFloorHuman = do
  saimMode <- getsSession saimMode
  aimPointerFloorHuman
  when (isNothing saimMode) $
    modifySession $ \sess -> sess {saimMode}

-- * XhairPointerEnemy

xhairPointerEnemyHuman :: (MonadClient m, MonadClientUI m) => m ()
xhairPointerEnemyHuman = do
  saimMode <- getsSession saimMode
  aimPointerEnemyHuman
  when (isNothing saimMode) $
    modifySession $ \sess -> sess {saimMode}

-- * AimPointerFloor

aimPointerFloorHuman :: (MonadClient m, MonadClientUI m) => m ()
aimPointerFloorHuman = do
  COps{corule=RuleContent{rXmax, rYmax}} <- getsState scops
  lidV <- viewedLevelUI
  -- Not @ScreenContent@, because not drawing here.
  K.PointUI x y <- getsSession spointer
  let (px, py) = (x `div` 2, y - K.mapStartY)
  if px >= 0 && py >= 0 && px < rXmax && py < rYmax
  then do
    oldXhair <- getsSession sxhair
    let sxhair = Just $ TPoint TUnknown lidV $ Point px py
        sxhairMoused = sxhair /= oldXhair
        detailSucc = if sxhairMoused
                     then detailLevel
                     else detailCycle . detailLevel
    modifySession $ \sess ->
      sess { saimMode =
               let newDetail = maybe defaultDetailLevel detailSucc
                                     (saimMode sess)
               in Just $ AimMode lidV newDetail
           , sxhairMoused }
    setXHairFromGUI sxhair
    doLook
  else stopPlayBack

-- * AimPointerEnemy

aimPointerEnemyHuman :: (MonadClient m, MonadClientUI m) => m ()
aimPointerEnemyHuman = do
  COps{corule=RuleContent{rXmax, rYmax}} <- getsState scops
  lidV <- viewedLevelUI
  -- Not @ScreenContent@, because not drawing here.
  K.PointUI x y <- getsSession spointer
  let (px, py) = (x `div` 2, y - K.mapStartY)
  if px >= 0 && py >= 0 && px < rXmax && py < rYmax
  then do
    bsAll <- getsState $ actorAssocs (const True) lidV
    oldXhair <- getsSession sxhair
    side <- getsClient sside
    fact <- getsState $ (EM.! side) . sfactionD
    let newPos = Point px py
        sxhair =
          -- If many actors, we pick here the first that would be picked
          -- by '*', so that all other projectiles on the tile come next,
          -- when pressing '*', without any intervening actors from other tiles.
          -- This is why we use @actorAssocs@ above instead of @posToAidAssocs@.
          case find (\(_, b) -> bpos b == newPos) bsAll of
            Just (aid, b) -> Just $ if isFoe side fact (bfid b)
                                    then TEnemy aid
                                    else TNonEnemy aid
            Nothing -> Just $ TPoint TUnknown lidV newPos
        sxhairMoused = sxhair /= oldXhair
        detailSucc = if sxhairMoused
                     then detailLevel
                     else detailCycle . detailLevel
    modifySession $ \sess ->
      sess { saimMode =
               let newDetail = maybe defaultDetailLevel detailSucc
                                     (saimMode sess)
               in Just $ AimMode lidV newDetail
           , sxhairMoused }
    setXHairFromGUI sxhair
    doLook
  else stopPlayBack
