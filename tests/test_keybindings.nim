## Loads the real keybinding scripts through an Owl runtime.
##
## The editor only evaluates these when a key is pressed, so nothing else
## catches a script that fails to load or a keymap that has drifted away from
## the commands it names.

import std/[os, strutils, tables, unittest]

import nest/owldsl
import owl
import ../src/commands
import ../src/widgets/panels
import ../src/widgets/toolbar

const SourceDir = currentSourcePath().parentDir.parentDir / "src"

proc loadedRuntime(): NestOwlRuntime =
  result = NestOwlRuntime.init()
  let bridge = NideOwlBridge.init()
  # The editor publishes this every frame; the vi driver reads it while it
  # builds its bindings.
  bridge.putData("active-editor-cursor-style", text("block"))
  bridge.putData("active-editor-input-driver", text("owl"))
  result.evaluator.registerInternalCommands(bridge)
  let path = SourceDir / "keybindings.owl"
  discard result.evaluator.exec(parse(readFile(path), path))

proc evaluate(runtime: NestOwlRuntime, source: string): Value =
  runtime.evaluator.exec(parse(source, "<test>"))

suite "editor shell":
  test "load.owl builds the toolbars, panels and status bar":
    let runtime = NestOwlRuntime.init()
    let bridge = NideOwlBridge.init()
    runtime.evaluator.registerInternalCommands(bridge)
    runtime.evaluator.registerToolbarBuilderCommands()
    runtime.evaluator.registerPanelBuilderCommands()
    let path = SourceDir / "load.owl"
    discard runtime.evaluator.exec(parse(readFile(path), path))

suite "keybinding scripts":
  test "the keybinding scripts and every input driver load":
    var runtime: NestOwlRuntime
    runtime = loadedRuntime()
    check not runtime.isNil

  test "a global binding reports the keys that reach its command":
    let runtime = loadedRuntime()
    check runtime.evaluate("""current-command-keybindings "find-file" """).text ==
        "Ctrl+x f"

  test "a modified binding spells out its modifiers":
    let runtime = loadedRuntime()
    let labels = runtime.evaluate(
      """current-command-keybindings "command-palette" """).text
    check "Ctrl+Shift+p" in labels

  test "every driver reaches the command palette":
    let runtime = loadedRuntime()
    for (driver, expected) in [("emacs", "Alt+x"), ("vscode", "Ctrl+Shift+p"),
        ("vi", "Shift+semicolon")]:
      discard runtime.evaluate("set editorInputDriver \"" & driver & "\"")
      let labels = runtime.evaluate(
        """current-command-keybindings "command-palette" """).text
      check expected in labels

  test "the configured driver's bindings are searched too":
    let runtime = loadedRuntime()
    # Emacs is the default driver, and binds Ctrl-A to the line start command.
    let labels = runtime.evaluate(
      """current-command-keybindings "editor-line-start" """).text
    check "Ctrl+a" in labels
    check "home" in labels

  test "a command nothing binds reports no keys":
    let runtime = loadedRuntime()
    check runtime.evaluate("""current-command-keybindings "file-save-as" """).text == ""

  test "switching driver switches which keys are reported":
    let runtime = loadedRuntime()
    discard runtime.evaluate("""set editorInputDriver "vi" """)
    let labels = runtime.evaluate(
      """current-command-keybindings "editor-backward-char" """).text
    check "h" in labels

  test "every driver builds its bindings without error":
    let runtime = loadedRuntime()
    for driver in ["emacs", "vscode", "vi"]:
      discard runtime.evaluate("set editorInputDriver \"" & driver & "\"")
      let labels = runtime.evaluate(
        """current-command-keybindings "editor-delete-backward" """).text
      check labels.len > 0

suite "command palette data":
  ## The palette widget needs a rendering UI to load, so what is checked here is
  ## the data it draws: the registry query, the keybinding lookup and the
  ## ranking native, composed the way command-palette-panel.owl composes them.
  setup:
    let runtime = loadedRuntime()
    discard runtime.evaluate("""
use nide:
  include command-palette-rows interactive-commands

fun palette-item entry:
  {}:
    id = entry.id
    description = entry.description
    keybindings = (current-command-keybindings entry.id)

fun palette-items-in entries:
  if (empty? entries):
    ([])
  else:
    cons (palette-item (first entries)) (palette-items-in (rest entries))

fun palette-items:
  palette-items-in (interactive-commands)

fun palette-row-for wanted rows:
  cond:
    when (empty? rows):
      nothing
    when (= (first rows).id wanted):
      first rows
    when true:
      palette-row-for wanted (rest rows)
""")

  test "the palette offers a useful number of commands":
    check runtime.evaluate("length (palette-items)").number > 20

  test "a row carries the description and the keys that reach it":
    let row = runtime.evaluate("""palette-row-for "find-file" (palette-items)""")
    check row.kind == Record
    check row["description"].text == "Open the file finder."
    check row["keybindings"].text == "Ctrl+x f"

  test "a row for an unbound command shows no keys":
    let row = runtime.evaluate("""palette-row-for "file-save-as" (palette-items)""")
    check row.kind == Record
    check row["keybindings"].text == ""

  test "accessors are not offered":
    let row = runtime.evaluate(
      """palette-row-for "get-active-editor-cursor" (palette-items)""")
    check row.kind == Nothing

  test "ranking a query keeps matching rows and marks one selected":
    let rows = runtime.evaluate("""command-palette-rows (palette-items) "find" "" """)
    check rows.kind == List
    check rows.len > 0
    check rows.len < 20
    var selected = 0
    for row in rows.items:
      if row["selected"].boolean:
        inc selected
    check selected == 1

  test "a command defined in a script shows up in the palette":
    discard runtime.evaluate("""
use nide:
  include defcommand

defcommand say-something:
  "A command defined in a script."
  nothing
""")
    let row = runtime.evaluate("""palette-row-for "say-something" (palette-items)""")
    check row.kind == Record
    check row["description"].text == "A command defined in a script."
