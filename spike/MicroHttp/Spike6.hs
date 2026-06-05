module MicroHttp.Spike6(main) where

import Control.Concurrent.STM
import MicroHttp.Store
import System.Directory

main :: IO ()
main = do
  root <- spikeRoot
  resetRoot root
  env <- newEnv root
  _ <- startWriter env
  putDocument env "alpha" "first"
  putDocument env "beta" "second"
  putDocument env "alpha" "updated"
  deleteDocument env "beta"
  stopWriter env
  state <- readTVarIO (appState env)
  assertEqual "memory state" [("alpha", "updated")] state
  reloaded <- loadState root
  assertEqual "reloaded state" [("alpha", "updated")] reloaded
  putStrLn "spike 6 filesystem store checks passed"

spikeRoot :: IO FilePath
spikeRoot = do
  tmp <- getTemporaryDirectory
  return (tmp ++ "/micro-http-spike6-store")

resetRoot :: FilePath -> IO ()
resetRoot root = do
  createDirectoryIfMissing True root
  names <- listDirectory root
  mapM_ (\ name -> removeFile (root ++ "/" ++ name)) names

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  if expected == actual then
    return ()
  else
    error (label ++ " expected " ++ show expected ++ " but got " ++ show actual)
