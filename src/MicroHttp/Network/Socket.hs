module MicroHttp.Network.Socket
  ( ClientSocket
  , Host(..)
  , ListenSocket
  , Port(..)
  , SocketError(..)
  , accept
  , closeClientSocket
  , closeListenSocket
  , listenTcp
  , recv
  , sendAll
  ) where

import qualified Data.ByteString as BS
import Data.Word(Word8)
import Foreign.C.Error(Errno, getErrno)
import Foreign.C.String(CString)
import Foreign.Marshal.Alloc(alloca, allocaBytes)
import Foreign.Ptr(Ptr, castPtr, plusPtr)
import Foreign.Storable(poke, pokeByteOff, sizeOf)

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

newtype ListenSocket = ListenSocket Int
  deriving (Eq, Show)

newtype ClientSocket = ClientSocket Int
  deriving (Eq, Show)

data Host
  = HostAny
  | HostIPv4 Word8 Word8 Word8 Word8
  deriving (Eq, Show)

newtype Port = Port Int
  deriving (Eq, Show)

data SocketError = SocketError String Errno
  deriving (Eq, Show)

listenTcp :: Host -> Port -> Int -> IO (Either SocketError ListenSocket)
listenTcp host port backlog = do
  opened <- checked "socket" (c_socket afInet sockStream 0)
  case opened of
    Left err -> return (Left err)
    Right fd -> do
      reuse <- setReuseAddr fd
      case reuse of
        Left err -> closeAndReturn fd err
        Right () ->
          withSockAddrIn host port $ \ addr addrLen -> do
            bound <- checked "bind" (c_bind fd addr addrLen)
            case bound of
              Left err -> closeAndReturn fd err
              Right _ -> do
                listening <- checked "listen" (c_listen fd backlog)
                case listening of
                  Left err -> closeAndReturn fd err
                  Right _ -> return (Right (ListenSocket fd))

accept :: ListenSocket -> IO (Either SocketError ClientSocket)
accept (ListenSocket fd) =
  allocaBytes sockaddrInSize $ \ addr ->
    alloca $ \ addrLen -> do
      poke addrLen sockaddrInSize
      accepted <- checked "accept" (c_accept fd (castPtr addr) addrLen)
      return (fmap ClientSocket accepted)

recv :: ClientSocket -> Int -> IO (Either SocketError BS.ByteString)
recv (ClientSocket fd) byteCount =
  allocaBytes byteCount $ \ buf -> do
    received <- checked "recv" (c_recv fd (castPtr buf) byteCount 0)
    case received of
      Left err -> return (Left err)
      Right count -> do
        bytes <- BS.packCStringLen (castPtr buf, count)
        return (Right bytes)

sendAll :: ClientSocket -> BS.ByteString -> IO (Either SocketError ())
sendAll (ClientSocket fd) bytes =
  BS.useAsCStringLen bytes $ \ (ptr, len) ->
    sendLoop fd ptr len

closeListenSocket :: ListenSocket -> IO (Either SocketError ())
closeListenSocket (ListenSocket fd) = closeFd fd

closeClientSocket :: ClientSocket -> IO (Either SocketError ())
closeClientSocket (ClientSocket fd) = closeFd fd

sendLoop :: Int -> CString -> Int -> IO (Either SocketError ())
sendLoop _ _ remaining | remaining <= 0 = return (Right ())
sendLoop fd ptr remaining = do
  sent <- checked "send" (c_send fd ptr remaining 0)
  case sent of
    Left err -> return (Left err)
    Right count -> sendLoop fd (advanceCString ptr count) (remaining - count)

advanceCString :: CString -> Int -> CString
advanceCString ptr count = castPtr (castPtr ptr `plusPtr` count)

closeFd :: Int -> IO (Either SocketError ())
closeFd fd = do
  closed <- checked "close" (c_close fd)
  case closed of
    Left err -> return (Left err)
    Right _ -> return (Right ())

setReuseAddr :: Int -> IO (Either SocketError ())
setReuseAddr fd =
  alloca $ \ opt -> do
    poke opt (1 :: Int)
    result <- checked "setsockopt"
      (c_setsockopt fd solSocket soReuseAddr opt (sizeOf (1 :: Int)))
    case result of
      Left err -> return (Left err)
      Right _ -> return (Right ())

closeAndReturn :: Int -> SocketError -> IO (Either SocketError ListenSocket)
closeAndReturn fd err = do
  _ <- c_close fd
  return (Left err)

checked :: String -> IO Int -> IO (Either SocketError Int)
checked label action = do
  result <- action
  if result < 0 then do
    errno <- getErrno
    return (Left (SocketError label errno))
  else
    return (Right result)

withSockAddrIn :: Host -> Port -> (Ptr () -> Int -> IO a) -> IO a
withSockAddrIn host (Port port) use =
  allocaBytes sockaddrInSize $ \ ptr -> do
    zeroBytes ptr sockaddrInSize
    pokeByteOff ptr 0 (fromIntegral sockaddrInSize :: Word8)
    pokeByteOff ptr 1 (fromIntegral afInet :: Word8)
    pokeByteOff ptr 2 (fromIntegral (port `quot` 256) :: Word8)
    pokeByteOff ptr 3 (fromIntegral (port `rem` 256) :: Word8)
    pokeHost ptr host
    use (castPtr ptr) sockaddrInSize

pokeHost :: Ptr Word8 -> Host -> IO ()
pokeHost ptr host =
  case host of
    HostAny -> do
      pokeByteOff ptr 4 (0 :: Word8)
      pokeByteOff ptr 5 (0 :: Word8)
      pokeByteOff ptr 6 (0 :: Word8)
      pokeByteOff ptr 7 (0 :: Word8)
    HostIPv4 a b c d -> do
      pokeByteOff ptr 4 a
      pokeByteOff ptr 5 b
      pokeByteOff ptr 6 c
      pokeByteOff ptr 7 d

zeroBytes :: Ptr Word8 -> Int -> IO ()
zeroBytes ptr len = go 0
  where
    go index
      | index >= len = return ()
      | otherwise = do
          pokeByteOff ptr index (0 :: Word8)
          go (index + 1)

sockaddrInSize :: Int
sockaddrInSize = 16
