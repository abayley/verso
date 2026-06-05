module MicroHttp.Store
  ( Env(..)
  , WriteJob(..)
  , newEnv
  , loadState
  , startWriter
  , putDocument
  , deleteDocument
  , stopWriter
  ) where

import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Foreign.C.String
import System.Directory

data Env = Env
  { storeRoot :: FilePath
  , appState :: TVar [(String, String)]
  , writeQ :: TQueue WriteJob
  }

data WriteJob
  = PutDocument String String
  | DeleteDocument String
  | StopWriter (MVar ())

foreign import ccall "rename" c_rename :: CString -> CString -> IO Int

newEnv :: FilePath -> IO Env
newEnv root = do
  createDirectoryIfMissing True root
  state <- loadState root
  stateVar <- newTVarIO state
  queue <- newTQueueIO
  return Env
    { storeRoot = root
    , appState = stateVar
    , writeQ = queue
    }

loadState :: FilePath -> IO [(String, String)]
loadState root = do
  exists <- doesDirectoryExist root
  if not exists then
    return []
  else do
    names <- listDirectory root
    loadFiles root (filter isDocumentFile names)

startWriter :: Env -> IO ThreadId
startWriter env = forkIO (writerLoop env)

putDocument :: Env -> String -> String -> IO ()
putDocument env key content =
  atomically (writeTQueue (writeQ env) (PutDocument key content))

deleteDocument :: Env -> String -> IO ()
deleteDocument env key =
  atomically (writeTQueue (writeQ env) (DeleteDocument key))

stopWriter :: Env -> IO ()
stopWriter env = do
  done <- newEmptyMVar
  atomically (writeTQueue (writeQ env) (StopWriter done))
  takeMVar done

writerLoop :: Env -> IO ()
writerLoop env = do
  job <- atomically (readTQueue (writeQ env))
  case job of
    PutDocument key content -> do
      atomicWriteFile (documentPath env key) content
      atomically (modifyTVar' (appState env) (upsert key content))
      writerLoop env
    DeleteDocument key -> do
      removeIfExists (documentPath env key)
      atomically (modifyTVar' (appState env) (filter ((/= key) . fst)))
      writerLoop env
    StopWriter done ->
      putMVar done ()

loadFiles :: FilePath -> [String] -> IO [(String, String)]
loadFiles _ [] = return []
loadFiles root (name:names) = do
  content <- readFile (root ++ "/" ++ name)
  rest <- loadFiles root names
  return ((dropExtension name, content) : rest)

atomicWriteFile :: FilePath -> String -> IO ()
atomicWriteFile path content = do
  let tmp = path ++ ".tmp"
  writeFile tmp content
  renameFileFfi tmp path

renameFileFfi :: FilePath -> FilePath -> IO ()
renameFileFfi from to =
  withCAString from $ \ cfrom ->
    withCAString to $ \ cto -> do
      result <- c_rename cfrom cto
      if result == 0 then
        return ()
      else
        error ("rename failed from " ++ from ++ " to " ++ to)

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  exists <- doesFileExist path
  if exists then removeFile path else return ()

documentPath :: Env -> String -> FilePath
documentPath env key = storeRoot env ++ "/" ++ key ++ ".txt"

isDocumentFile :: String -> Bool
isDocumentFile name = ".txt" `isSuffixOfLocal` name && not (".tmp" `isSuffixOfLocal` name)

dropExtension :: String -> String
dropExtension name = reverse (drop 4 (reverse name))

upsert :: String -> String -> [(String, String)] -> [(String, String)]
upsert key content [] = [(key, content)]
upsert key content ((existingKey, _):rest)
  | key == existingKey = (key, content) : rest
upsert key content (entry:rest) = entry : upsert key content rest

isSuffixOfLocal :: String -> String -> Bool
isSuffixOfLocal suffix text = reverse suffix `isPrefixOfLocal` reverse text

isPrefixOfLocal :: String -> String -> Bool
isPrefixOfLocal [] _ = True
isPrefixOfLocal _ [] = False
isPrefixOfLocal (x:xs) (y:ys) = x == y && isPrefixOfLocal xs ys
