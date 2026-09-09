module Main (main) where

import MicroSpike (spikeAdd)

main :: IO ()
main = putStrLn ("spikeAdd 2 3 = " ++ show (spikeAdd 2 3))
