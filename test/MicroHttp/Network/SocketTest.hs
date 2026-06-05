module Main(main) where

import MicroHttp.Network.Socket

main :: IO ()
main = do
  opened <- listenTcp HostAny (Port 0) 1
  case opened of
    Left err ->
      error ("given port zero, when listening, then listen succeeds: " ++ show err)
    Right socket -> do
      closed <- closeListenSocket socket
      assertEqual
        "given open listen socket, when closing, then close succeeds"
        (Right ())
        closed

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual then
    return ()
  else
    error (name ++ ": expected " ++ show expected ++ ", got " ++ show actual)
