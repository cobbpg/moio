import Control.Monad
import Network
import System.Environment
import System.IO

main = do
  args <- getArgs
  case args of
    server:name:_ -> chatWith server name
    _ -> putStrLn "Usage: BulletinBoardClient <host:port> <username>"

chatWith server name = do
  let (addr,_:port) = span (/=':') server
      portNum :: Int
      portNum = read port
  hdl <- connectTo addr ((PortNumber . fromIntegral) portNum)
  hSetBuffering hdl LineBuffering
  hPutStrLn hdl $ "#NAME " ++ name
  forever $ getLine >>= hPutStrLn hdl
