## The file explorer's row window.
##
## The panel asks for a slice of the tree on every frame of a scroll, and the
## scan behind it is cached so the disk is not walked for each one. A cache is
## only worth having if it cannot be told apart from no cache, so these check
## that the window still answers correctly as the offset, the selection and
## the tree itself change.

import std/[algorithm, os, strutils, unittest]

import owl
import ../src/commands

const
  Entries = 120
  RowHeight = 27.0
  ViewportHeight = 270.0

proc treeRoot(): string =
  getTempDir() / "nide-test-file-tree"

proc buildTree(root: string, entries: int) =
  removeDir(root)
  createDir(root)
  for f in 0 ..< entries:
    writeFile(root / ("module" & align($f, 4, '0') & ".nim"), "## generated\n")

proc newEvaluator(): Evaluator =
  result = Evaluator.init()
  result.registerInternalCommands(NideOwlBridge.init())
  discard result.exec(parse("""
use nide:
  include file-tree-window
define:
  expanded = []
""", "setup"))

proc window(
    evaluator: var Evaluator, root: string, scrollY: float64,
    selected = "", field = "rows"
): Value =
  let source =
    "dict-get (file-tree-window \"" & root & "\" expanded \"" & selected &
    "\" \"\" \"name\" false \"all\" " & $scrollY & " " & $ViewportHeight &
    " " & $RowHeight & " 4) \"" & field & "\""
  evaluator.exec(parse(source, "window"))

proc rowPaths(rows: Value): seq[string] =
  for row in rows.items:
    result.add row["path"].text

proc selectedPaths(rows: Value): seq[string] =
  for row in rows.items:
    if row["selected"].boolean:
      result.add row["path"].text

suite "file tree window":
  setup:
    buildTree(treeRoot(), Entries)

  teardown:
    removeDir(treeRoot())
    invalidateFileTreeCache()

  test "the window is a slice of the tree, not the whole of it":
    var evaluator = newEvaluator()
    let
      root = treeRoot()
      total = evaluator.window(root, 0.0, field = "total").number.int
      rows = evaluator.window(root, 0.0)
    check total == Entries
    check rowPaths(rows).len > 0
    check rowPaths(rows).len < Entries div 2

  test "the padding above and below accounts for the rest of the tree":
    var evaluator = newEvaluator()
    let root = treeRoot()
    for offset in [0.0, 300.0, 1200.0, 2500.0]:
      let
        rows = evaluator.window(root, offset)
        before = evaluator.window(root, offset, field = "before").number
        after = evaluator.window(root, offset, field = "after").number
        shown = rowPaths(rows).len.float64
      check before + shown * RowHeight + after ==
        Entries.float64 * RowHeight

  test "a cached scan still answers each offset with its own rows":
    var evaluator = newEvaluator()
    let
      root = treeRoot()
      top = rowPaths(evaluator.window(root, 0.0))
      middle = rowPaths(evaluator.window(root, 1000.0))
      bottom = rowPaths(evaluator.window(root, 2500.0))
    check top.len > 0
    check top != middle
    check middle != bottom
    # And every slice is in tree order, drawn from the same scan.
    for slice in [top, middle, bottom]:
      var sorted = slice
      sorted.sort()
      check sorted == slice

  test "the same offset asked twice answers the same rows":
    # A frame asks once dispatching events and once building widgets, and the
    # two must agree or the widgets are built for rows the events were not.
    var evaluator = newEvaluator()
    let root = treeRoot()
    check rowPaths(evaluator.window(root, 700.0)) ==
      rowPaths(evaluator.window(root, 700.0))

  test "selection follows the selected path without a rescan":
    var evaluator = newEvaluator()
    let
      root = treeRoot()
      first = rowPaths(evaluator.window(root, 0.0))[0]
      second = rowPaths(evaluator.window(root, 0.0))[1]
    check selectedPaths(evaluator.window(root, 0.0, selected = first)) == @[first]
    check selectedPaths(evaluator.window(root, 0.0, selected = second)) == @[second]
    check selectedPaths(evaluator.window(root, 0.0)).len == 0

  test "a refresh picks up a file that appeared":
    var evaluator = newEvaluator()
    let root = treeRoot()
    check evaluator.window(root, 0.0, field = "total").number.int == Entries

    writeFile(root / "aaa-brand-new.nim", "## new\n")
    invalidateFileTreeCache()
    check evaluator.window(root, 0.0, field = "total").number.int == Entries + 1
    check "aaa-brand-new.nim" in rowPaths(evaluator.window(root, 0.0))[0]

  test "a different root is not answered from another root's scan":
    var evaluator = newEvaluator()
    let
      root = treeRoot()
      other = treeRoot() & "-other"
    buildTree(other, 7)
    defer: removeDir(other)
    check evaluator.window(root, 0.0, field = "total").number.int == Entries
    check evaluator.window(other, 0.0, field = "total").number.int == 7
    check evaluator.window(root, 0.0, field = "total").number.int == Entries
