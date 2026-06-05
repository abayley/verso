module MicroHttp.Spike2(main) where

import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Exception
import Data.Word
import Foreign.C.String
import Foreign.Marshal.Alloc
import Foreign.Ptr
import Foreign.Storable

foreign import ccall "socket" c_socket :: Int -> Int -> Int -> IO Int
foreign import ccall "setsockopt" c_setsockopt :: Int -> Int -> Int -> Ptr Int -> Int -> IO Int
foreign import ccall "bind" c_bind :: Int -> Ptr () -> Int -> IO Int
foreign import ccall "listen" c_listen :: Int -> Int -> IO Int
foreign import ccall "accept" c_accept :: Int -> Ptr () -> Ptr Int -> IO Int
foreign import ccall "recv" c_recv :: Int -> CString -> Int -> Int -> IO Int
foreign import ccall "send" c_send :: Int -> CString -> Int -> Int -> IO Int
foreign import ccall "close" c_close :: Int -> IO Int

foreign import capi "sys/socket.h value AF_INET" afInet :: Int
foreign import capi "sys/socket.h value SOCK_STREAM" sockStream :: Int
foreign import capi "sys/socket.h value SOL_SOCKET" solSocket :: Int
foreign import capi "sys/socket.h value SO_REUSEADDR" soReuseAddr :: Int

main :: IO ()
main = serveMany settings

data Settings = Settings
  { settingsPort :: Int
  , settingsBacklog :: Int
  , settingsMaxActiveHandlers :: Int
  , settingsRequestsToAccept :: Int
  }

settings :: Settings
settings = Settings
  { settingsPort = 8080
  , settingsBacklog = 16
  , settingsMaxActiveHandlers = 2
  , settingsRequestsToAccept = 6
  }

serveMany :: Settings -> IO ()
serveMany cfg = do
  sock <- checked "socket" (c_socket afInet sockStream 0)
  setReuseAddr sock
  sem <- newQSem (settingsMaxActiveHandlers cfg)
  done <- newEmptyMVar
  withSockAddrIn (settingsPort cfg) $ \ addr addrLen -> do
    _ <- checked "bind" (c_bind sock addr addrLen)
    _ <- checked "listen" (c_listen sock (settingsBacklog cfg))
    putStrLn ("listening on http://127.0.0.1:" ++ show (settingsPort cfg))
    acceptLoop cfg sock sem done 1
    waitForHandlers (settingsRequestsToAccept cfg) done
    _ <- c_close sock
    putStrLn "server stopped"

acceptLoop :: Settings -> Int -> QSem -> MVar Int -> Int -> IO ()
acceptLoop cfg sock sem done requestNumber
  | requestNumber > settingsRequestsToAccept cfg = return ()
  | otherwise = do
      client <- acceptClient sock
      _ <- forkIO (runHandler sem done requestNumber client)
      acceptLoop cfg sock sem done (requestNumber + 1)

runHandler :: QSem -> MVar Int -> Int -> Int -> IO ()
runHandler sem done requestNumber client =
  finally
    (do
      waitQSem sem
      finally (handleClient requestNumber client) (signalQSem sem))
    (putMVar done requestNumber)

waitForHandlers :: Int -> MVar Int -> IO ()
waitForHandlers total done = go 0
  where
    go finished
      | finished >= total = return ()
      | otherwise = do
          requestNumber <- takeMVar done
          putStrLn ("completed request " ++ show requestNumber)
          go (finished + 1)

handleClient :: Int -> Int -> IO ()
handleClient requestNumber client = do
  putStrLn ("accepted request " ++ show requestNumber)
  allocaBytes 4096 $ \ buf -> do
    received <- c_recv client (castPtr buf) 4096 0
    putStrLn ("request " ++ show requestNumber ++ " read " ++ show received ++ " bytes")
  threadDelay 250000
  sendAll client (response requestNumber)
  _ <- c_close client
  return ()

acceptClient :: Int -> IO Int
acceptClient sock =
  allocaBytes sockaddrInSize $ \ addr ->
    alloca $ \ addrLen -> do
      poke addrLen sockaddrInSize
      checked "accept" (c_accept sock (castPtr addr) addrLen)

sendAll :: Int -> String -> IO ()
sendAll fd bytes =
  withCAStringLen bytes $ \ (ptr, len) -> do
    sent <- c_send fd ptr len 0
    if sent == len then
      return ()
    else
      error ("send wrote " ++ show sent ++ " of " ++ show len ++ " bytes")

setReuseAddr :: Int -> IO ()
setReuseAddr sock =
  alloca $ \ opt -> do
    poke opt (1 :: Int)
    _ <- checked "setsockopt" (c_setsockopt sock solSocket soReuseAddr opt (sizeOf (1 :: Int)))
    return ()

withSockAddrIn :: Int -> (Ptr () -> Int -> IO a) -> IO a
withSockAddrIn port use =
  allocaBytes sockaddrInSize $ \ ptr -> do
    zeroBytes ptr sockaddrInSize
    pokeByteOff ptr 0 (fromIntegral sockaddrInSize :: Word8)
    pokeByteOff ptr 1 (fromIntegral afInet :: Word8)
    pokeByteOff ptr 2 (fromIntegral (port `quot` 256) :: Word8)
    pokeByteOff ptr 3 (fromIntegral (port `rem` 256) :: Word8)
    pokeByteOff ptr 4 (127 :: Word8)
    pokeByteOff ptr 5 (0 :: Word8)
    pokeByteOff ptr 6 (0 :: Word8)
    pokeByteOff ptr 7 (1 :: Word8)
    use (castPtr ptr) sockaddrInSize

zeroBytes :: Ptr Word8 -> Int -> IO ()
zeroBytes ptr len = go 0
  where
    go index
      | index >= len = return ()
      | otherwise = do
          pokeByteOff ptr index (0 :: Word8)
          go (index + 1)

checked :: String -> IO Int -> IO Int
checked label action = do
  result <- action
  if result < 0 then
    error (label ++ " failed")
  else
    return result

sockaddrInSize :: Int
sockaddrInSize = 16

response :: Int -> String
response requestNumber =
  "HTTP/1.1 200 OK\r\n" ++
  "Content-Type: text/plain\r\n" ++
  "Content-Length: " ++ show (length body) ++ "\r\n" ++
  "Connection: close\r\n" ++
  "\r\n" ++
  body
  where
    body = "micro-http spike 2 request " ++ show requestNumber ++ "\n"
