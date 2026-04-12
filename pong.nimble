# Package

version       = "0.1.0"
author        = "bk20x"
description   = "Little multiplayer ping pong in nim (My first multiplayer game)"
license       = "MIT"
srcDir        = "src"
bin           = @["pong"]


# Dependencies

requires "nim    >= 2.3.1"
requires "naylib >= 26.08.0"
requires "https://github.com/planetis-m/naygui >= 25.25.0"
requires "threading >= 0.2.1"
