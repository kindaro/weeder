
module Dir.Reuse(reused) where

import Dir.Reexport
import Dir.TypesOnly
import Foo.Used()

reused = (0 :: Word8) `seq` Ctor1 1 1
