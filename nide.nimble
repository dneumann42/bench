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
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release --hints:off --nimcache:build/nimcache-release tests/test_keybindings.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release -d:nideNoMain --hints:off --nimcache:build/nimcache-release tests/test_keymap_frame.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --hints:off --nimcache:build/nimcache tests/test_viewers.nim"
  exec "nim c -r -d:release --hints:off --nimcache:build/nimcache-release tests/test_file_tree.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release -d:nideNoMain --hints:off " &
    "--nimcache:build/nimcache-release tests/test_scroll_settle.nim"

task bench, "Run the Nide benchmarks":
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release -d:nideNoMain --hints:off " &
    "--nimcache:build/nimcache-bench tests/bench_palette.nim"
  exec "nim c -r -d:release --hints:off --nimcache:build/nimcache-bench tests/bench_file_tree.nim"

requires "https://github.com/dneumann42/nest#head"
requires "https://github.com/dneumann42/owl#head"
requires "https://github.com/nim-lang/sdl3#e5f87eb992f828419aad83075ea1c41147fbb088"
