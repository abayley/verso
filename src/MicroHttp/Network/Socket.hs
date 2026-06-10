module MicroHttp.Network.Socket (
    ClientSocket,
    Host (..),
    ListenSocket,
    Port (..),
    SocketError (..),
    accept,
    boundPort,
    closeClientSocket,
    closeListenSocket,
    connectTcp,
    encodeSockAddrIn,
    listenTcp,
    recv,
    sendAll,
) where

import Control.Concurrent (threadDelay)
import qualified Data.ByteString as BS
import Data.Word (Word8)
import Foreign.C.Error (Errno, eAGAIN, eALREADY, eINPROGRESS, eISCONN, eWOULDBLOCK, getErrno)
import Foreign.C.String (CString)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (peekByteOff, poke, pokeByteOff, sizeOf)

foreign import ccall "socket" c_socket :: Int -> Int -> Int -> IO Int
foreign import ccall "setsockopt" c_setsockopt :: Int -> Int -> Int -> Ptr Int -> Int -> IO Int
foreign import ccall "fcntl" c_fcntl :: Int -> Int -> Int -> IO Int
foreign import ccall "bind" c_bind :: Int -> Ptr () -> Int -> IO Int
foreign import ccall "connect" c_connect :: Int -> Ptr () -> Int -> IO Int
foreign import ccall "listen" c_listen :: Int -> Int -> IO Int
foreign import ccall "accept" c_accept :: Int -> Ptr () -> Ptr Int -> IO Int
foreign import ccall "getsockname" c_getsockname :: Int -> Ptr () -> Ptr Int -> IO Int
foreign import ccall "recv" c_recv :: Int -> CString -> Int -> Int -> IO Int
foreign import ccall "send" c_send :: Int -> CString -> Int -> Int -> IO Int
foreign import ccall "close" c_close :: Int -> IO Int

foreign import capi "sys/socket.h value AF_INET" afInet :: Int
foreign import capi "sys/socket.h value SOCK_STREAM" sockStream :: Int
foreign import capi "sys/socket.h value SOL_SOCKET" solSocket :: Int
foreign import capi "sys/socket.h value SO_REUSEADDR" soReuseAddr :: Int
foreign import capi "fcntl.h value F_SETFL" fSetFl :: Int
foreign import capi "fcntl.h value O_NONBLOCK" oNonBlock :: Int

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
    deriving (Eq)

instance Show SocketError where
    show (SocketError operation _) = "SocketError " ++ show operation

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
                    withSockAddrIn host port $ \addr addrLen -> do
                        bound <- checked "bind" (c_bind fd addr addrLen)
                        case bound of
                            Left err -> closeAndReturn fd err
                            Right _ -> do
                                listening <- checked "listen" (c_listen fd backlog)
                                case listening of
                                    Left err -> closeAndReturn fd err
                                    Right _ -> do
                                        nonBlocking <- setNonBlocking fd
                                        case nonBlocking of
                                            Left err -> closeAndReturn fd err
                                            Right () -> return (Right (ListenSocket fd))

accept :: ListenSocket -> IO (Either SocketError ClientSocket)
accept (ListenSocket fd) =
    allocaBytes sockaddrInSize $ \addr ->
        alloca $ \addrLen ->
            acceptLoop addr addrLen
  where
    acceptLoop addr addrLen = do
        poke addrLen sockaddrInSize
        accepted <- c_accept fd (castPtr addr) addrLen
        if accepted < 0
            then do
                errno <- getErrno
                if isWouldBlock errno
                    then do
                        threadDelay pollDelayMicros
                        acceptLoop addr addrLen
                    else return (Left (SocketError "accept" errno))
            else do
                nonBlocking <- setNonBlocking accepted
                case nonBlocking of
                    Left err -> do
                        _ <- c_close accepted
                        return (Left err)
                    Right () -> return (Right (ClientSocket accepted))

{- | Connects a non-blocking TCP client socket to a host and port.
The socket is non-blocking before connecting, so connection progress is
polled: in-progress results retry until the socket reports connected.
-}
connectTcp :: Host -> Port -> IO (Either SocketError ClientSocket)
connectTcp host port = do
    opened <- checked "socket" (c_socket afInet sockStream 0)
    case opened of
        Left err -> return (Left err)
        Right fd -> do
            nonBlocking <- setNonBlocking fd
            case nonBlocking of
                Left err -> do
                    _ <- c_close fd
                    return (Left err)
                Right () -> withSockAddrIn host port (connectLoop fd)

connectLoop :: Int -> Ptr () -> Int -> IO (Either SocketError ClientSocket)
connectLoop fd addr addrLen = do
    connected <- c_connect fd addr addrLen
    if connected >= 0
        then return (Right (ClientSocket fd))
        else do
            errno <- getErrno
            if errno == eISCONN
                then return (Right (ClientSocket fd))
                else
                    if isConnectPending errno
                        then do
                            threadDelay pollDelayMicros
                            connectLoop fd addr addrLen
                        else do
                            _ <- c_close fd
                            return (Left (SocketError "connect" errno))

isConnectPending :: Errno -> Bool
isConnectPending errno =
    errno == eINPROGRESS || errno == eALREADY || isWouldBlock errno

-- | Returns the locally bound port of a listening socket.
boundPort :: ListenSocket -> IO (Either SocketError Port)
boundPort (ListenSocket fd) =
    allocaBytes sockaddrInSize $ \addr ->
        alloca $ \addrLen -> do
            poke addrLen sockaddrInSize
            queried <- checked "getsockname" (c_getsockname fd (castPtr addr) addrLen)
            case queried of
                Left err -> return (Left err)
                Right _ -> do
                    high <- peekWord8 addr 2
                    low <- peekWord8 addr 3
                    return (Right (Port (fromIntegral high * 256 + fromIntegral low)))

peekWord8 :: Ptr Word8 -> Int -> IO Word8
peekWord8 = peekByteOff

recv :: ClientSocket -> Int -> IO (Either SocketError BS.ByteString)
recv (ClientSocket fd) byteCount =
    allocaBytes byteCount $ \buf ->
        recvLoop buf
  where
    recvLoop buf = do
        received <- c_recv fd (castPtr buf) byteCount 0
        if received < 0
            then do
                errno <- getErrno
                if isWouldBlock errno
                    then do
                        threadDelay pollDelayMicros
                        recvLoop buf
                    else return (Left (SocketError "recv" errno))
            else do
                bytes <- BS.packCStringLen (castPtr buf, received)
                return (Right bytes)

sendAll :: ClientSocket -> BS.ByteString -> IO (Either SocketError ())
sendAll (ClientSocket fd) bytes =
    BS.useAsCStringLen bytes (uncurry (sendLoop fd))

closeListenSocket :: ListenSocket -> IO (Either SocketError ())
closeListenSocket (ListenSocket fd) = closeFd fd

closeClientSocket :: ClientSocket -> IO (Either SocketError ())
closeClientSocket (ClientSocket fd) = closeFd fd

sendLoop :: Int -> CString -> Int -> IO (Either SocketError ())
sendLoop _ _ remaining | remaining <= 0 = return (Right ())
sendLoop fd ptr remaining = do
    sent <- c_send fd ptr remaining 0
    if sent < 0
        then do
            errno <- getErrno
            if isWouldBlock errno
                then do
                    threadDelay pollDelayMicros
                    sendLoop fd ptr remaining
                else return (Left (SocketError "send" errno))
        else sendLoop fd (advanceCString ptr sent) (remaining - sent)

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
    alloca $ \opt -> do
        poke opt (1 :: Int)
        result <-
            checked
                "setsockopt"
                (c_setsockopt fd solSocket soReuseAddr opt (sizeOf (1 :: Int)))
        case result of
            Left err -> return (Left err)
            Right _ -> return (Right ())

setNonBlocking :: Int -> IO (Either SocketError ())
setNonBlocking fd = do
    result <- checked "fcntl" (c_fcntl fd fSetFl oNonBlock)
    case result of
        Left err -> return (Left err)
        Right _ -> return (Right ())

isWouldBlock :: Errno -> Bool
isWouldBlock errno =
    errno == eAGAIN || errno == eWOULDBLOCK

pollDelayMicros :: Int
pollDelayMicros = 1000

closeAndReturn :: Int -> SocketError -> IO (Either SocketError ListenSocket)
closeAndReturn fd err = do
    _ <- c_close fd
    return (Left err)

checked :: String -> IO Int -> IO (Either SocketError Int)
checked label action = do
    result <- action
    if result < 0
        then do
            Left . SocketError label <$> getErrno
        else
            return (Right result)

{- | Encodes an IPv4 socket address as the sixteen sockaddr_in bytes.
The layout is the BSD form with a length byte at offset zero, which is
correct on macOS; other platforms need their own layout behind this seam.
-}
encodeSockAddrIn :: Host -> Port -> [Word8]
encodeSockAddrIn host (Port port) =
    [ fromIntegral sockaddrInSize
    , fromIntegral afInet
    , fromIntegral (port `quot` 256)
    , fromIntegral (port `rem` 256)
    ]
        ++ hostBytes host
        ++ replicate 8 0

hostBytes :: Host -> [Word8]
hostBytes HostAny = [0, 0, 0, 0]
hostBytes (HostIPv4 a b c d) = [a, b, c, d]

withSockAddrIn :: Host -> Port -> (Ptr () -> Int -> IO a) -> IO a
withSockAddrIn host port use =
    allocaBytes sockaddrInSize $ \ptr -> do
        pokeBytes ptr (encodeSockAddrIn host port)
        use (castPtr ptr) sockaddrInSize

pokeBytes :: Ptr Word8 -> [Word8] -> IO ()
pokeBytes ptr = go 0
  where
    go _ [] = return ()
    go index (byte : rest) = do
        pokeByteOff ptr index byte
        go (index + 1) rest

sockaddrInSize :: Int
sockaddrInSize = 16
