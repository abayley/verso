module MicroHttp.Response(serialiseResponse) where

import MicroHttp.Http

serialiseResponse :: Response -> String
serialiseResponse response =
  statusLine response ++
  concatMap headerLine allHeaders ++
  "\r\n" ++
  responseBody response
  where
    allHeaders =
      responseHeaders response ++
      [ ("Content-Length", show (length (responseBody response)))
      , ("Connection", "close")
      ]

statusLine :: Response -> String
statusLine response =
  "HTTP/1.1 " ++ show (responseStatus response) ++ " " ++ responseStatusText response ++ "\r\n"

headerLine :: (String, String) -> String
headerLine (name, value) = name ++ ": " ++ value ++ "\r\n"
