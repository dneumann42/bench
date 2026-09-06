## Cost of one file explorer frame, against the size of the tree it shows.
##
## The panel already asks for a window of rows rather than all of them, so what
## this measures is what producing that window costs: the directory walk behind
## it, and how many rows are turned into Owl values to hand back. A scroll is a
## new window over the same tree, and a frame asks for one twice -- once
## dispatching events and once building widgets -- so anything the window does
## that does not depend on the scroll offset is paid for twice per frame and
## thrown away.
##
##   nim c -r -d:release tests/bench_file_tree.nim [entries] [calls]

import std/[monotimes, os, strformat, strutils]
from std/times import inNanoseconds

import owl
import ../src/commands

proc buildTree(root: string, entries: int) =
  ## A directory of a known size, in the scratch area. Flat, so the row count
  ## is exactly `entries` without needing anything expanded.
  removeDir(root)
  createDir(root)
  for f in 0 ..< entries:
    writeFile(root / ("module" & align($f, 5, '0') & ".nim"), "## generated\n")

const SetupScript = """
use nide:
  include file-tree-window
define:
  expanded = []
"""

proc script(root: string, scrollY: float64): string =
  ## One window call, as the panel makes it: the same tree, a new offset.
  &"""dict-get (file-tree-window "{root}" expanded "" "" "name" false "all" """ &
    &"""{scrollY} 600 27 8) "total""""

proc main() =
  let
    entries =
      if paramCount() >= 1:
        try: parseInt(paramStr(1)) except ValueError: 2000
      else: 2000
    calls =
      if paramCount() >= 2:
        try: parseInt(paramStr(2)) except ValueError: 200
      else: 200
    root = getTempDir() / "nide-bench-file-tree"

  buildTree(root, entries)
  defer: removeDir(root)

  var evaluator = Evaluator.init()
  evaluator.registerInternalCommands(NideOwlBridge.init())
  discard evaluator.exec(parse(SetupScript, "bench-setup"))

  # Warm: the first call pays for whatever the walk caches.
  discard evaluator.exec(parse(script(root, 0.0), "bench"))

  var total = 0.0
  let start = getMonoTime()
  for i in 0 ..< calls:
    # A scroll drag: a new offset every call, same tree.
    let offset = float64((i mod 200) * 27)
    let value = evaluator.exec(parse(script(root, offset), "bench"))
    total = value.number
  let elapsed = (getMonoTime() - start).inNanoseconds.float64 / 1_000_000.0

  echo ""
  echo &"  tree: {total.int} rows"
  echo &"  window calls: {calls}"
  echo &"  per call:  {elapsed / calls.float64:.3f} ms"
  echo &"  per frame: {2.0 * elapsed / calls.float64:.3f} ms " &
    "(a frame asks twice: events, then widgets)"
  echo ""

when isMainModule:
  main()
