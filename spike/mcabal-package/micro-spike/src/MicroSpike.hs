module MicroSpike (spikeAdd) where

foreign import ccall "hello.h spike_add" c_spike_add :: Int -> Int -> Int

spikeAdd :: Int -> Int -> Int
spikeAdd = c_spike_add
