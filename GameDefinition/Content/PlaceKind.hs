-- | Rooms, halls and passages for LambdaHack.
module Content.PlaceKind ( cdefs ) where

import Game.LambdaHack.Common.ContentDef
import Game.LambdaHack.Content.PlaceKind

cdefs :: ContentDef PlaceKind
cdefs = ContentDef
  { getSymbol = psymbol
  , getName = pname
  , getFreq = pfreq
  , validate = validatePlaceKind
  , content =
      [rect, ruin, pillar, pillarC, pillar3, colonnade, colonnadeW, lampPost, lampPost2, lampPost3]
  }
rect,        ruin, pillar, pillarC, pillar3, colonnade, colonnadeW, lampPost, lampPost2, lampPost3 :: PlaceKind

rect = PlaceKind  -- Valid for any nonempty area, hence low frequency.
  { psymbol  = 'r'
  , pname    = "room"
  , pfreq    = [("rogue", 100), ("ambush", 5)]
  , pcover   = CStretch
  , pfence   = FNone
  , ptopLeft = [ "--"
               , "|."
               ]
  , poverride = []
  }
ruin = PlaceKind
  { psymbol  = 'R'
  , pname    = "ruin"
  , pfreq    = [("ambush", 20)]
  , pcover   = CStretch
  , pfence   = FNone
  , ptopLeft = [ "--"
               , "|X"
               ]
  , poverride = []
  }
pillar = PlaceKind
  { psymbol  = 'p'
  , pname    = "pillar room"
  , pfreq    = [("rogue", 1000)]  -- larger rooms require support pillars
  , pcover   = CStretch
  , pfence   = FNone
  , ptopLeft = [ "-----"
               , "|...."
               , "|.O.."
               , "|...."
               , "|...."
               ]
  , poverride = []
  }
pillarC = pillar
  { ptopLeft = [ "-----"
               , "|O..."
               , "|...."
               , "|...."
               , "|...."
               ]
  }
pillar3 = pillar
  { ptopLeft = [ "-----"
               , "|&.O."
               , "|...."
               , "|O..."
               , "|...."
               ]
  }
colonnade = PlaceKind
  { psymbol  = 'c'
  , pname    = "colonnade"
  , pfreq    = [("rogue", 500)]
  , pcover   = CAlternate
  , pfence   = FFloor
  , ptopLeft = [ "O."
               , ".O"
               ]
  , poverride = []
  }
colonnadeW = colonnade
  { ptopLeft = [ "O."
               , ".."
               ]
  }
lampPost = PlaceKind
  { psymbol  = 'l'
  , pname    = "lamp post"
  , pfreq    = [("ambush", 50)]
  , pcover   = CVerbatim
  , pfence   = FNone
  , ptopLeft = [ "X.X"
               , ".O."
               , "X.X"
               ]
  , poverride = [('O', "ambushOverO")]
  }
lampPost2 = lampPost
  { pfreq    = [("ambush", 50)]
  , ptopLeft = [ "..."
               , ".O."
               , "..."
               ]
  }
lampPost3 = lampPost
  { pfreq    = [("ambush", 999)]
  , ptopLeft = [ "XX.XX"
               , "X...X"
               , "..O.."
               , "X...X"
               , "XX.XX"
               ]
  }
