import std/[strutils, unittest]

import owl
import ../src/commands

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

  test "run-command reports an unknown id instead of failing quietly":
    expect EvaluatorError:
      discard evaluator.exec(parse("""
use nide:
  include run-command

run-command "not-a-real-command"
""", "<test>"))
