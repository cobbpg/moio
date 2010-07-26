import Control.Applicative
import Control.Concurrent
import Control.Moio as M
import Control.Monad
import Control.Monad.Fix
import Control.Monad.Trans
import Data.Char
import Data.Maybe
import Data.Monoid
import Graphics.UI.Gtk as Gtk hiding (get)
import Graphics.UI.Gtk.Gdk.Events hiding (Event)
import Graphics.UI.Gtk.Glade
import Network
import System.IO
import Text.Printf

black = (0, 0, 0)
blue = (0, 0, 200)
red = (200, 0, 0)

appendTextColour :: Label -> (Int, Int, Int) -> Bool -> String -> IO ()
appendTextColour label (r, g, b) isBold text = do
  oldText <- labelGetLabel label
  let pat = if isBold
            then "%s<span fgcolor=\"#%02x%02x%02x\"><b>%s</b></span>"
            else "%s<span fgcolor=\"#%02x%02x%02x\">%s</span>"
  labelSetMarkup label $ printf pat oldText r g b text

mkButtonE :: Button -> IO (Producer ())
mkButtonE button = do
  (event, sink) <- mkSink
  --button `on` buttonActivated $ sink (Just ()) -- too cutting edge for now
  onClicked button $ sink (Just ())
  return event

cycleA :: [a] -> Actor x a
cycleA vals = rep (cycle vals)
  where rep (x:xs) = get . const . put x $ rep xs

listenA :: PortNumber -> Actor x Handle
listenA port = mkA $ \sink -> do
  sock <- listenOn (PortNumber port)
  let go = forever $ do
        (hdl, _, _) <- accept sock
        hSetBuffering hdl LineBuffering
        sink (Just hdl)
      stop = sClose sock
  return (go, stop)

fetchLines :: Handle -> Producer String
fetchLines hdl = mkP $ \sink -> fix $ \loop -> do
  mline <- catch (Just <$> hGetLine hdl) (\_ -> return Nothing)
  case mline of
    Just line -> sink mline >> loop
    Nothing -> sink (Just "#END") >> sink Nothing

addName :: String -> Actor String (String, String)
addName name = get $ \line ->
  case words line of
    "#NAME":name':_ ->
      put (name, printf "From now on, my name is %s." name') (addName (escapeMarkup name'))
    _ -> put (name, line) (addName name)

main = withSocketsDo $ do
  initGUI

  timeoutAddFull (yield >> return True) priorityDefaultIdle 50

  Just xml <- xmlNew "BulletinBoard.glade"
  let getWidget cast name = xmlGetWidget xml cast name

  window <- getWidget castToWindow "mainWindow"
  onDestroy window mainQuit

  boardContents <- getWidget castToLabel "boardContents"
  let appendText = appendTextColour boardContents

  Just boardParent <- widgetGetParent boardContents
  widgetModifyBg boardParent StateNormal (Color 0xffff 0xffff 0xffff)

  toggleServer <- getWidget castToButton "toggleServer"
  toggleServerE <- mkButtonE toggleServer

  portNumber <- getWidget castToEntry "portNumber"

  let mainProducer = do
        toggle <- subscribe $ cycleA [True, False] <-< toggleServerE
        isStart <- toggle
        hdl <- if isStart
          then do
            port <- ioP $ do
              let readPort = fromMaybe 1234 . fmap fst . listToMaybe . reads
              p <- readPort <$> entryGetText portNumber
              entrySetText portNumber $ show p
              buttonSetLabel toggleServer "Stop server"
              appendText red True $ printf "Server started on port %d.\n" (p :: Int)
              return (fromIntegral p)
            listenA port <-< toggle
          else do
            ioP $ do
              buttonSetLabel toggleServer "Start server"
              appendText red True "Server stopped.\n"
            mempty
        let idstr = escapeMarkup (show hdl)
        ioP $ appendText blue True $ printf "New connection (id %s).\n" idstr
        (name, line) <- addName idstr <-< fetchLines hdl
        ioP $ if line /= "#END"
          then do
            appendText blue False $ printf "%s: " name
            appendText black False $ printf "%s\n" (escapeMarkup line)
          else do
            appendText blue True $ printf "%s disconnected.\n" name

  forkIO $ embed mainProducer

  widgetShowAll window
  mainGUI
