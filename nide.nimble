# Package

version       = "0.0.0"
author        = "dneumann"
description   = "A nim editor by Dustin Neumann"
license       = "MIT"
srcDir        = "src"
bin           = @["nide"]


# Dependencies

requires "nim >= 2.2.10"

task test, "Run the Nide test suite":
  exec "nim c -r --hints:off --nimcache:build/nimcache tests/test_commands.nim"
  exec "nim c -r --hints:off --nimcache:build/nimcache tests/test_owl_scripts.nim"
  # Built with -d:release: the Owl interpreter nests several Nim frames per
  # call, so a debug build's 2000-call ceiling trips long before these scripts
  # have done anything unreasonable.
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release --hints:off --nimcache:build/nimcache-release tests/test_keybindings.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release -d:nideNoMain --hints:off --nimcache:build/nimcache-release tests/test_keymap_frame.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --hints:off --nimcache:build/nimcache tests/test_viewers.nim"

