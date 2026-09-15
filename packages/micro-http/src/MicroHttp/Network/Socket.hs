module MicroHttp.Network.Socket (
    ClientSocket,
    ConnectionInfo (..),
    FileFd,
    Host (..),
    ListenSocket,
    Port (..),
    SocketError (..),
    accept,
    boundPort,
    closeClientSocket,
    closeClientSocketGraceful,
    closeFileFd,
    closeListenSocket,
    connectTcp,
    encodeSockAddrIn,
    fileSize,
    fileSizeBytes,
    isTimeoutError,
    listenTcp,
    openFileRead,
    probeListener,
    recv,
    recvWithin,
    sendAll,
    sendAllWithin,
    sendFileWithin,
) where

import qualified Control.Monad as Monad
import qualified Control.Monad.Except as Except
import qualified Control.Monad.IO.Class as Class
import qualified Data.ByteString as BS
import qualified Data.Word as Word
import qualified Foreign.C.Error as Error
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable
import qualified System.IO.FD as FD
import qualified System.Timeout as Timeout

-- Every import spells its C types with Foreign.C.Types (ADR-0087 follow-up, network-design
-- "GHC Compatibility Direction"): a C `int` result read as a 64-bit Int has an unspecified
-- upper half under GHC, and a `socklen_t` is 32 bits, so a `Ptr Int` for it reads eight
-- bytes through a four-byte object. `ssize_t`, `off_t` and `time_t` are `long` on the
-- LP64 platforms this targets, spelt CLong. Descriptors stay Int on the Haskell side and
-- convert at the call.
foreign import ccall "socket" c_socket :: CTypes.CInt -> CTypes.CInt -> CTypes.CInt -> IO CTypes.CInt
foreign import ccall "setsockopt" c_setsockopt :: CTypes.CInt -> CTypes.CInt -> CTypes.CInt -> Ptr.Ptr CTypes.CInt -> CTypes.CUInt -> IO CTypes.CInt
foreign import ccall "getsockopt" c_getsockopt :: CTypes.CInt -> CTypes.CInt -> CTypes.CInt -> Ptr.Ptr CTypes.CInt -> Ptr.Ptr CTypes.CUInt -> IO CTypes.CInt

-- fcntl(2) is variadic and must not be imported at a fixed arity: on arm64
-- macOS the variadic argument travels on the stack, so a three-Int ccall put
-- O_NONBLOCK where fcntl never looked and the socket silently stayed blocking
-- under GHC (the coverage builds). The cbits wrapper makes the call from real C.
foreign import ccall "microhttp_fs.h mhfs_set_nonblock" c_setNonBlock :: CTypes.CLong -> IO CTypes.CLong
foreign import ccall "bind" c_bind :: CTypes.CInt -> Ptr.Ptr () -> CTypes.CUInt -> IO CTypes.CInt
foreign import ccall "connect" c_connect :: CTypes.CInt -> Ptr.Ptr () -> CTypes.CUInt -> IO CTypes.CInt
foreign import ccall "listen" c_listen :: CTypes.CInt -> CTypes.CInt -> IO CTypes.CInt
foreign import ccall "accept" c_accept :: CTypes.CInt -> Ptr.Ptr () -> Ptr.Ptr CTypes.CUInt -> IO CTypes.CInt
foreign import ccall "getsockname" c_getsockname :: CTypes.CInt -> Ptr.Ptr () -> Ptr.Ptr CTypes.CUInt -> IO CTypes.CInt
foreign import ccall "recv" c_recv :: CTypes.CInt -> CStr.CString -> CTypes.CSize -> CTypes.CInt -> IO CTypes.CLong
foreign import ccall "send" c_send :: CTypes.CInt -> CStr.CString -> CTypes.CSize -> CTypes.CInt -> IO CTypes.CLong
foreign import ccall "close" c_close :: CTypes.CInt -> IO CTypes.CInt

-- open(2) is variadic, so it goes through the fixed-arity wrapper (see microhttp_fs.h).
foreign import ccall "microhttp_fs.h mhfs_open_read" c_openRead :: CStr.CString -> IO CTypes.CLong
foreign import ccall "unistd.h lseek" c_lseek :: CTypes.CInt -> CTypes.CLong -> CTypes.CInt -> IO CTypes.CLong

-- macOS sendfile: sendfile(int fd, int s, off_t offset, off_t *len,
-- struct sf_hdtr *hdtr, int flags). The in/out len holds bytes sent on both
-- success and EAGAIN; hdtr is passed NULL (the head goes via the chunk path).
foreign import ccall "sys/socket.h sendfile"
    c_sendfile :: CTypes.CInt -> CTypes.CInt -> CTypes.CLong -> Ptr.Ptr CTypes.CLong -> Ptr.Ptr () -> CTypes.CInt -> IO CTypes.CInt

-- The constants stay Int: MicroHs evaluates a `capi value` import typed as a
-- Foreign.C.Types newtype to an unevaluated application ("evalint, bad tag AP" at the
-- call), so they are converted at each use instead.
foreign import capi "sys/socket.h value AF_INET" afInet :: Int
foreign import capi "sys/socket.h value SOCK_STREAM" sockStream :: Int
foreign import capi "sys/socket.h value SOL_SOCKET" solSocket :: Int
foreign import capi "sys/socket.h value SO_REUSEADDR" soReuseAddr :: Int
foreign import capi "sys/socket.h value SO_ERROR" soError :: Int
foreign import capi "unistd.h value SEEK_END" seekEnd :: Int

-- | A descriptor, flag or constant as a C @int@.
cfd :: Int -> CTypes.CInt
cfd = fromIntegral

newtype ListenSocket = ListenSocket Int
    deriving (Eq, Show)

newtype ClientSocket = ClientSocket Int
    deriving (Eq, Show)

-- | An open, read-only file descriptor for zero-copy sending (RFC-0014).
newtype FileFd = FileFd Int
    deriving (Eq, Show)

data Host
    = HostAny
    | HostIPv4 Word.Word8 Word.Word8 Word.Word8 Word.Word8
    deriving (Eq, Show)

newtype Port = Port Int
    deriving (Eq, Show)

{- | Non-payload metadata about an accepted connection: the peer's address.
Captured at accept from the @sockaddr@ that @accept@ fills, so it needs no
@getpeername@ call. Extensible (local address, accept time, TLS) later.
-}
data ConnectionInfo = ConnectionInfo
    { connPeerHost :: Host
    , connPeerPort :: Port
    }
    deriving (Eq, Show)

data SocketError = SocketError String Error.Errno
    deriving (Eq)

instance Show SocketError where
    show (SocketError operation errno) = "SocketError " ++ show operation ++ " " ++ renderErrno errno

{- | Names the errnos a caller can act on, falling back to the number.

The errno used to be dropped here, which made every failed bind report the bare word
"bind": address-in-use, permission denied and a bad address all read the same, though the
thing to do about each is different. Named rather than passed to 'show' because GHC (the
coverage builds) has no 'Show' instance for 'Error.Errno' -- only MicroHs does, and it
prints the number.
-}
renderErrno :: Error.Errno -> String
renderErrno errno
    | errno == Error.eADDRINUSE = "EADDRINUSE"
    | errno == Error.eADDRNOTAVAIL = "EADDRNOTAVAIL"
    | errno == Error.eACCES = "EACCES"
    | errno == Error.eCONNREFUSED = "ECONNREFUSED"
    | errno == Error.eCONNRESET = "ECONNRESET"
    | errno == Error.ePIPE = "EPIPE"
    | errno == Error.eTIMEDOUT = "ETIMEDOUT"
    | errno == Error.eAGAIN = "EAGAIN"
    | errno == Error.eINPROGRESS = "EINPROGRESS"
    | errno == Error.eISCONN = "EISCONN"
    | errno == Error.eNOTCONN = "ENOTCONN"
    | errno == Error.eINTR = "EINTR"
    | errno == Error.eBADF = "EBADF"
    | errno == Error.eMFILE = "EMFILE"
    | errno == Error.eNFILE = "ENFILE"
    | otherwise = case errno of Error.Errno number -> "errno " ++ show number

{- | Creates a listening TCP socket bound to a host and port with the given
backlog, set non-blocking, closing the descriptor on any mid-setup failure.
-}
listenTcp :: Host -> Port -> Int -> IO (Either SocketError ListenSocket)
listenTcp host port backlog =
    Except.runExceptT $ do
        fd <- Except.ExceptT (checked "socket" (c_socket (cfd afInet) (cfd sockStream) 0))
        closingOnError fd $ do
            Except.ExceptT (setReuseAddr fd)
            Except.ExceptT (withSockAddrIn host port (\addr addrLen -> checked "bind" (c_bind (cfd fd) addr addrLen)))
            Except.ExceptT (checked "listen" (c_listen (cfd fd) (fromIntegral backlog)))
            Except.ExceptT (setNonBlocking fd)
            pure (ListenSocket fd)

{- | Accepts a pending connection on a listening socket, returning the
non-blocking client socket and its peer 'ConnectionInfo'; parks on read
readiness while no connection is queued.
-}
accept :: ListenSocket -> IO (Either SocketError (ClientSocket, ConnectionInfo))
accept (ListenSocket fd) =
    Alloc.allocaBytes sockaddrInSize $ \addr ->
        Alloc.alloca $ \addrLen ->
            Except.runExceptT $ do
                accepted <- Except.ExceptT (acceptLoop addr addrLen)
                closingOnError accepted $ do
                    Except.ExceptT (setNonBlocking accepted)
                    peer <- Class.liftIO (peekConnectionInfo (Ptr.castPtr addr))
                    pure (ClientSocket accepted, peer)
  where
    acceptLoop addr addrLen = do
        Storable.poke addrLen sockaddrInLen
        accepted <- fmap fromIntegral (c_accept (cfd fd) (Ptr.castPtr addr) addrLen)
        if accepted < 0
            then do
                errno <- Error.getErrno
                if isWouldBlock errno
                    then do
                        FD.waitForReadFD fd
                        acceptLoop addr addrLen
                    else return (Left (SocketError "accept" errno))
            else return (Right accepted)

{- | Connects a non-blocking TCP client socket to a host and port.
The socket is non-blocking before connecting, so connection progress is
polled: in-progress results retry until the socket reports connected.
-}
connectTcp :: Host -> Port -> IO (Either SocketError ClientSocket)
connectTcp host port =
    Except.runExceptT $ do
        fd <- Except.ExceptT (checked "socket" (c_socket (cfd afInet) (cfd sockStream) 0))
        closingOnError fd $ do
            Except.ExceptT (setNonBlocking fd)
            Except.ExceptT (withSockAddrIn host port (connectLoop fd))

{- | Whether something is already accepting connections at this address and port.

This exists because a port clash is not always a bind failure. 'listenTcp' sets
@SO_REUSEADDR@, and on BSD/macOS that lets a wildcard bind succeed while another process
holds the same port on a specific address such as 127.0.0.1 -- and then loopback traffic
goes to that process, because the more specific bind wins. @bind@ reports success, so the
only way to see the clash is to ask the port whether anyone answers before binding it.

Probe loopback. A refused connection there is reported at once or, since macOS 27,
after the non-blocking connect has parked on write readiness and @SO_ERROR@ has been
read; a filtered address elsewhere would leave the connect parked.
-}
probeListener :: Host -> Port -> IO Bool
probeListener host port = do
    attempt <- connectTcp host port
    case attempt of
        Left _ -> return False
        Right client -> do
            _ <- closeClientSocket client
            return True

{- | Drives the non-blocking connect: a pending connect parks on write readiness
and then reads the outcome from @SO_ERROR@, which is the only place a
refusal lands once the connect has gone asynchronous. Retrying @connect@
instead, as this once did, reported success on macOS 27, where a loopback
connect to a closed port returns @EINPROGRESS@ rather than @ECONNREFUSED@.
-}
connectLoop :: Int -> Ptr.Ptr () -> CTypes.CUInt -> IO (Either SocketError ClientSocket)
connectLoop fd addr addrLen = do
    connected <- c_connect (cfd fd) addr addrLen
    if connected >= 0
        then return (Right (ClientSocket fd))
        else do
            errno <- Error.getErrno
            if errno == Error.eISCONN
                then return (Right (ClientSocket fd))
                else
                    if isConnectPending errno
                        then do
                            FD.waitForWriteFD fd
                            pendingOutcome fd
                        else return (Left (SocketError "connect" errno))

-- | The outcome of a connect that went asynchronous: @SO_ERROR@ once the socket is writable.
pendingOutcome :: Int -> IO (Either SocketError ClientSocket)
pendingOutcome fd =
    Alloc.alloca $ \errPtr ->
        Alloc.alloca $ \lenPtr -> do
            Storable.poke errPtr (0 :: CTypes.CInt)
            Storable.poke lenPtr (fromIntegral (Storable.sizeOf (0 :: CTypes.CInt)) :: CTypes.CUInt)
            asked <- c_getsockopt (cfd fd) (cfd solSocket) (cfd soError) errPtr lenPtr
            if asked < 0
                then Left . SocketError "getsockopt" <$> Error.getErrno
                else do
                    err <- Storable.peek errPtr
                    pure $
                        if err == 0
                            then Right (ClientSocket fd)
                            else Left (SocketError "connect" (Error.Errno err))

-- | Whether a connect errno means the connection is still in progress.
isConnectPending :: Error.Errno -> Bool
isConnectPending errno =
    errno == Error.eINPROGRESS || errno == Error.eALREADY || isWouldBlock errno

-- | Returns the locally bound port of a listening socket.
boundPort :: ListenSocket -> IO (Either SocketError Port)
boundPort (ListenSocket fd) =
    Alloc.allocaBytes sockaddrInSize $ \addr ->
        Alloc.alloca $ \addrLen ->
            Except.runExceptT $ do
                Class.liftIO (Storable.poke addrLen sockaddrInLen)
                Except.ExceptT (checked "getsockname" (c_getsockname (cfd fd) (Ptr.castPtr addr) addrLen))
                high <- Class.liftIO (peekWord8 addr 2)
                low <- Class.liftIO (peekWord8 addr 3)
                pure (Port (fromIntegral high * 256 + fromIntegral low))

-- | Reads a single byte from a @sockaddr@ buffer at the given offset.
peekWord8 :: Ptr.Ptr Word.Word8 -> Int -> IO Word.Word8
peekWord8 = Storable.peekByteOff

{- | Decodes the peer address from a filled @sockaddr_in@ buffer, using the
same BSD byte layout as 'encodeSockAddrIn': the port at offsets 2-3 and the
IPv4 address at offsets 4-7.
-}
peekConnectionInfo :: Ptr.Ptr Word.Word8 -> IO ConnectionInfo
peekConnectionInfo addr = do
    portHigh <- peekWord8 addr 2
    portLow <- peekWord8 addr 3
    a <- peekWord8 addr 4
    b <- peekWord8 addr 5
    c <- peekWord8 addr 6
    d <- peekWord8 addr 7
    return
        ConnectionInfo
            { connPeerHost = HostIPv4 a b c d
            , connPeerPort = Port (fromIntegral portHigh * 256 + fromIntegral portLow)
            }

{- | Receives up to @byteCount@ bytes from a client socket, waiting indefinitely
for read readiness (the unbounded form of 'recvWithin').
-}
recv :: ClientSocket -> Int -> IO (Either SocketError BS.ByteString)
recv = recvWithin 0

{- | Like 'recv', but the wait for read readiness is bounded by the idle
timeout in microseconds: a non-positive timeout waits indefinitely (the
RFC-0005 behaviour), and a positive one fails with a timeout 'SocketError'
('isTimeoutError') if no data arrives in that window. The timer is armed only
when a read would block, so a read with data ready returns immediately with
no timer.
-}
recvWithin :: Int -> ClientSocket -> Int -> IO (Either SocketError BS.ByteString)
recvWithin idleMicros (ClientSocket fd) byteCount =
    Alloc.allocaBytes byteCount recvLoop
  where
    recvLoop buf = do
        received <- fmap fromIntegral (c_recv (cfd fd) (Ptr.castPtr buf) (fromIntegral byteCount) 0)
        if received < 0
            then do
                errno <- Error.getErrno
                if isWouldBlock errno
                    then do
                        ready <- waitReadable idleMicros fd
                        case ready of
                            Left err -> return (Left err)
                            Right () -> recvLoop buf
                    else return (Left (SocketError "recv" errno))
            else do
                bytes <- BS.packCStringLen (Ptr.castPtr buf, received)
                return (Right bytes)

{- | Waits for a descriptor to become readable, bounded by the idle timeout
if it is positive. A reached deadline is reported as a timeout 'SocketError'.
-}
waitReadable :: Int -> Int -> IO (Either SocketError ())
waitReadable idleMicros fd
    | idleMicros <= 0 = do
        FD.waitForReadFD fd
        return (Right ())
    | otherwise = do
        woken <- Timeout.timeout idleMicros (FD.waitForReadFD fd)
        case woken of
            Just () -> return (Right ())
            Nothing -> return (Left (SocketError "recv" Error.eTIMEDOUT))

-- | Whether a socket error is an idle-timeout failure (read or write).
isTimeoutError :: SocketError -> Bool
isTimeoutError (SocketError _ errno) = errno == Error.eTIMEDOUT

{- | Sends an entire byte string on a client socket, waiting indefinitely for
write readiness (the unbounded form of 'sendAllWithin').
-}
sendAll :: ClientSocket -> BS.ByteString -> IO (Either SocketError ())
sendAll = sendAllWithin 0

{- | Like 'sendAll', but the wait for write readiness on a would-block send is
bounded by the idle timeout in microseconds: a non-positive timeout waits
indefinitely (the RFC-0005 behaviour), and a positive one fails with a timeout
'SocketError' ('isTimeoutError') if the peer does not drain the send buffer in
that window. The timer is armed only when a send would block, so a send with
buffer space returns immediately with no timer.
-}
sendAllWithin :: Int -> ClientSocket -> BS.ByteString -> IO (Either SocketError ())
sendAllWithin idleMicros (ClientSocket fd) bytes =
    BS.useAsCStringLen bytes (uncurry (sendLoop idleMicros fd))

-- | Opens a file read-only for zero-copy sending; 'Nothing' if it cannot open.
openFileRead :: FilePath -> IO (Maybe FileFd)
openFileRead path = do
    fd <- fmap fromIntegral (CStr.withCString path c_openRead)
    if fd < 0
        then return Nothing
        else return (Just (FileFd fd))

-- | The file's size in bytes, via @lseek@ to the end (no @struct stat@ needed).
fileSize :: FileFd -> IO Int
fileSize (FileFd fd) = fmap fromIntegral (c_lseek (cfd fd) 0 (cfd seekEnd))

-- | Closes a file descriptor (a read-only fd close); the result is ignored.
closeFileFd :: FileFd -> IO ()
closeFileFd (FileFd fd) = Monad.void (c_close (cfd fd))

{- | The size of a file by path, opening read-only and closing again, or
'Nothing' if it cannot be opened. The single size source for a 'FileBody':
'MicroHttp.Static.serveStatic' resolves it once and carries it on the body, so
the response head's @Content-Length@ and the access log read the same number
with no further syscall.
-}
fileSizeBytes :: FilePath -> IO (Maybe Int)
fileSizeBytes path = do
    opened <- openFileRead path
    case opened of
        Nothing -> return Nothing
        Just fd -> do
            size <- fileSize fd
            closeFileFd fd
            return (Just size)

{- | Sends @len@ bytes of a file from @offset@ to the socket via @sendfile(2)@,
with no userspace copy. Mirrors 'sendAllWithin': a would-block parks on write
readiness bounded by the idle write timeout (a non-positive timeout waits
indefinitely), advancing past the bytes the kernel already sent. The macOS
@sendfile@ reports bytes sent through its in/out length argument on both success
and @EAGAIN@; a short success (kernel sent fewer than requested with no error)
stops, covering a file truncated under us.
-}
sendFileWithin :: Int -> ClientSocket -> FileFd -> Int -> Int -> IO (Either SocketError ())
sendFileWithin idleMicros (ClientSocket s) (FileFd fd) offset0 len0 =
    Alloc.alloca (sendFileLoop idleMicros s fd offset0 len0)

{- | Drives the @sendfile@ retry loop, advancing past bytes the kernel sent and
parking on write readiness on a would-block until the range is fully sent.
-}
sendFileLoop :: Int -> Int -> Int -> Int -> Int -> Ptr.Ptr CTypes.CLong -> IO (Either SocketError ())
sendFileLoop idleMicros s fd offset remaining lenPtr
    | remaining <= 0 = return (Right ())
    | otherwise = do
        Storable.poke lenPtr (fromIntegral remaining)
        rc <- c_sendfile (cfd fd) (cfd s) (fromIntegral offset) lenPtr Ptr.nullPtr 0
        sent <- fmap fromIntegral (Storable.peek lenPtr)
        let offset' = offset + sent
            remaining' = remaining - sent
        if remaining' <= 0
            then return (Right ())
            else
                if rc == 0
                    then
                        if sent <= 0
                            then return (Right ())
                            else sendFileLoop idleMicros s fd offset' remaining' lenPtr
                    else do
                        errno <- Error.getErrno
                        if isWouldBlock errno
                            then do
                                ready <- waitWritable idleMicros s
                                case ready of
                                    Left err -> return (Left err)
                                    Right () -> sendFileLoop idleMicros s fd offset' remaining' lenPtr
                            else return (Left (SocketError "sendfile" errno))

-- | Closes a listening socket, returning any close error.
closeListenSocket :: ListenSocket -> IO (Either SocketError ())
closeListenSocket (ListenSocket fd) = closeFd fd

-- | Closes a client socket immediately, returning any close error.
closeClientSocket :: ClientSocket -> IO (Either SocketError ())
closeClientSocket (ClientSocket fd) = closeFd fd

{- | Closes a client socket gracefully: it first drains any unread bytes still
in the receive buffer, then closes. The drain matters because on macOS/BSD a
@close@ with unread receive data sends a @RST@ rather than a @FIN@, and that
@RST@ can race the peer's read and discard data the peer has buffered but not yet
read -- truncating the response. Since an application may answer without
consuming the whole request (RFC-0012), the connection layer clears the receive
buffer here so the close is an orderly @FIN@ that delivers the queued response.
-}
closeClientSocketGraceful :: ClientSocket -> IO (Either SocketError ())
closeClientSocketGraceful sock@(ClientSocket fd) = do
    drainReceiveBuffer sock
    closeFd fd

{- | Reads and discards everything currently in the receive buffer without
waiting: it stops as soon as a read would block (no data ready), at end of
stream, or on error. This is a non-blocking sweep, not a wait for the peer, so
it never stalls the handler.
-}
drainReceiveBuffer :: ClientSocket -> IO ()
drainReceiveBuffer (ClientSocket fd) = Alloc.allocaBytes drainBufferBytes loop
  where
    loop buf = do
        received <- c_recv (cfd fd) (Ptr.castPtr buf) (fromIntegral drainBufferBytes) 0
        Monad.when (received > 0) (loop buf)

-- | The fixed buffer size used by the receive-buffer drain sweep.
drainBufferBytes :: Int
drainBufferBytes = 4096

{- | Drives the non-blocking send loop, advancing the pointer past sent bytes
and parking on write readiness on a would-block until all bytes are sent.
-}
sendLoop :: Int -> Int -> CStr.CString -> Int -> IO (Either SocketError ())
sendLoop _ _ _ remaining | remaining <= 0 = return (Right ())
sendLoop idleMicros fd ptr remaining = do
    sent <- fmap fromIntegral (c_send (cfd fd) ptr (fromIntegral remaining) 0)
    if sent < 0
        then do
            errno <- Error.getErrno
            if isWouldBlock errno
                then do
                    ready <- waitWritable idleMicros fd
                    case ready of
                        Left err -> return (Left err)
                        Right () -> sendLoop idleMicros fd ptr remaining
                else return (Left (SocketError "send" errno))
        else sendLoop idleMicros fd (advanceCString ptr sent) (remaining - sent)

{- | Waits for a descriptor to become writable, bounded by the idle timeout
if it is positive. A reached deadline is reported as a timeout 'SocketError'.
-}
waitWritable :: Int -> Int -> IO (Either SocketError ())
waitWritable idleMicros fd
    | idleMicros <= 0 = do
        FD.waitForWriteFD fd
        return (Right ())
    | otherwise = do
        woken <- Timeout.timeout idleMicros (FD.waitForWriteFD fd)
        case woken of
            Just () -> return (Right ())
            Nothing -> return (Left (SocketError "send" Error.eTIMEDOUT))

-- | Advances a 'CStr.CString' pointer by a byte count.
advanceCString :: CStr.CString -> Int -> CStr.CString
advanceCString ptr count = Ptr.castPtr (Ptr.castPtr ptr `Ptr.plusPtr` count)

-- | Closes a raw descriptor, discarding the success value, reporting any error.
closeFd :: Int -> IO (Either SocketError ())
closeFd fd = Monad.void <$> checked "close" (c_close (cfd fd))

-- | Enables @SO_REUSEADDR@ on a socket, returning any setsockopt error.
setReuseAddr :: Int -> IO (Either SocketError ())
setReuseAddr fd =
    Alloc.alloca $ \opt -> do
        Storable.poke opt (1 :: CTypes.CInt)
        Monad.void <$> checked "setsockopt" (c_setsockopt (cfd fd) (cfd solSocket) (cfd soReuseAddr) opt (fromIntegral (Storable.sizeOf (1 :: CTypes.CInt))))

{- | Sets a socket to non-blocking mode (adding @O_NONBLOCK@ to its flags),
returning any error. The whole layer depends on this: reads and writes probe
first and wait on would-block, so a socket left blocking parks its thread in
the kernel instead of in the scheduler, and the idle timeouts never arm.
-}
setNonBlocking :: Int -> IO (Either SocketError ())
setNonBlocking fd = do
    rc <- c_setNonBlock (fromIntegral fd)
    pure
        ( if rc == 0
            then Right ()
            else Left (SocketError "fcntl" (Error.Errno (fromIntegral rc)))
        )

-- | Whether an errno means the operation would block on a non-blocking socket.
isWouldBlock :: Error.Errno -> Bool
isWouldBlock errno =
    errno == Error.eAGAIN || errno == Error.eWOULDBLOCK

{- | Runs an acquire step that already owns @fd@; if it fails, closes @fd@
before propagating the error, so a mid-acquisition failure never leaks the
descriptor.
-}
closingOnError :: Int -> Except.ExceptT SocketError IO a -> Except.ExceptT SocketError IO a
closingOnError fd action =
    action `Except.catchError` \err -> do
        _ <- Class.liftIO (c_close (cfd fd))
        Except.throwError err

{- | Runs a syscall returning a C @int@, mapping a negative result to a
'SocketError' tagged with the given label and the current errno.
-}
checked :: String -> IO CTypes.CInt -> IO (Either SocketError Int)
checked label action = do
    result <- fmap fromIntegral action
    if result < 0
        then do
            Left . SocketError label <$> Error.getErrno
        else
            return (Right result)

{- | Encodes an IPv4 socket address as the sixteen sockaddr_in bytes.
The layout is the BSD form with a length byte at offset zero, which is
correct on macOS; other platforms need their own layout behind this seam.
-}
encodeSockAddrIn :: Host -> Port -> [Word.Word8]
encodeSockAddrIn host (Port port) =
    [ fromIntegral sockaddrInSize
    , fromIntegral afInet
    , fromIntegral (port `quot` 256)
    , fromIntegral (port `rem` 256)
    ]
        ++ hostBytes host
        ++ replicate 8 0

-- | The four address bytes for a host: all-zero for 'HostAny', else the octets.
hostBytes :: Host -> [Word.Word8]
hostBytes HostAny = [0, 0, 0, 0]
hostBytes (HostIPv4 a b c d) = [a, b, c, d]

{- | Builds a @sockaddr_in@ in a temporary buffer and passes it (with its size)
to the continuation.
-}
withSockAddrIn :: Host -> Port -> (Ptr.Ptr () -> CTypes.CUInt -> IO a) -> IO a
withSockAddrIn host port use =
    Alloc.allocaBytes sockaddrInSize $ \ptr -> do
        pokeBytes ptr (encodeSockAddrIn host port)
        use (Ptr.castPtr ptr) sockaddrInLen

-- | Writes a list of bytes into a buffer at successive offsets from zero.
pokeBytes :: Ptr.Ptr Word.Word8 -> [Word.Word8] -> IO ()
pokeBytes ptr = go 0
  where
    go _ [] = return ()
    go index (byte : rest) = do
        Storable.pokeByteOff ptr index byte
        go (index + 1) rest

-- | The size in bytes of a @sockaddr_in@ structure.
sockaddrInSize :: Int
sockaddrInSize = 16

-- | The same size as the @socklen_t@ the socket calls take and fill in.
sockaddrInLen :: CTypes.CUInt
sockaddrInLen = fromIntegral sockaddrInSize
