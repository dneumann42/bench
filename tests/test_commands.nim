import std/[monotimes, os, strutils, unittest]
from std/times import inNanoseconds

import owl
import ../src/commands
import ../src/modes

suite "command registry":
  test "native commands register themselves as the module loads":
    check commandCount() > 50
    check hasCommand("find-file")
    check hasCommand("get-active-editor-cursor")
    check hasCommand("run-command")

  test "every registered command is documented":
    var undocumented: seq[string]
    for command in commands():
      if command.description.strip().len == 0:
        undocumented.add command.id
    check undocumented == newSeq[string]()

  test "descriptions are prose, not the command id repeated":
    for command in commands():
      check command.description != command.id
      check command.description.len >= 8

  test "palette commands are a subset of all commands":
    var interactive, total = 0
    for command in commands():
      inc total
      if command.interactive:
        inc interactive
    check interactive > 0
    check interactive < total

  test "accessors are scriptable but stay out of the palette":
    for id in ["get-active-editor-cursor", "get-projects", "path-join"]:
      check hasCommand(id)
      for command in commands():
        if command.id == id:
          check not command.interactive

  test "actions are offered in the palette":
    for id in ["find-file", "file-save", "command-palette", "editor-line-start"]:
      var found = false
      for command in commands():
        if command.id == id:
          found = true
          check command.interactive
      check found

  test "ids are unique and sorted":
    let ids = commandIds()
    check ids.len == commandCount()
    for index in 1 ..< ids.len:
      check ids[index - 1] < ids[index]

  test "unknown ids are reported rather than silently ignored":
    check not hasCommand("no-such-command")
    expect EvaluatorError:
      discard commandValue("no-such-command")

suite "commands from Owl":
  setup:
    var evaluator = Evaluator.init()
    let bridge = NideOwlBridge.init()
    evaluator.registerInternalCommands(bridge)
    # The editor seeds these before it runs any script; commands that write
    # status expect somewhere to write to.
    evaluator.env.bindText(VarStatus, "")

  test "defcommand registers a command and its description":
    discard evaluator.exec(parse("""
use nide:
  include defcommand

defcommand greet-the-buffer:
  "Say hello in the status bar."
  nothing
""", "<test>"))
    check hasCommand("greet-the-buffer")
    check commandDescription("greet-the-buffer") == "Say hello in the status bar."

  test "defcommand refuses a command with no description":
    expect EvaluatorError:
      discard evaluator.exec(parse("""
use nide:
  include defcommand

defcommand undocumented:
  nothing
""", "<test>"))

  test "an Owl command is invokable by id from Nim":
    discard evaluator.exec(parse("""
use nide:
  include defcommand set-status

defcommand remember-a-name name:
  "Record a name in the status bar."
  set-status name
""", "<test>"))
    discard evaluator.env.invoke("remember-a-name", [text("owl")])
    check evaluator.env.get("nide-status").text == "owl"

  test "run-command reaches a command by id from Owl":
    discard evaluator.exec(parse("""
use nide:
  include defcommand run-command set-status

defcommand remember name:
  "Record a name in the status bar."
  set-status name

run-command "remember" "puppeted"
""", "<test>"))
    check evaluator.env.get("nide-status").text == "puppeted"

  test "describe-command reads a native command's doc comment":
    let described = evaluator.exec(parse("""
use nide:
  include describe-command

describe-command "find-file"
""", "<test>"))
    check described.text == "Open the file finder."

  test "commands lists both origins once Owl has defined one":
    discard evaluator.exec(parse("""
use nide:
  include defcommand

defcommand from-owl:
  "A command defined in Owl."
  nothing
""", "<test>"))
    var origins: seq[string]
    for command in commands():
      if command.id in ["from-owl", "find-file"]:
        origins.add $command.origin
    check "owl" in origins
    check "nim" in origins

  test "run-command reaches a command the script never imported":
    # The registry is global, so a script only has to import run-command to
    # drive anything the editor can do.
    discard evaluator.exec(parse("""
use nide:
  include run-command

run-command "set-status" "reached"
""", "<test>"))
    check evaluator.env.get("nide-status").text == "reached"

  test "a command can declare tags and be found by them":
    discard evaluator.exec(parse("""
use nide:
  include defcommand

defcommand tagged-one:
  "First tagged command."
  tags "demo" "alpha"
  nothing

defcommand tagged-two:
  "Second tagged command."
  tags "demo"
  nothing

defcommand untagged-one:
  "Not tagged at all."
  nothing
""", "<test>"))
    check commandTags("tagged-one") == @["demo", "alpha"]
    check commandTags("untagged-one").len == 0
    var demo: seq[string]
    for command in commandsTagged("demo"):
      demo.add command.id
    check demo == @["tagged-one", "tagged-two"]
    check "untagged-one" notin demo

  test "a tag declaration is metadata, not part of the body":
    # `tags` must not run as code, and must not become the command's result.
    discard evaluator.exec(parse("""
use nide:
  include defcommand set-status

defcommand tag-then-body:
  "Runs its body, not its tags."
  tags "demo"
  set-status "body ran"
""", "<test>"))
    discard evaluator.env.invoke("tag-then-body")
    check evaluator.env.get("nide-status").text == "body ran"

  test "the mode scripts tag their commands":
    let path = currentSourcePath().parentDir.parentDir / "src" / "modes" / "nim.owl"
    discard evaluator.exec(parse(readFile(path), path))
    check "mode" in commandTags("nim-enable-highlighting")
    check "nim" in commandTags("nim-enable-highlighting")

  test "a hidden tag keeps a command out of the palette":
    discard evaluator.exec(parse("""
use nide:
  include defcommand

defcommand shows-up:
  "Offered to a person."
  nothing

defcommand stays-out:
  "Plumbing nobody picks by name."
  tags "hidden"
  nothing
""", "<test>"))
    var listed: seq[string]
    for command in commands():
      if command.interactive:
        listed.add command.id
    check "shows-up" in listed
    check "stays-out" notin listed
    # still a command, just not palette clutter
    check hasCommand("stays-out")

  test "a plain fun is not reachable by id":
    # An Owl `fun` is a private callable, not a Nide command. Anything meant to
    # be invoked by name declares itself with `defcommand`.
    discard evaluator.exec(parse("""
fun not-a-command:
  nothing
""", "<test>"))
    check not hasCommand("not-a-command")
    expect EvaluatorError:
      discard evaluator.env.invoke("not-a-command")

  test "run-command reports an unknown id instead of failing quietly":
    expect EvaluatorError:
      discard evaluator.exec(parse("""
use nide:
  include run-command

run-command "not-a-real-command"
""", "<test>"))


suite "project file scanning":
  setup:
    var evaluator = Evaluator.init()
    let bridge = NideOwlBridge.init()
    evaluator.registerInternalCommands(bridge)

  test "an effectively unbounded root is capped rather than walked to the end":
    # The finder walks the tree on the UI thread, and with no project open the
    # root falls back to the home directory. Scanning "/" stands in for that:
    # it must come back promptly and admit it truncated, not wedge the caller.
    let started = getMonoTime()
    let rows = evaluator.exec(parse("""
use nide:
  include project-files-window

project-files-window "/" "zzz-no-such-file"
""", "<test>"))
    let elapsedMs = (getMonoTime() - started).inNanoseconds.float64 / 1_000_000.0
    check rows.kind == List
    check elapsedMs < 10_000.0
    let truncated = evaluator.exec(parse("""
use nide:
  include project-files-truncated?

project-files-truncated?
""", "<test>"))
    check truncated.boolean


suite "mode scripts are found, not listed":
  test "a builtin mode resolves to its file in the source tree":
    let found = modeSource("nim")
    check found.source.len > 0
    check found.path == builtinModeScriptPath("nim")
    check found.path.fileExists

  test "an unknown mode simply has no script":
    # No case statement to fall off the end of: a mode with no file has none,
    # and the buffer stays plain text.
    check modeSource("no-such-mode-xyz").source.len == 0
    check modeSource("").source.len == 0

  test "a mode dropped into the config directory is picked up":
    let path = modeScriptPath("nide-test-only-mode")
    check not path.fileExists
    createDir(path.parentDir)
    writeFile(path, "; test mode\n")
    try:
      let found = modeSource("nide-test-only-mode")
      check found.path == path
      check found.source.contains("test mode")
    finally:
      removeFile(path)

  test "the user config wins over the copy shipped with nide":
    let path = modeScriptPath("nim")
    if path.fileExists:
      skip()   # never clobber a real user mode script
    else:
      createDir(path.parentDir)
      writeFile(path, "; user override\n")
      try:
        check modeSource("nim").path == path
      finally:
        removeFile(path)


suite "text columns":
  setup:
    var evaluator = Evaluator.init()
    let bridge = NideOwlBridge.init()
    evaluator.registerInternalCommands(bridge)

  proc column(evaluator: var Evaluator, source: string): string =
    evaluator.exec(parse("""
use nide:
  include text-column

""" & source, "<test>")).text

  test "short text is padded to the column width":
    check evaluator.column("""text-column "ab" 5""") == "ab   "

  test "long text is truncated with an ellipsis":
    check evaluator.column("""text-column "abcdefgh" 5""") == "abcd…"

  test "padding can be turned off for a trailing column":
    check evaluator.column("""text-column "ab" 5 false""") == "ab"

  test "a zero width column is empty":
    check evaluator.column("""text-column "abc" 0""") == ""
