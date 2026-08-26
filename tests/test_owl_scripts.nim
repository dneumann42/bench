## Checks over Nide's Owl sources that do not need a running UI.
##
## The scripts are only evaluated when the editor renders the widget that uses
## them, so a syntax error or a keybinding naming a command that does not exist
## goes unnoticed until someone presses the key. These parse every script and
## cross-check what the keymaps and toolbars name against the command registry.

import std/[os, sets, strutils, unittest]

import owl
import ../src/commands

const SourceDir = currentSourcePath().parentDir.parentDir / "src"

proc owlSources(): seq[string] =
  for path in walkDirRec(SourceDir):
    if path.endsWith(".owl"):
      result.add path

proc parsed(path: string): SyntaxNode =
  parse(readFile(path), path)

iterator nodes(node: SyntaxNode): SyntaxNode =
  ## Every command node in a tree, outermost first.
  var pending = @[node]
  while pending.len > 0:
    let current = pending.pop()
    if current.isNil:
      continue
    case current.kind
    of Script:
      for statement in current.statements:
        pending.add statement
    of Binding:
      pending.add current.value
    of Command:
      yield current
      pending.add current.callee
      for argument in current.arguments:
        pending.add argument
      for statement in current.body:
        pending.add statement
    else:
      discard

proc calleeName(node: SyntaxNode): string =
  if node.kind == Command and node.callee.kind == Symbol:
    node.callee.symbol
  else:
    ""

proc owlDefinedCommands(): HashSet[string] =
  ## Command ids `defcommand` introduces. These only reach the registry once
  ## their script runs, so a static check has to find them here.
  for path in owlSources():
    for node in parsed(path).nodes:
      if node.calleeName == "defcommand" and node.arguments.len > 0:
        let name = node.arguments[0]
        if name.kind == Symbol:
          result.incl name.symbol
        elif name.kind == Command and name.callee.kind == Symbol:
          result.incl name.callee.symbol

proc boundCommandIds(path: string): seq[tuple[id: string, line: int]] =
  ## Command ids named by a keymap binding or a toolbar entry.
  const
    KeyBinders = ["key", "ctrl", "alt", "shift", "key-combo"]
    ToolbarBinders = ["toolbar-item", "toolbar-tool"]
  for node in parsed(path).nodes:
    let callee = node.calleeName
    if node.arguments.len == 0:
      continue
    let last = node.arguments[^1]
    if last.kind != String:
      # A binding may carry a callable instead of an id; those have no id to
      # check.
      continue
    if callee in KeyBinders or callee in ToolbarBinders:
      result.add (last.stringValue, node.pos.line.int)

suite "owl sources":
  test "every script parses":
    var failures: seq[string]
    for path in owlSources():
      try:
        discard parsed(path)
      except OwlError as error:
        failures.add path.extractFilename & ": " & error.msg
    check failures == newSeq[string]()

  test "there are scripts to check":
    check owlSources().len > 10

suite "keybindings and toolbars name real commands":
  setup:
    let known = owlDefinedCommands()

  test "owl defines the commands the input layer relies on":
    for id in ["noop", "cancel-key-sequence", "editor-insert-frame-text",
        "vi-normal-mode", "vi-insert-mode"]:
      check id in known

  test "every bound command id resolves":
    var unresolved: seq[string]
    for path in owlSources():
      for (id, line) in boundCommandIds(path):
        if id.len == 0:
          continue
        if not hasCommand(id) and id notin known:
          unresolved.add path.extractFilename & ":" & $line & " -> " & id
    check unresolved == newSeq[string]()

  test "the editor drivers bind by id, not by closure":
    # Binding by id is what lets the palette show which keys reach a command.
    for name in ["emacs.owl", "vscode.owl", "vi.owl"]:
      let path = SourceDir / "editor-input" / name
      check boundCommandIds(path).len > 5

  test "keybindings reach commands the palette also offers":
    let bound = boundCommandIds(SourceDir / "keybindings.owl")
    check bound.len > 0
    for (id, _) in bound:
      if id == "noop":
        continue
      check hasCommand(id) or id in known
