module MicroHttp.Spike1(main) where

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
main = serveOne 8080

serveOne :: Int -> IO ()
serveOne port = do
  sock <- checked "socket" (c_socket afInet sockStream 0)
  setReuseAddr sock
  withSockAddrIn port $ \ addr addrLen -> do
    _ <- checked "bind" (c_bind sock addr addrLen)
    _ <- checked "listen" (c_listen sock 16)
    putStrLn ("listening on http://127.0.0.1:" ++ show port)
    client <- acceptClient sock
    handleClient client
    _ <- c_close sock
    return ()

handleClient :: Int -> IO ()
handleClient client = do
  putStrLn "accepted client"
  allocaBytes 4096 $ \ buf -> do
    putStrLn "reading request"
    received <- c_recv client (castPtr buf) 4096 0
    putStrLn ("read " ++ show received ++ " bytes")
  putStrLn "sending response"
  sendAll client response
  putStrLn "response sent"
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

response :: String
response =
  "HTTP/1.1 200 OK\r\n" ++
  "Content-Type: text/plain\r\n" ++
  "Content-Length: 19\r\n" ++
  "Connection: close\r\n" ++
  "\r\n" ++
  "micro-http spike 1\n"
