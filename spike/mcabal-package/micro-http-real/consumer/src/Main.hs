module Main (main) where

import qualified MicroHttp.FileSystem as FS

main :: IO ()
main = do
  result <- FS.fileStat "/etc/hosts"
  case result of
    Left err -> putStrLn ("fileStat error: " ++ show err)
    Right st -> putStrLn ("fileStat /etc/hosts OK, size=" ++ show (FS.fsSize st))
