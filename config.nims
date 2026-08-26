import std/strutils

# This checkout lives on a shared partition that is mounted at a different
# absolute path depending on which OS booted it, so nothing below may hardcode
# one. Sibling checkouts are addressed relative to this file, and nimble
# packages are looked up in the store of whichever user/OS is running.

--path:"src"
--path:"../nest/src"
--path:"../owl/src"

proc nimbleStore(): string =
  result = getEnv("NIMBLE_DIR")
  if result.len == 0:
    result = getEnv("HOME") & "/.nimble"
  result = result & "/pkgs2"

proc addPkg(name: string) =
  ## Put the newest install of `name` on the path. Stores disagree on layout --
  ## some packages keep their srcDir, others are flattened -- so pick whichever
  ## this machine actually has.
  let store = nimbleStore()
  var newest = ""
  for dir in listDirs(store):
    let base = dir.strip(chars = {'/'}).rsplit('/', 1)[^1]
    if base.startsWith(name & "-") and dir > newest:
      newest = dir
  if newest.len == 0:
    echo "config.nims: nimble package '" & name & "' not found under " & store
    return
  switch("path", if dirExists(newest & "/src"): newest & "/src" else: newest)

# Transitive dependencies of nest (see nest.nimble).
for pkg in ["chroma", "sdl3", "micros", "fungus", "kiwiberry"]:
  addPkg(pkg)

# nest requires the sdl3 backend define (mirrors ../nest/config.nims)
--d:sdl3

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
