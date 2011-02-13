module Graphics.Vty.Widgets.DirBrowser
    ( DirBrowser(dirBrowserWidget, dirBrowserList)
    , BrowserSkin(..)
    , newDirBrowser
    , withAnnotations
    , setDirBrowserPath
    , getDirBrowserPath
    , defaultBrowserSkin
    , onBrowseAccept
    , onBrowseCancel
    , onBrowserPathChange
    )
where

import Data.IORef
import qualified Data.Map as Map
import Control.Monad
import Control.Monad.Trans
import Graphics.Vty
import Graphics.Vty.Widgets.Core
import Graphics.Vty.Widgets.List
import Graphics.Vty.Widgets.Text
import Graphics.Vty.Widgets.Box
import Graphics.Vty.Widgets.Fills
import Graphics.Vty.Widgets.Util
import Graphics.Vty.Widgets.Events
import System.Directory
import System.FilePath
import System.Posix.Files

type T = Widget (Box
                  (Box (Box FormattedText FormattedText) HFill)
                  (Box
                   (List String FormattedText)
                   (Box
                    (Box FormattedText FormattedText) HFill)))

data DirBrowser = DirBrowser { dirBrowserWidget :: T
                             , dirBrowserList :: Widget (List String FormattedText)
                             , dirBrowserPath :: IORef FilePath
                             , dirBrowserPathDisplay :: Widget FormattedText
                             , dirBrowserSelectionMap :: IORef (Map.Map FilePath Int)
                             , dirBrowserFileInfo :: Widget FormattedText
                             , dirBrowserSkin :: BrowserSkin
                             , dirBrowserChooseHandlers :: Handlers FilePath
                             , dirBrowserCancelHandlers :: Handlers FilePath
                             , dirBrowserPathChangeHandlers :: Handlers FilePath
                             }

data BrowserSkin = BrowserSkin { browserHeaderAttr :: Attr
                               , browserUnfocusedSelAttr :: Attr
                               , browserDirAttr :: Attr
                               , browserLinkAttr :: Attr
                               , browserBlockDevAttr :: Attr
                               , browserNamedPipeAttr :: Attr
                               , browserCharDevAttr :: Attr
                               , browserSockAttr :: Attr
                               , browserCustomAnnotations :: [ (FilePath -> FileStatus -> Bool
                                                               , FilePath -> FileStatus -> IO String
                                                               , Attr)
                                                             ]
                               }

defaultBrowserSkin :: BrowserSkin
defaultBrowserSkin = BrowserSkin { browserHeaderAttr = white `on` blue
                                 , browserUnfocusedSelAttr = bgColor blue
                                 , browserDirAttr = fgColor green
                                 , browserLinkAttr = fgColor cyan
                                 , browserBlockDevAttr = fgColor red
                                 , browserNamedPipeAttr = fgColor yellow
                                 , browserCharDevAttr = fgColor red
                                 , browserSockAttr = fgColor magenta
                                 , browserCustomAnnotations = []
                                 }

withAnnotations :: BrowserSkin
                -> [(FilePath -> FileStatus -> Bool, FilePath -> FileStatus -> IO String, Attr)]
                -> BrowserSkin
withAnnotations sk as = sk { browserCustomAnnotations = browserCustomAnnotations sk ++ as }

newDirBrowser :: (MonadIO m) => BrowserSkin -> m DirBrowser
newDirBrowser bSkin = do
  path <- liftIO $ getCurrentDirectory
  pathWidget <- simpleText ""
  header <- ((simpleText " Path: ") <++> (return pathWidget) <++> (hFill ' ' 1))
            >>= withNormalAttribute (browserHeaderAttr bSkin)

  fileInfo <- simpleText ""
  footer <- ((simpleText " ") <++> (return fileInfo) <++> (hFill ' ' 1))
            >>= withNormalAttribute (browserHeaderAttr bSkin)

  l <- newListWidget =<< newList (browserUnfocusedSelAttr bSkin) (simpleText . (" " ++))
  ui <- vBox header =<< vBox l footer

  r <- liftIO $ newIORef ""
  r2 <- liftIO $ newIORef Map.empty

  hs <- newHandlers
  chs <- newHandlers
  pchs <- newHandlers

  let b = DirBrowser { dirBrowserWidget = ui
                     , dirBrowserList = l
                     , dirBrowserPath = r
                     , dirBrowserPathDisplay = pathWidget
                     , dirBrowserSelectionMap = r2
                     , dirBrowserFileInfo = fileInfo
                     , dirBrowserSkin = bSkin
                     , dirBrowserChooseHandlers = hs
                     , dirBrowserCancelHandlers = chs
                     , dirBrowserPathChangeHandlers = pchs
                     }

  l `onKeyPressed` handleBrowserKey b
  l `onSelectionChange` handleSelectionChange b
  b `onBrowserPathChange` setText (dirBrowserPathDisplay b)

  fg <- newFocusGroup
  _ <- addToFocusGroup fg l
  setFocusGroup ui fg

  setDirBrowserPath b path
  return b

onBrowseAccept :: (MonadIO m) => DirBrowser -> (FilePath -> IO ()) -> m ()
onBrowseAccept = addHandler (return . dirBrowserChooseHandlers)

onBrowseCancel :: (MonadIO m) => DirBrowser -> (FilePath -> IO ()) -> m ()
onBrowseCancel = addHandler (return . dirBrowserCancelHandlers)

onBrowserPathChange :: (MonadIO m) => DirBrowser -> (FilePath -> IO ()) -> m ()
onBrowserPathChange = addHandler (return . dirBrowserPathChangeHandlers)

cancelBrowse :: (MonadIO m) => DirBrowser -> m ()
cancelBrowse b = fireEvent b (return . dirBrowserCancelHandlers) =<< getDirBrowserPath b

chooseCurrentEntry :: (MonadIO m) => DirBrowser -> m ()
chooseCurrentEntry b = do
  p <- getDirBrowserPath b
  mCur <- getSelected (dirBrowserList b)
  case mCur of
    Nothing -> return ()
    Just (_, (e, _)) -> fireEvent b (return . dirBrowserChooseHandlers) (p </> e)

handleSelectionChange :: DirBrowser -> SelectionEvent String b -> IO ()
handleSelectionChange b ev = do
  case ev of
    SelectionOff -> setText (dirBrowserFileInfo b) "-"
    SelectionOn _ path _ -> setText (dirBrowserFileInfo b) =<< getFileInfo b path

getFileInfo :: (MonadIO m) => DirBrowser -> FilePath -> m String
getFileInfo b path = do
  cur <- getDirBrowserPath b
  let newPath = cur </> path
  st <- liftIO $ getSymbolicLinkStatus newPath
  (_, mkAnn) <- fileAnnotation (dirBrowserSkin b) st cur path
  ann <- liftIO mkAnn
  return $ path ++ ": " ++ ann

fileAnnotation :: (MonadIO m) => BrowserSkin -> FileStatus -> FilePath -> FilePath -> m (Attr, IO String)
fileAnnotation sk st cur shortPath = do
  let fullPath = cur </> shortPath

      customAnnotation = customAnnotation' fullPath st $ (browserCustomAnnotations sk) ++
                         builtIns
      builtIns = [ (\_ s -> isRegularFile s
                   , \_ s -> return $ "regular file, " ++
                           (show $ fileSize s) ++ " bytes"
                   , def_attr)
                 , (\_ s -> isSymbolicLink s, (\p stat -> do
                            linkDest <- if not $ isSymbolicLink stat
                                        then return ""
                                        else do
                                          linkPath <- liftIO $ readSymbolicLink p
                                          liftIO $ canonicalizePath $ cur </> linkPath
                            return $ "symbolic link to " ++ linkDest)
                   , browserLinkAttr sk)
                 , (\_ s -> isDirectory s, \_ _ -> return "directory", browserDirAttr sk)
                 , (\_ s -> isBlockDevice s, \_ _ -> return "block device", browserBlockDevAttr sk)
                 , (\_ s -> isNamedPipe s, \_ _ -> return "named pipe", browserNamedPipeAttr sk)
                 , (\_ s -> isCharacterDevice s, \_ _ -> return "character device", browserCharDevAttr sk)
                 , (\_ s -> isSocket s, \_ _ -> return "socket", browserSockAttr sk)
                 ]

      customAnnotation' _ _ [] = (def_attr, return "")
      customAnnotation' pth stat ((f,mkAnn,a):rest) =
          if f pth stat
          then (a, mkAnn pth stat)
          else customAnnotation' pth stat rest

  return customAnnotation

handleBrowserKey :: DirBrowser -> Widget (List a b) -> Key -> [Modifier] -> IO Bool
handleBrowserKey b _ KEnter [] = descend b True >> return True
handleBrowserKey b _ KRight [] = descend b False >> return True
handleBrowserKey b _ KLeft [] = ascend b >> return True
handleBrowserKey b _ KEsc [] = cancelBrowse b >> return True
handleBrowserKey b _ (KASCII 'q') [] = cancelBrowse b >> return True
handleBrowserKey _ _ _ _ = return False

setDirBrowserPath :: (MonadIO m) => DirBrowser -> FilePath -> m ()
setDirBrowserPath b path = do
  -- If something is currently selected, store that in the selection
  -- map before changing the path.
  cur <- getDirBrowserPath b
  mCur <- getSelected (dirBrowserList b)
  case mCur of
    Nothing -> return ()
    Just (i, _) -> storeSelection b cur i

  clearList (dirBrowserList b)
  cPath <- liftIO $ canonicalizePath path
  liftIO $ modifyIORef (dirBrowserPath b) $ const cPath
  load b

  res <- getSelection b path
  case res of
    Nothing -> return ()
    Just i -> scrollBy (dirBrowserList b) i

  fireEvent b (return . dirBrowserPathChangeHandlers) cPath

getDirBrowserPath :: (MonadIO m) => DirBrowser -> m FilePath
getDirBrowserPath = liftIO . readIORef . dirBrowserPath

storeSelection :: (MonadIO m) => DirBrowser -> FilePath -> Int -> m ()
storeSelection b path i =
    liftIO $ modifyIORef (dirBrowserSelectionMap b) $ \m -> Map.insert path i m

getSelection :: (MonadIO m) => DirBrowser -> FilePath -> m (Maybe Int)
getSelection b path =
    liftIO $ do
      st <- readIORef (dirBrowserSelectionMap b)
      return $ Map.lookup path st

load :: (MonadIO m) => DirBrowser -> m ()
load b = do
  cur <- getDirBrowserPath b
  -- XXX catch permission exception
  entries <- liftIO (getDirectoryContents cur)
  forM_ entries $ \entry -> do
           let fullPath = cur </> entry
           f <- liftIO $ getSymbolicLinkStatus fullPath
           (attr, _) <- fileAnnotation (dirBrowserSkin b) f cur entry
           (_, w) <- addToList (dirBrowserList b) (entry)
           setNormalAttribute w attr

descend :: (MonadIO m) => DirBrowser -> Bool -> m ()
descend b shouldSelect = do
  base <- getDirBrowserPath b
  mCur <- getSelected (dirBrowserList b)
  case mCur of
    Nothing -> return ()
    Just (_, (p, _)) -> do
              let newPath = base </> p
              e <- liftIO $ doesDirectoryExist newPath
              case e of
                True -> do
                       cPath <- liftIO $ canonicalizePath newPath
                       cur <- getDirBrowserPath b
                       when (cur /= cPath) $ do
                          case takeDirectory cur == cPath of
                            True -> ascend b
                            False -> setDirBrowserPath b cPath

                False -> when shouldSelect $ chooseCurrentEntry b

ascend :: (MonadIO m) => DirBrowser -> m ()
ascend b = do
  cur <- liftIO $ getDirBrowserPath b
  let newPath = takeDirectory cur
  when (newPath /= cur) $
       setDirBrowserPath b newPath