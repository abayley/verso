-- Spike 10: minimal MicroHs runtime concurrency hang reproducer.
--
-- Self-contained: compiles with plain mhs and no project sources. A
-- receiver green thread polls recv on a non-blocking loopback TCP socket
-- (EAGAIN, threadDelay 1000, retry) while the main thread lazily
-- constructs a 512 KiB ByteString and sends it under useAsCStringLen,
-- also polling EAGAIN. Expected: ten transfer iterations complete.
-- Observed with mhs 0.16.0.0 on macOS arm64: the program usually hangs,
-- sleeping at about one percent CPU with empty kernel socket queues.
--
-- Bisection matrix (three runs each unless noted):
--   raw pointers both sides ................................ passes
--   plus pure list allocation pressure per chunk ........... passes
--   packCStringLen per recv, raw sender .................... passes
--   payload forced BEFORE forkIO, useAsCStringLen sends .... passes
--   brief useAsCStringLen (memcpy out), raw sends .......... passes
--   recv-polling thread plus concurrent construction,
--     no sends ............................................. passes
--   forkIO plus threadDelay poller plus construction,
--     no sockets ........................................... passes
--   THIS FILE: payload forced lazily after forkIO and sent
--     under useAsCStringLen while the receiver polls ........ hangs
--
-- The trigger appears conjunctive: lazy construction of a large
-- ByteString after the polling thread exists, plus sending from the
-- ByteString's interior pointer while both threads poll EAGAIN with
-- threadDelay. Note that mhs appears to block-buffer redirected stdout
-- regardless of hSetBuffering, so a killed hung run shows no output.
--
-- Compile and run:
--   mhs spike/MicroHttp/Spike10.hs -ispike -o build/spike10 && build/spike10
module MicroHttp.Spike10 (main) where

import Control.Concurrent (forkIO, threadDelay)
import qualified Data.ByteString.Char8 as BS
import Control.Concurrent.MVar
import Data.Word (Word8)
import Foreign.C.Error (eAGAIN, eALREADY, eINPROGRESS, eISCONN, eWOULDBLOCK, getErrno)
import Foreign.Marshal.Alloc (alloca, allocaBytes, mallocBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (peekByteOff, poke, pokeByteOff)
import System.IO

foreign import ccall "socket" c_socket :: Int -> Int -> Int -> IO Int
foreign import ccall "fcntl" c_fcntl :: Int -> Int -> Int -> IO Int
foreign import ccall "bind" c_bind :: Int -> Ptr () -> Int -> IO Int
foreign import ccall "listen" c_listen :: Int -> Int -> IO Int
foreign import ccall "accept" c_accept :: Int -> Ptr () -> Ptr Int -> IO Int
foreign import ccall "getsockname" c_getsockname :: Int -> Ptr () -> Ptr Int -> IO Int
foreign import ccall "connect" c_connect :: Int -> Ptr () -> Int -> IO Int
foreign import ccall "recv" c_recv :: Int -> Ptr () -> Int -> Int -> IO Int
foreign import ccall "send" c_send :: Int -> Ptr () -> Int -> Int -> IO Int

foreign import capi "sys/socket.h value AF_INET" afInet :: Int
foreign import capi "sys/socket.h value SOCK_STREAM" sockStream :: Int
foreign import capi "fcntl.h value F_SETFL" fSetFl :: Int
foreign import capi "fcntl.h value O_NONBLOCK" oNonBlock :: Int

payloadBytes :: Int
payloadBytes = 524288

iterations :: Int
iterations = 10

pollMicros :: Int
pollMicros = 1000

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    listener <- c_socket afInet sockStream 0
    require "socket" listener
    require "fcntl listener" =<< setNonBlocking listener
    withSockAddr 0 0 $ \addr -> do
        require "bind" =<< c_bind listener addr 16
        require "listen" =<< c_listen listener 1
    port <- boundPort listener
    putStrLn ("listening on port " ++ show port)
    client <- connectNonBlocking port
    served <- acceptNonBlocking listener
    putStrLn "connected"
    recvBuffer <- mallocBytes 65536
    runIterations 1 client served recvBuffer

runIterations :: Int -> Int -> Int -> Ptr () -> IO ()
runIterations iteration client served recvBuffer
    | iteration > iterations = putStrLn "all iterations completed"
    | otherwise = do
        done <- newEmptyMVar
        _ <- forkIO (drain served recvBuffer 0 done)
        let payload = BS.concat (replicate 8 (BS.pack (replicate 65536 'x')))
        BS.useAsCStringLen payload (\(ptr, len) -> sendLoopBS client (castPtr ptr) len 0)
        total <- takeMVar done
        putStrLn ("iteration " ++ show iteration ++ " received " ++ show total)
        runIterations (iteration + 1) client served recvBuffer

-- The receiver green thread: recv until payloadBytes seen, polling EAGAIN.
drain :: Int -> Ptr () -> Int -> MVar Int -> IO ()
drain fd buffer total done
    | total >= payloadBytes = putMVar done total
    | otherwise = do
        received <- c_recv fd buffer 65536 0
        if received < 0
            then do
                errno <- getErrno
                if errno == eAGAIN || errno == eWOULDBLOCK
                    then do
                        threadDelay pollMicros
                        drain fd buffer total done
                    else do
                        putStrLn "recv failed"
                        putMVar done total
            else drain fd buffer (total + received) done

-- The sender on the main green thread: send until payloadBytes written,
-- polling EAGAIN.
sendLoopBS :: Int -> Ptr () -> Int -> Int -> IO ()
sendLoopBS fd buffer len sent
    | sent >= len = return ()
    | otherwise = do
        wrote <- c_send fd (buffer `plusPtr` sent) (len - sent) 0
        if wrote < 0
            then do
                errno <- getErrno
                if errno == eAGAIN || errno == eWOULDBLOCK
                    then do
                        threadDelay pollMicros
                        sendLoopBS fd buffer len sent
                    else putStrLn "send failed"
            else sendLoopBS fd buffer len (sent + wrote)

connectNonBlocking :: Int -> IO Int
connectNonBlocking port = do
    fd <- c_socket afInet sockStream 0
    require "socket client" fd
    require "fcntl client" =<< setNonBlocking fd
    withSockAddr port 127 $ \addr -> connectLoop fd addr
    return fd

connectLoop :: Int -> Ptr () -> IO ()
connectLoop fd addr = do
    connected <- c_connect fd addr 16
    if connected >= 0
        then return ()
        else do
            errno <- getErrno
            if errno == eISCONN
                then return ()
                else
                    if errno == eINPROGRESS || errno == eALREADY || errno == eAGAIN || errno == eWOULDBLOCK
                        then do
                            threadDelay pollMicros
                            connectLoop fd addr
                        else putStrLn "connect failed"

acceptNonBlocking :: Int -> IO Int
acceptNonBlocking listener =
    allocaBytes 16 $ \addr ->
        alloca $ \addrLen -> do
            poke addrLen (16 :: Int)
            acceptLoop addr addrLen
  where
    acceptLoop addr addrLen = do
        accepted <- c_accept listener (castPtr addr) addrLen
        if accepted >= 0
            then do
                require "fcntl accepted" =<< setNonBlocking accepted
                return accepted
            else do
                errno <- getErrno
                if errno == eAGAIN || errno == eWOULDBLOCK
                    then do
                        threadDelay pollMicros
                        acceptLoop addr addrLen
                    else do
                        putStrLn "accept failed"
                        return (-1)

boundPort :: Int -> IO Int
boundPort fd =
    allocaBytes 16 $ \addr ->
        alloca $ \addrLen -> do
            poke addrLen (16 :: Int)
            require "getsockname" =<< c_getsockname fd (castPtr addr) addrLen
            high <- peekW8 addr 2
            low <- peekW8 addr 3
            return (fromIntegral high * 256 + fromIntegral low)

peekW8 :: Ptr Word8 -> Int -> IO Word8
peekW8 = peekByteOff

-- sockaddr_in in the BSD/macOS layout: length byte, family byte, port
-- big-endian, then the IPv4 address. hostFirstOctet 0 binds INADDR_ANY;
-- 127 connects to 127.0.0.1.
withSockAddr :: Int -> Word8 -> (Ptr () -> IO a) -> IO a
withSockAddr port hostFirstOctet use =
    allocaBytes 16 $ \ptr -> do
        mapM_ (\index -> pokeByteOff ptr index (0 :: Word8)) [0 .. 15]
        pokeByteOff ptr 0 (16 :: Word8)
        pokeByteOff ptr 1 (fromIntegral afInet :: Word8)
        pokeByteOff ptr 2 (fromIntegral (port `quot` 256) :: Word8)
        pokeByteOff ptr 3 (fromIntegral (port `rem` 256) :: Word8)
        pokeByteOff ptr 4 hostFirstOctet
        pokeByteOff ptr 7 (if hostFirstOctet == 0 then 0 else 1 :: Word8)
        use (castPtr ptr)

setNonBlocking :: Int -> IO Int
setNonBlocking fd = c_fcntl fd fSetFl oNonBlock

require :: String -> Int -> IO ()
require label result =
    if result < 0
        then putStrLn (label ++ " failed")
        else return ()
