{-# LANGUAGE ExistentialQuantification #-}
-- |This module provides visual borders to be placed between and
-- around widgets.
module Graphics.Vty.Widgets.Borders
    ( Bordered
    , HBorder
    , VBorder
    , vBorder
    , hBorder
    , vBorderWith
    , hBorderWith
    , bordered
    )
where

import Control.Monad.Trans
    ( MonadIO
    )
import Data.Maybe
    ( catMaybes
    )
import Graphics.Vty
    ( Attr
    , DisplayRegion(DisplayRegion)
    , Image
    , char_fill
    , region_height
    , region_width
    , image_width
    , image_height
    , vert_cat
    , horiz_cat
    )
import Graphics.Vty.Widgets.Core
    ( WidgetImpl(..)
    , Widget
    , RenderContext(..)
    , newWidget
    , updateWidget
    , growVertical
    , growHorizontal
    , render
    , handleKeyEvent
    , getState
    , withWidth
    , withHeight
    , setPhysicalPosition
    )
import Graphics.Vty.Widgets.Box
    ( hBox
    )
import Graphics.Vty.Widgets.Text
    ( simpleText
    )

data HBorder = HBorder Attr Char
               deriving (Show)

-- |Create a single-row horizontal border.
hBorder :: (MonadIO m) => Attr -> m (Widget HBorder)
hBorder = hBorderWith '-'

-- |Create a single-row horizontal border using the specified
-- attribute and character.
hBorderWith :: (MonadIO m) => Char -> Attr -> m (Widget HBorder)
hBorderWith ch att = do
  wRef <- newWidget
  updateWidget wRef $ \w ->
      w { state = HBorder att ch
        , getGrowVertical = const $ return False
        , getGrowHorizontal = const $ return True
        , draw = \this s ctx -> do
                   HBorder attr _ <- getState this
                   let attr' = head $ catMaybes [ overrideAttr ctx, Just attr ]
                   return $ char_fill attr' ch (region_width s) 1
        }
  return wRef

data VBorder = VBorder Attr Char
               deriving (Show)

-- |Create a single-column vertical border.
vBorder :: (MonadIO m) => Attr -> m (Widget VBorder)
vBorder = vBorderWith '|'

-- |Create a single-column vertical border using the specified
-- attribute and character.
vBorderWith :: (MonadIO m) => Char -> Attr -> m (Widget VBorder)
vBorderWith ch att = do
  wRef <- newWidget
  updateWidget wRef $ \w ->
      w { state = VBorder att ch
        , getGrowHorizontal = const $ return False
        , getGrowVertical = const $ return True
        , draw = \this s ctx -> do
                   VBorder attr _ <- getState this
                   let attr' = head $ catMaybes [ overrideAttr ctx, Just attr ]
                   return $ char_fill attr' ch 1 (region_height s)
        }
  return wRef

data Bordered a = (Show a) => Bordered Attr (Widget a)

instance Show (Bordered a) where
    show (Bordered attr _) = concat [ "Bordered { attr = "
                                    , show attr
                                    , ", ... }"
                                    ]

-- |Wrap a widget in a bordering box using the specified attribute.
bordered :: (MonadIO m, Show a) => Attr -> Widget a -> m (Widget (Bordered a))
bordered att child = do
  wRef <- newWidget
  updateWidget wRef $ \w ->
      w { state = Bordered att child

        , getGrowVertical = const $ growVertical child
        , getGrowHorizontal = const $ growHorizontal child

        , keyEventHandler =
            \this key mods -> do
              Bordered _ ch <- getState this
              handleKeyEvent ch key mods

        , draw =
            \this s ctx -> do
              st <- getState this
              drawBordered st s ctx

        , setPosition =
            \this pos -> do
              (setPosition w) this pos
              Bordered _ ch <- getState this
              let chPos = pos
                          `withWidth` (region_width pos + 1)
                          `withHeight` (region_height pos + 1)
              setPhysicalPosition ch chPos
        }
  return wRef

drawBordered :: (Show a) =>
                Bordered a -> DisplayRegion -> RenderContext -> IO Image
drawBordered this s ctx = do
  let Bordered attr child = this
      attr' = head $ catMaybes [ overrideAttr ctx, Just attr ]

  -- Render the contained widget with enough room to draw borders.
  -- Then, use the size of the rendered widget to constrain the space
  -- used by the (expanding) borders.
  let constrained = DisplayRegion (region_width s - 2) (region_height s - 2)

  childImage <- render child constrained ctx

  let adjusted = DisplayRegion (image_width childImage + 2)
                 (image_height childImage)
  corner <- simpleText attr' "+"

  hb <- hBorder attr'
  topWidget <- hBox corner =<< hBox hb corner
  topBottom <- render topWidget adjusted ctx

  vb <- vBorder attr'
  leftRight <- render vb adjusted ctx

  let middle = horiz_cat [leftRight, childImage, leftRight]

  return $ vert_cat [topBottom, middle, topBottom]
