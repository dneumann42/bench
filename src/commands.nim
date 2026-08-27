## Nide's native commands, and the bridge they drive the editor through.
##
## Every proc here carrying a `nideCommand`/`nideAction` pragma registers
## itself in the command registry as it loads; `registerInternalCommands` only
## has to hand the collected set to Owl. See `registry.nim` for what a command
## is and how Owl defines its own.

import std/[algorithm, math, os, sets, streams, strutils, tables, sugar,
  times, unicode]
import owl
import registry
export registry

const
  ActionNewFile* = "new-file"
  ActionOpenFileDialog* = "open-file-dialog"
  ActionSaveFileAsDialog* = "save-file-as-dialog"
  ActionMarkBufferSaved* = "mark-buffer-saved"
  ActionToggleProjectsPanel* = "toggle-projects-panel"
  ActionToggleFileExplorerPanel* = "toggle-file-explorer-panel"
  MaxFinderRows = 400
  MaxPreviewBytes = 200_000
  ## The file finder walks the project tree on the UI thread, so the walk is
  ## bounded rather than trusted to finish. Without a project open the root
  ## falls back to the home directory, which is effectively unbounded.
  MaxFinderScanEntries = 40_000
  MaxFinderScanDepth = 32

  VarState* = "nide-state"
  VarRequestedActions* = "nide-requested-actions"
  VarStatus* = "nide-status"

type
  NideBridgeRequest* = object
    name*: string
    arguments*: seq[Value]

  NideOwlBridge* = ref object
    data: Table[string, Value]
    requests: seq[NideBridgeRequest]

proc init*(T: typedesc[NideOwlBridge]): T =
  NideOwlBridge(data: initTable[string, Value](), requests: @[])

proc putData*(bridge: NideOwlBridge, name: string, value: Value) =
  if not bridge.isNil:
    bridge.data[name] = value

proc bridgeGet*(bridge: NideOwlBridge, name: string): Value {.raises: [
    EvaluatorError].} =
  if bridge.isNil or name notin bridge.data:
    raise newException(EvaluatorError, "unknown Nide getter: " & name)
  bridge.data.getOrDefault(name)

proc request*(bridge: NideOwlBridge, name: string,
    arguments: openArray[Value] = []) =
  if not bridge.isNil:
    bridge.requests.add NideBridgeRequest(name: name, arguments: @arguments)

proc drainRequests*(bridge: NideOwlBridge): seq[NideBridgeRequest] =
  if bridge.isNil:
    return @[]
  result = bridge.requests
  bridge.requests.setLen(0)

## The bridge the registered commands talk to. Set by
## `registerInternalCommands` before any command can run.
var activeBridge: NideOwlBridge
proc textList*(items: openArray[string]): Value =
  list(collect(for item in items: text(item)))

proc dictionaryValue(fields: openArray[(string, Value)]): Value =
  var entries = initTable[string, Value]()
  for (key, value) in fields:
    entries[key] = value
  dictionary(entries)

proc bindvalue*(env: Environment, name: string, value: Value) =
  env.define(name, value)

proc bindText*(env: Environment, name, value: string) =
  env.bindValue(name, text(value))

proc bindTextList*(env: Environment, name: string, values: openArray[string]) =
  env.bindValue(name, textList(values))

proc bindEmptyList*(env: Environment, name: string) =
  env.bindValue(name, list(@[]))

proc valueText(value: Value): string =
  case value.kind
  of Text:
    value.text
  of Number:
    if value.number == value.number.int.float:
      $value.number.int
    else:
      $value.number
  of Boolean:
    if value.boolean: "true" else: "false"
  else:
    ""

proc stateField(env: Environment, key: string): string =
  try:
    let state = env.get(VarState)
    if state.kind == Dictionary and state.entries.hasKey(key):
      valueText(state.entries.getOrDefault(key))
    else:
      ""
  except EvaluatorError:
    ""

proc stateNumber(env: Environment, key: string): float64 =
  try:
    let state = env.get(VarState)
    if state.kind == Dictionary and state.entries.hasKey(key):
      let value = state.entries.getOrDefault(key)
      case value.kind
      of Number:
        value.number
      of Text:
        parseFloat(value.text)
      else:
        0
    else:
      0
  except CatchableError:
    0

proc stateSnapshot*(
    bufferIDs: openArray[string],
    activeBufferPath,
    activeBufferText: string,
    activeBufferID = "",
    activeEditorCursor = 0,
    activeEditorLine = 1,
    activeEditorColumn = 1,
    activeEditorSelectionStart = 0,
    activeEditorSelectionStop = 0,
    activeEditorHasSelection = false,
    activeEditorSelectedText = "",
    activeEditorInputDriver = "",
    activeEditorCursorStyle = "line",
): Value =
  var entries = initTable[string, Value]()
  entries["buffers"] = textList(bufferIDs)
  entries["active-buffer-id"] = text(activeBufferID)
  entries["active-buffer-path"] = text(activeBufferPath)
  entries["active-buffer-text"] = text(activeBufferText)
  entries["active-editor-cursor"] = number(activeEditorCursor.float64)
  entries["active-editor-line"] = number(activeEditorLine.float64)
  entries["active-editor-column"] = number(activeEditorColumn.float64)
  entries["active-editor-selection-start"] = number(activeEditorSelectionStart.float64)
  entries["active-editor-selection-stop"] = number(activeEditorSelectionStop.float64)
  entries["active-editor-has-selection"] = boolean(activeEditorHasSelection)
  entries["active-editor-selected-text"] = text(activeEditorSelectedText)
  entries["active-editor-input-driver"] = text(activeEditorInputDriver)
  entries["active-editor-cursor-style"] = text(activeEditorCursorStyle)
  dictionary(entries)

proc readText*(env: Environment, name: string): string =
  try:
    let value = env.get(name)
    if value.kind == Text:
      value.text
    else:
      ""
  except EvaluatorError:
    ""

proc readTextSet*(env: Environment, name: string): HashSet[string] =
  try:
    let value = env.get(name)
    if value.kind == List:
      for item in value.items:
        if item.kind == Text:
          result.incl item.text
  except EvaluatorError:
    discard
proc expectOneArgument(commandID: string, arguments: seq[SyntaxNode]) =
  if arguments.len != 1:
    raise newException(EvaluatorError, commandID & " expects one argument")

proc expectNoArguments(commandID: string, arguments: seq[SyntaxNode]) =
  if arguments.len != 0:
    raise newException(EvaluatorError, commandID & " expects no arguments")
proc evalTextArgument(env: Environment, arguments: seq[SyntaxNode], index: int,
    commandID: string): string {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    raise newException(EvaluatorError, commandID & " missing argument")
  let value = env.eval(arguments[index])
  if value.kind != Text:
    raise newException(EvaluatorError, commandID & " expects text")
  value.text

proc evalBoolArgument(env: Environment, arguments: seq[SyntaxNode], index: int,
    commandID: string): bool {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    raise newException(EvaluatorError, commandID & " missing argument")
  env.eval(arguments[index]).isTruthy

proc evalNumberArgument(env: Environment, arguments: seq[SyntaxNode],
    index: int, commandID: string): float64 {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    raise newException(EvaluatorError, commandID & " missing argument")
  let value = env.eval(arguments[index])
  if value.kind != Number:
    raise newException(EvaluatorError, commandID & " expects number")
  value.number

proc evalTextListArgument(env: Environment, arguments: seq[SyntaxNode],
    index: int, commandID: string): seq[string] {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    raise newException(EvaluatorError, commandID & " missing argument")
  let value = env.eval(arguments[index])
  if value.kind != List:
    raise newException(EvaluatorError, commandID & " expects a list")
  for item in value.items:
    if item.kind == Text:
      result.add item.text

proc textListContains(items: openArray[string], target: string): bool =
  for item in items:
    if item == target:
      return true

proc dictionaryText(value: Value, key: string): string =
  if value.kind != Dictionary or not value.entries.hasKey(key):
    return ""
  let entry = value.entries.getOrDefault(key)
  if entry.kind == Text:
    entry.text
  else:
    ""

proc requestAction(env: Environment, action: string) {.raises: [EvaluatorError].} =
  if not activeBridge.isNil:
    activeBridge.request(action)
    return
  var actions =
    if env.contains(VarRequestedActions):
      env.get(VarRequestedActions)
    else:
      list(@[])
  if actions.kind != List:
    raise newException(EvaluatorError, VarRequestedActions & " must be a list")
  env.set(VarRequestedActions, actions.listAppended(text(action)))

# ---------------------------------------------------------------------------
# Command families
#
# Three shapes cover most of the surface: read a value the editor published,
# forward a request to the editor, and forward a primitive to the active
# editor. Each command is a row carrying its own id and description.
# ---------------------------------------------------------------------------

proc registerBridgeGetter(id, getterName, description: string) =
  registerNativeCommand(id, description, proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.closure, raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, id & " expects no arguments")
    activeBridge.bridgeGet(getterName)
  )

proc registerBridgeRequest(id, requestName, description: string,
    arities: openArray[int], interactive = false) =
  let counts = @arities
  registerNativeCommand(id, description, proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.closure, raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len notin counts:
      raise newException(EvaluatorError, id & " got " & $arguments.len &
          " arguments")
    var values: seq[Value]
    for argument in arguments:
      values.add env.eval(argument)
    activeBridge.request(requestName, values)
    boolean(true)
  , interactive = interactive)

proc registerEditorCommand(id, editorCommand, description: string) =
  registerNativeCommand(id, description, proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.closure, raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, id & " expects no arguments")
    activeBridge.request("active-editor.command", [text(editorCommand)])
    boolean(true)
  , interactive = true)

for (id, getterName, description) in [
  ("get-project-manager", "project-manager", "The project manager state."),
  ("get-projects", "projects", "The tracked projects."),
  ("get-project-profile-templates", "project-profile-templates",
      "The available project profile templates."),
  ("get-active-project", "active-project", "The active project, if any."),
  ("get-active-project-path", "active-project-path",
      "The active project's directory path."),
  ("get-home-directory", "home-directory", "The user's home directory."),
  ("get-panels", "panels", "The docked and floating panels."),
  ("get-floating-activation-generation", "floating-activation-generation",
      "A counter that changes each time a floating panel is activated."),
  ("get-buffers", "buffers", "The open buffers."),
  ("get-buffer-preview-text", "buffer-preview-text",
      "Preview text for the buffer currently being previewed."),
  ("get-current-mode", "active-buffer-mode", "The active buffer's file mode."),
  ("get-active-buffer-id", "active-buffer-id", "The active buffer's id."),
  ("get-active-buffer-path", "active-buffer-path",
      "The active buffer's file path."),
  ("get-active-editor-text-length", "active-editor-text-length",
      "The number of characters in the active editor."),
  ("get-active-editor-cursor", "active-editor-cursor",
      "The active editor's cursor offset."),
  ("get-active-editor-line", "active-editor-line",
      "The line the active editor's cursor is on."),
  ("get-active-editor-column", "active-editor-column",
      "The column the active editor's cursor is on."),
  ("get-active-editor-selection-start", "active-editor-selection-start",
      "Where the active editor's selection starts."),
  ("get-active-editor-selection-stop", "active-editor-selection-stop",
      "Where the active editor's selection ends."),
  ("get-active-editor-has-selection", "active-editor-has-selection",
      "Whether the active editor has a selection."),
  ("get-active-editor-selected-text", "active-editor-selected-text",
      "The text selected in the active editor."),
  ("get-active-editor-input-driver", "active-editor-input-driver",
      "The name of the active editor's input driver."),
  ("get-active-editor-cursor-style", "active-editor-cursor-style",
      "The active editor's cursor style."),
  ("auto-track-opened-projects", "auto-track-opened-projects",
      "Whether opening a directory also tracks it as a project."),
  ("open-build-launch-tab", "open-build-launch-tab",
      "Whether building opens the launch tab."),
  ("open-run-launch-tab", "open-run-launch-tab",
      "Whether running opens the launch tab."),
  ("open-check-launch-tab", "open-check-launch-tab",
      "Whether checking opens the launch tab."),
]:
  registerBridgeGetter(id, getterName, description)

for (id, requestName, description, arities, interactive) in [
  ("project-open", "project.pick-directory", "Open a project directory.",
      @[0], true),
  ("open-project", "project.open", "Open a tracked project by name.", @[1], false),
  ("pick-project-directory", "project.pick-directory",
      "Choose a project directory with the system dialog.", @[0], false),
  ("add-project", "project.add", "Track a project under a name and directory.",
      @[2], false),
  ("save-project-profile", "project.profile.save", "Save a project run profile.",
      @[7], false),
  ("run-project-profile", "project.profile.run", "Run a project profile.",
      @[3], false),
  ("set-process-launch-tab", "process.launch-tab.set",
      "Set whether a kind of process opens the launch tab.", @[2], false),
  ("unload-project", "project.unload", "Unload the active project.", @[0], false),
  ("reload-projects", "projects.reload",
      "Reload the tracked projects from disk.", @[0], false),
  ("save-projects", "projects.save", "Write the tracked projects to disk.",
      @[0], false),
  ("set-nide-status", "status.set", "Set the status bar message.", @[1], false),
  ("toggle-panel", "panel.toggle", "Toggle a panel by id.", @[1], false),
  ("open-floating-panel", "panel.open-floating",
      "Open a panel as a floating window.", @[1], false),
  ("float-panel", "panel.float",
      "Detach a docked panel into a floating window.", @[1], false),
  ("dock-panel", "panel.dock", "Dock a floating panel.", @[1], false),
  ("float-active-pane", "pane.float-active",
      "Detach the active pane into a floating window.", @[0], false),
  ("dock-pane", "pane.dock", "Dock a floating pane.", @[1], false),
  ("pane-split-column", "pane.split-column",
      "Split the current pane into columns.", @[0], true),
  ("pane-split-row", "pane.split-row", "Split the current pane into rows.",
      @[0], true),
  ("pane-unsplit", "pane.unsplit", "Remove the current pane split.", @[0], true),
  ("open-file-path", "file.open-path", "Open a file by path.", @[1], false),
  ("switch-buffer", "buffer.switch", "Switch to a buffer by id.", @[1], false),
  ("kill-buffer", "buffer.kill", "Close a buffer by id.", @[1], false),
  ("preview-buffer", "buffer.preview", "Preview a buffer by id.", @[1], false),
  ("close-floating", "floating.close", "Close the floating window.", @[0], false),
  ("toggle-floating", "floating.toggle", "Toggle the floating window.",
      @[0], true),
  ("set-editor-syntax", "buffer.set-syntax",
      "Apply a syntax definition to the active buffer.", @[1], false),
  ("clear-editor-syntax", "buffer.clear-syntax",
      "Remove the active buffer's syntax highlighting.", @[0], false),
  ("set-mode-hook", "buffer.set-mode-hook",
      "Bind a command to a buffer mode hook.", @[2], false),
  ("active-editor-command", "active-editor.command",
      "Send a primitive command to the active editor.", @[1, 2, 3], false),
]:
  registerBridgeRequest(id, requestName, description, arities, interactive)

for (id, editorCommand, description) in [
  ("editor-forward-word", "word-forward", "Move the cursor forward by one word."),
  ("editor-backward-word", "word-backward",
      "Move the cursor backward by one word."),
  ("editor-delete-word-forward", "delete-word-forward",
      "Delete the word after the cursor."),
  ("editor-delete-word-backward", "delete-word-backward",
      "Delete the word before the cursor."),
  ("editor-delete-backward", "delete-backward",
      "Delete the character before the cursor."),
  ("editor-delete-forward", "delete-forward",
      "Delete the character after the cursor."),
  ("editor-delete-selection", "delete-selection", "Delete the selected text."),
  ("editor-kill-line-start", "kill-line-start",
      "Delete from the cursor to the start of the line."),
  ("editor-kill-line-end", "kill-line-end",
      "Delete from the cursor to the end of the line."),
  ("editor-select-all", "select-all", "Select the entire buffer."),
  ("editor-copy", "copy-selection", "Copy the current selection."),
  ("editor-cut", "cut-selection", "Cut the current selection."),
  ("editor-paste", "paste-clipboard", "Paste from the clipboard."),
  ("editor-undo", "undo", "Undo the last editor change."),
  ("editor-redo", "redo", "Redo the last undone editor change."),
]:
  registerEditorCommand(id, editorCommand, description)
proc detectFileIconMode(): string {.raises: [].} =
  for directory in [
    getHomeDir() / ".local" / "share" / "fonts",
    getHomeDir() / ".fonts",
    "/usr/local/share/fonts",
    "/usr/share/fonts",
  ]:
    if not dirExists(directory):
      continue
    try:
      for path in walkDirRec(directory):
        let name = path.extractFilename.toLowerAscii()
        if name.endsWith(".ttf") or name.endsWith(".otf") or name.endsWith(".ttc"):
          if "nerdfont" in name or "nerd font" in name or " nf " in name or
              "nf-" in name:
            return "nerd"
    except CatchableError:
      discard
  "unicode"

proc fileIcon(name: string, isDir: bool, mode: string): string =
  if mode == "nerd":
    if isDir:
      return ""
    let ext = name.splitFile.ext.toLowerAscii()
    case ext
    of ".nim": ""
    of ".nims", ".nimble": ""
    of ".owl": "󰈙"
    of ".md", ".org", ".txt": "󰈙"
    of ".json", ".lock": ""
    of ".c", ".h": ""
    of ".cpp", ".hpp", ".cc": ""
    of ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp": "󰋩"
    of ".ttf", ".otf": ""
    of ".sh", ".bash": ""
    else: "󰈔"
  elif mode == "unicode":
    if isDir: "▣" else: "□"
  else:
    if isDir: "[D]" else: "[F]"

proc hasVisibleChild(path: string, showHidden, showDirs,
    showFiles: bool): bool =
  try:
    for kind, child in walkDir(path, relative = false):
      let name = child.extractFilename
      if not showHidden and name.startsWith("."):
        continue
      if kind == pcDir and showDirs:
        return true
      if kind == pcFile and showFiles:
        return true
  except CatchableError:
    discard

proc sortedDirEntries(path, sortMode: string, showHidden, showDirs,
    showFiles: bool): seq[tuple[path, name: string, isDir: bool]] =
  try:
    for kind, child in walkDir(path, relative = false):
      let
        name = child.extractFilename
        isDir = kind == pcDir
      if kind notin {pcDir, pcFile}:
        continue
      if not showHidden and name.startsWith("."):
        continue
      if isDir and not showDirs:
        continue
      if (not isDir) and not showFiles:
        continue
      result.add((child, name, isDir))
  except CatchableError:
    return
  result.sort(proc(a, b: tuple[path, name: string, isDir: bool]): int =
    if a.isDir != b.isDir:
      return if a.isDir: -1 else: 1
    case sortMode
    of "extension":
      result = cmp(a.name.splitFile.ext.toLowerAscii(),
          b.name.splitFile.ext.toLowerAscii())
      if result != 0:
        return
    of "kind":
      result = cmp($a.isDir, $b.isDir)
      if result != 0:
        return
    else:
      discard
    cmp(a.name.toLowerAscii(), b.name.toLowerAscii())
  )

proc addFileTreeRows(rows: var seq[Value], path: string, depth: int,
    expanded: HashSet[string], selectedPath, query, sortMode, iconMode: string,
    showHidden, showDirs, showFiles: bool, remaining: var int): bool =
  if remaining <= 0:
    return false
  let queryLower = query.toLowerAscii()
  var matchedAny = false
  for entry in sortedDirEntries(path, sortMode, showHidden, showDirs, showFiles):
    if remaining <= 0:
      break
    let
      childExpanded = entry.path in expanded
      hasChildren = entry.isDir and hasVisibleChild(entry.path, showHidden,
          showDirs, showFiles)
      selfMatches = queryLower.len == 0 or entry.name.toLowerAscii().contains(
          queryLower) or
        entry.path.toLowerAscii().contains(queryLower)
    var childRows: seq[Value]
    var childMatches = false
    if entry.isDir and (childExpanded or queryLower.len > 0):
      childMatches = addFileTreeRows(childRows, entry.path, depth + 1,
          expanded, selectedPath, query, sortMode, iconMode, showHidden,
          showDirs, showFiles, remaining)
    if queryLower.len == 0 or selfMatches or childMatches:
      matchedAny = true
      rows.add dictionaryValue([
        ("path", text(entry.path)),
        ("name", text(entry.name)),
        ("kind", text(if entry.isDir: "directory" else: "file")),
        ("isDir", boolean(entry.isDir)),
        ("depth", number(depth.float64)),
        ("expanded", boolean(childExpanded)),
        ("hasChildren", boolean(hasChildren)),
        ("selected", boolean(entry.path == selectedPath)),
        ("icon", text(fileIcon(entry.name, entry.isDir, iconMode))),
      ])
      dec remaining
      if childExpanded or queryLower.len > 0:
        rows.add childRows
  matchedAny

proc fileTreeRows(root: string, expandedList: seq[string], selectedPath, query,
    sortMode: string, showHidden, showDirs, showFiles: bool): seq[Value] =
  let iconMode = detectFileIconMode()
  var expanded = initHashSet[string]()
  for item in expandedList:
    expanded.incl item.expandTilde()
  var remaining = 5000
  discard addFileTreeRows(result, root, 0, expanded, selectedPath, query,
      sortMode, iconMode, showHidden, showDirs, showFiles, remaining)

proc fuzzyScore(haystack, needle: string): int =
  if needle.len == 0:
    return 0
  let
    hay = haystack.toLowerAscii()
    query = needle.toLowerAscii()
  if hay.contains(query):
    return query.len * 20 - hay.find(query)
  var
    index = 0
    score = 0
    streak = 0
  for ch in hay:
    if index < query.len and ch == query[index]:
      inc index
      inc streak
      score += 4 + streak
    else:
      streak = 0
  if index == query.len:
    score - hay.len
  else:
    low(int) div 4

proc matchesFuzzy(haystack, query: string): bool =
  query.len == 0 or fuzzyScore(haystack, query) > low(int) div 8

type FileScan = object
  budget: int ## directory entries left to visit
  truncated: bool ## whether the walk gave up before seeing everything

proc collectProjectFiles(
    root, baseRoot, query: string,
    ignoredDirs: HashSet[string],
    rows: var seq[tuple[score: int, path, name, relative: string]],
    scan: var FileScan,
    depth = 0,
) =
  if scan.budget <= 0 or depth > MaxFinderScanDepth:
    scan.truncated = true
    return
  try:
    for kind, path in walkDir(root, relative = false):
      if scan.budget <= 0:
        scan.truncated = true
        return
      dec scan.budget
      let name = path.extractFilename
      if name.len == 0:
        continue
      if kind == pcDir:
        if name in ignoredDirs:
          continue
        collectProjectFiles(path, baseRoot, query, ignoredDirs, rows, scan,
            depth + 1)
      elif kind == pcFile:
        var rel = path
        try:
          rel = relativePath(path, baseRoot)
        except CatchableError:
          discard
        if not matchesFuzzy(name & " " & rel, query):
          continue
        rows.add((fuzzyScore(name & " " & rel, query), path, name, rel))
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Status, text and path commands
# ---------------------------------------------------------------------------

proc requestActionCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "request-action", raises: [EvaluatorError].} =
  ## Queue an editor action by name for the host to carry out.
  discard layout
  discard bodyNodes
  expectOneArgument("request-action", arguments)
  let action = env.eval(arguments[0])
  if action.kind != Text:
    raise newException(EvaluatorError, "request-action expects text")
  env.requestAction(action.text)
  boolean(true)

proc setStatusCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "set-status", raises: [EvaluatorError].} =
  ## Set the status bar message.
  discard layout
  discard bodyNodes
  expectOneArgument("set-status", arguments)
  result = env.eval(arguments[0])
  env.set(VarStatus, result)

proc getStatusCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "get-status", raises: [EvaluatorError].} =
  ## The current status bar message.
  discard layout
  discard bodyNodes
  if arguments.len != 0:
    raise newException(EvaluatorError, "get-status expects no arguments")
  env.get(VarStatus)

proc textContainsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "text-contains", raises: [EvaluatorError].} =
  ## Report whether text contains a needle, optionally ignoring case.
  discard layout
  discard bodyNodes
  if arguments.len notin {2, 3}:
    raise newException(EvaluatorError,
        "text-contains expects haystack, needle, and optional ignore-case")
  let haystackValue = env.eval(arguments[0])
  let needleValue = env.eval(arguments[1])
  if haystackValue.kind != Text or needleValue.kind != Text:
    raise newException(EvaluatorError, "text-contains expects text")
  let ignoreCase =
    if arguments.len == 3:
      env.eval(arguments[2]).isTruthy
    else:
      false
  var haystack = haystackValue.text
  var needle = needleValue.text
  if ignoreCase:
    haystack = haystack.toLowerAscii()
    needle = needle.toLowerAscii()
  boolean(needle.len == 0 or haystack.contains(needle))

proc stringCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "string", raises: [EvaluatorError].} =
  ## Concatenate every argument into one piece of text.
  discard layout
  discard bodyNodes
  var output = ""
  for argument in arguments:
    let value = env.eval(argument)
    case value.kind
    of Text:
      output.add value.text
    else:
      output.add $value
  text(output)

proc textColumnCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "text-column", raises: [EvaluatorError].} =
  ## Fit text to a column of so many characters: truncated with an ellipsis
  ## when it is too long, and padded with spaces when it is short unless a
  ## third argument says not to. Lines columns up in a monospaced font.
  discard layout
  discard bodyNodes
  if arguments.len notin {2, 3}:
    raise newException(EvaluatorError,
        "text-column expects text, a width, and an optional pad flag")
  let
    source = env.evalTextArgument(arguments, 0, "text-column")
    width = env.evalNumberArgument(arguments, 1, "text-column").int
    pad =
      if arguments.len == 3: env.eval(arguments[2]).isTruthy
      else: true
  if width <= 0:
    return text("")
  let runes = source.toRunes
  if runes.len > width:
    return text(if width == 1: "…" else: $runes[0 ..< width - 1] & "…")
  if pad:
    text(source & spaces(width - runes.len))
  else:
    text(source)

proc pathNormalizeCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "path-normalize", raises: [EvaluatorError].} =
  ## Expand, absolutise and normalise a path.
  discard layout
  discard bodyNodes
  expectOneArgument("path-normalize", arguments)
  let value = env.eval(arguments[0])
  if value.kind != Text:
    raise newException(EvaluatorError, "path-normalize expects text")
  try:
    text(value.text.expandTilde().absolutePath().normalizedPath())
  except CatchableError as error:
    raise newException(EvaluatorError, error.msg)

proc pathParentCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "path-parent", raises: [EvaluatorError].} =
  ## The directory containing a path.
  discard layout
  discard bodyNodes
  expectOneArgument("path-parent", arguments)
  let value = env.eval(arguments[0])
  if value.kind != Text:
    raise newException(EvaluatorError, "path-parent expects text")
  text(value.text.parentDir)

proc pathBaseNameCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "path-base-name", raises: [EvaluatorError].} =
  ## The final component of a path, extension included.
  discard layout
  discard bodyNodes
  expectOneArgument("path-base-name", arguments)
  let value = env.eval(arguments[0])
  if value.kind != Text:
    raise newException(EvaluatorError, "path-base-name expects text")
  text(value.text.extractFilename)

proc pathStemCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "path-stem", raises: [EvaluatorError].} =
  ## The final component of a path without its extension.
  discard layout
  discard bodyNodes
  expectOneArgument("path-stem", arguments)
  let value = env.eval(arguments[0])
  if value.kind != Text:
    raise newException(EvaluatorError, "path-stem expects text")
  text(value.text.splitFile.name)

proc pathJoinCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "path-join", raises: [EvaluatorError].} =
  ## Join path parts with the platform separator.
  discard layout
  discard bodyNodes
  if arguments.len < 1:
    raise newException(EvaluatorError, "path-join expects path parts")
  var path = ""
  for argument in arguments:
    let value = env.eval(argument)
    if value.kind != Text:
      raise newException(EvaluatorError, "path-join expects text")
    path = if path.len == 0: value.text else: path / value.text
  text(path)

proc fileExistsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "file-exists?", raises: [EvaluatorError].} =
  ## Report whether a file exists at a path.
  discard layout
  discard bodyNodes
  expectOneArgument("file-exists?", arguments)
  let value = env.eval(arguments[0])
  if value.kind != Text:
    raise newException(EvaluatorError, "file-exists? expects text")
  try:
    boolean(fileExists(value.text.expandTilde()))
  except CatchableError as error:
    raise newException(EvaluatorError, error.msg)

proc dirExistsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "dir-exists?", raises: [EvaluatorError].} =
  ## Report whether a directory exists at a path.
  discard layout
  discard bodyNodes
  expectOneArgument("dir-exists?", arguments)
  let value = env.eval(arguments[0])
  if value.kind != Text:
    raise newException(EvaluatorError, "dir-exists? expects text")
  try:
    boolean(dirExists(value.text.expandTilde()))
  except CatchableError as error:
    raise newException(EvaluatorError, error.msg)

proc directoryFilesCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "directory-files", raises: [EvaluatorError].} =
  ## The files directly inside a directory.
  discard layout
  discard bodyNodes
  expectOneArgument("directory-files", arguments)
  let value = env.eval(arguments[0])
  if value.kind != Text:
    raise newException(EvaluatorError, "directory-files expects text")
  try:
    let dir = value.text.expandTilde()
    if not dirExists(dir):
      return list(@[])
    var items: seq[Value]
    for kind, path in walkDir(dir, relative = false):
      if kind == pcFile:
        items.add text(path)
    list(items)
  except CatchableError as error:
    raise newException(EvaluatorError, error.msg)

# ---------------------------------------------------------------------------
# Syntax highlighting definitions
# ---------------------------------------------------------------------------

proc syntaxRule(env: Environment, arguments: seq[SyntaxNode],
    commandID, kind: string, expected: openArray[int]): Value {.raises: [
    EvaluatorError].} =
  var valid = false
  for count in expected:
    if arguments.len == count:
      valid = true
      break
  if not valid:
    raise newException(EvaluatorError, commandID & " got " & $arguments.len &
        " arguments")
  let pattern = env.evalTextArgument(arguments, 0, commandID)
  var stop = ""
  let colorIndex =
    if arguments.len == 3:
      stop = env.evalTextArgument(arguments, 1, commandID)
      2
    else:
      1
  dictionaryValue([
    ("kind", text(kind)),
    ("pattern", text(pattern)),
    ("stop", text(stop)),
    ("color", env.eval(arguments[colorIndex])),
  ])

proc rgbCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "rgb", raises: [EvaluatorError].} =
  ## A colour from red, green, blue and an optional alpha.
  discard layout
  discard bodyNodes
  if arguments.len notin {3, 4}:
    raise newException(EvaluatorError,
        "rgb expects red, green, blue, and optional alpha")
  dictionaryValue([
    ("r", number(env.evalNumberArgument(arguments, 0, "rgb"))),
    ("g", number(env.evalNumberArgument(arguments, 1, "rgb"))),
    ("b", number(env.evalNumberArgument(arguments, 2, "rgb"))),
    ("a", number(if arguments.len == 4:
      env.evalNumberArgument(arguments, 3, "rgb")
    else:
      255.0)),
  ])

proc regexRuleCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "regex", raises: [EvaluatorError].} =
  ## A syntax rule colouring text matching a regular expression.
  discard layout
  discard bodyNodes
  env.syntaxRule(arguments, "regex", "regex", [2])

proc wordRuleCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "word", raises: [EvaluatorError].} =
  ## A syntax rule colouring a whole word.
  discard layout
  discard bodyNodes
  env.syntaxRule(arguments, "word", "word", [2])

proc startsWithRuleCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "starts-with", raises: [EvaluatorError].} =
  ## A syntax rule colouring text from a prefix to the end of the line.
  discard layout
  discard bodyNodes
  env.syntaxRule(arguments, "starts-with", "starts-with", [2])

proc containsRuleCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "contains", raises: [EvaluatorError].} =
  ## A syntax rule colouring any occurrence of a substring.
  discard layout
  discard bodyNodes
  env.syntaxRule(arguments, "contains", "contains", [2])

proc spanRuleCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "span", raises: [EvaluatorError].} =
  ## A syntax rule colouring everything between an opening and closing pattern.
  discard layout
  discard bodyNodes
  env.syntaxRule(arguments, "span", "span", [3])

proc syntaxCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "syntax", raises: [EvaluatorError].} =
  ## A named syntax definition built from a list of rules.
  discard layout
  discard bodyNodes
  if arguments.len != 2:
    raise newException(EvaluatorError, "syntax expects name and rules")
  let name = env.evalTextArgument(arguments, 0, "syntax")
  let rules = env.eval(arguments[1])
  if rules.kind != List:
    raise newException(EvaluatorError, "syntax expects a rule list")
  dictionaryValue([
    ("name", text(name)),
    ("rules", rules),
  ])

# ---------------------------------------------------------------------------
# File explorer, finders and the palette's row builder
# ---------------------------------------------------------------------------

var
  finderCacheRoot = ""
  finderCacheQuery = ""
  finderCacheIgnored: seq[string]
  finderCacheRows: seq[tuple[score: int, path, name, relative: string]]
  previewCachePath = ""
  previewCacheMtime: Time
  previewCacheSize: BiggestInt = -1
  previewCacheText = ""
  finderCacheTruncated = false

proc fileIconModeCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "file-icon-mode", raises: [EvaluatorError].} =
  ## Which icon set the installed fonts can render: "nerd", "unicode" or "ascii".
  discard env
  discard layout
  discard bodyNodes
  if arguments.len != 0:
    raise newException(EvaluatorError, "file-icon-mode expects no arguments")
  text(detectFileIconMode())

proc textListContainsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "text-list-contains?", raises: [EvaluatorError].} =
  ## Report whether a list of text contains an entry.
  discard layout
  discard bodyNodes
  if arguments.len != 2:
    raise newException(EvaluatorError, "text-list-contains? expects list and text")
  let items = env.evalTextListArgument(arguments, 0, "text-list-contains?")
  let target = env.evalTextArgument(arguments, 1, "text-list-contains?")
  boolean(items.textListContains(target))

proc textListToggleCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "text-list-toggle", raises: [EvaluatorError].} =
  ## Add an entry to a list of text, or remove it if it is already there.
  discard layout
  discard bodyNodes
  if arguments.len != 2:
    raise newException(EvaluatorError, "text-list-toggle expects list and text")
  var items = env.evalTextListArgument(arguments, 0, "text-list-toggle")
  let target = env.evalTextArgument(arguments, 1, "text-list-toggle")
  var output: seq[string]
  var removed = false
  for item in items:
    if item == target:
      removed = true
    else:
      output.add item
  if not removed:
    output.add target
  textList(output)

proc rowWindow(total: int, scrollY, viewportHeight: float64,
    rowHeight, overscan: int): tuple[first, stop, before, after: int] {.raises: [].} =
  ## The slice of a uniform-height row list a scrolled viewport shows, plus the
  ## pixel padding standing in for the rows above and below it.
  let
    height = max(rowHeight, 1)
    margin = max(overscan, 0)
  result.first = clamp(
    floor(scrollY / height.float64).int - margin, 0, max(total, 0))
  let count = max(ceil(viewportHeight / height.float64).int + margin * 2, 1)
  result.stop = clamp(result.first + count, result.first, max(total, 0))
  result.before = result.first * height
  result.after = (max(total, 0) - result.stop) * height

proc listWindowCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "list-window", raises: [EvaluatorError].} =
  ## The slice of a list a scrolled viewport shows, as rows, before, after and
  ## total. Any panel whose rows are a uniform height can render just this
  ## slice between two spacers instead of every row.
  discard layout
  discard bodyNodes
  if arguments.len != 5:
    raise newException(EvaluatorError,
        "list-window expects rows, scroll-y, viewport-height, row-height, and overscan")
  let rows = env.eval(arguments[0])
  if rows.kind != List:
    raise newException(EvaluatorError, "list-window expects a list of rows")
  let window = rowWindow(
    rows.listLen,
    env.evalNumberArgument(arguments, 1, "list-window"),
    env.evalNumberArgument(arguments, 2, "list-window"),
    env.evalNumberArgument(arguments, 3, "list-window").int,
    env.evalNumberArgument(arguments, 4, "list-window").int,
  )
  var visible: seq[Value]
  for index in window.first ..< window.stop:
    visible.add rows.at(index)
  dictionaryValue([
    ("rows", list(visible)),
    ("before", number(window.before.float64)),
    ("after", number(window.after.float64)),
    ("total", number(rows.listLen.float64)),
  ])

proc fileTreeVisibleCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "file-tree-visible", raises: [EvaluatorError].} =
  ## The file tree rows a root expands to under the current filters.
  discard layout
  discard bodyNodes
  if arguments.len != 7:
    raise newException(EvaluatorError,
        "file-tree-visible expects root, expanded, selected, query, sort, show-hidden, filter")
  let
    root = env.evalTextArgument(arguments, 0, "file-tree-visible").expandTilde()
    expandedList = env.evalTextListArgument(arguments, 1, "file-tree-visible")
    selectedPath = env.evalTextArgument(arguments, 2, "file-tree-visible")
    query = env.evalTextArgument(arguments, 3, "file-tree-visible")
    sortMode = env.evalTextArgument(arguments, 4, "file-tree-visible")
    showHidden = env.evalBoolArgument(arguments, 5, "file-tree-visible")
    filterMode = env.evalTextArgument(arguments, 6, "file-tree-visible")
    showDirs = filterMode != "files"
    showFiles = filterMode != "directories"
  list(fileTreeRows(root, expandedList, selectedPath, query, sortMode,
      showHidden, showDirs, showFiles))

proc fileTreeWindowCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "file-tree-window", raises: [EvaluatorError].} =
  ## The slice of file tree rows a scrolled viewport needs, with the padding
  ## above and below it.
  discard layout
  discard bodyNodes
  if arguments.len != 11:
    raise newException(EvaluatorError,
        "file-tree-window expects root, expanded, selected, query, sort, show-hidden, filter, scroll-y, viewport-height, row-height, overscan")
  let
    root = env.evalTextArgument(arguments, 0, "file-tree-window").expandTilde()
    expandedList = env.evalTextListArgument(arguments, 1, "file-tree-window")
    selectedPath = env.evalTextArgument(arguments, 2, "file-tree-window")
    query = env.evalTextArgument(arguments, 3, "file-tree-window")
    sortMode = env.evalTextArgument(arguments, 4, "file-tree-window")
    showHidden = env.evalBoolArgument(arguments, 5, "file-tree-window")
    filterMode = env.evalTextArgument(arguments, 6, "file-tree-window")
    scrollY = env.evalNumberArgument(arguments, 7, "file-tree-window")
    viewportHeight = env.evalNumberArgument(arguments, 8, "file-tree-window")
    rowHeight = max(env.evalNumberArgument(arguments, 9, "file-tree-window").int, 1)
    overscan = max(env.evalNumberArgument(arguments, 10, "file-tree-window").int, 0)
    showDirs = filterMode != "files"
    showFiles = filterMode != "directories"
    allRows = fileTreeRows(root, expandedList, selectedPath, query, sortMode,
        showHidden, showDirs, showFiles)
    window = rowWindow(allRows.len, scrollY, viewportHeight, rowHeight, overscan)
  var rows: seq[Value]
  for index in window.first ..< window.stop:
    rows.add allRows[index]
  dictionaryValue([
    ("rows", list(rows)),
    ("before", number(window.before.float64)),
    ("after", number(window.after.float64)),
    ("total", number(allRows.len.float64)),
  ])

proc fileExplorerEventCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "file-explorer-event", raises: [EvaluatorError].} =
  ## Forward a file explorer interaction, with an optional path, to the editor.
  discard layout
  discard bodyNodes
  if arguments.len < 1 or arguments.len > 2:
    raise newException(EvaluatorError,
        "file-explorer-event expects action and optional path")
  let action = env.evalTextArgument(arguments, 0, "file-explorer-event")
  let target =
    if arguments.len == 2:
      env.eval(arguments[1])
    else:
      text("")
  activeBridge.request("file-explorer." & action, [target])
  boolean(true)

proc projectFilesWindowCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "project-files-window", raises: [EvaluatorError].} =
  ## The project files matching a query, ranked, with one row marked selected.
  discard layout
  discard bodyNodes
  if arguments.len notin {2, 3, 4}:
    raise newException(EvaluatorError,
        "project-files-window expects root, query, optional selected path, and optional ignored directories")
  let
    root = env.evalTextArgument(arguments, 0, "project-files-window").expandTilde()
    query = env.evalTextArgument(arguments, 1,
        "project-files-window").toLowerAscii()
    selectedPath =
      if arguments.len >= 3:
        env.evalTextArgument(arguments, 2, "project-files-window")
      else:
        ""
    ignored =
      if arguments.len == 4:
        env.evalTextListArgument(arguments, 3, "project-files-window")
      else:
        @[]
  if not dirExists(root):
    return list(@[])
  if root != finderCacheRoot or query != finderCacheQuery or
      ignored != finderCacheIgnored:
    finderCacheRoot = root
    finderCacheQuery = query
    finderCacheIgnored = ignored
    finderCacheRows.setLen(0)
    var ignoredSet = initHashSet[string]()
    for item in ignored:
      if item.len > 0:
        ignoredSet.incl item
    var scan = FileScan(budget: MaxFinderScanEntries)
    collectProjectFiles(root, root, query, ignoredSet, finderCacheRows, scan)
    finderCacheTruncated = scan.truncated
    finderCacheRows.sort(proc(a, b: tuple[score: int, path, name,
        relative: string]): int =
      result = cmp(b.score, a.score)
      if result != 0:
        return
      result = cmp(a.relative.toLowerAscii(), b.relative.toLowerAscii())
    )
  var rows: seq[Value]
  for index, candidate in finderCacheRows:
    if index >= MaxFinderRows:
      break
    let selected = candidate.path == selectedPath or
      (selectedPath.len == 0 and index == 0)
    rows.add dictionaryValue([
      ("path", text(candidate.path)),
      ("name", text(candidate.name)),
      ("relative", text(candidate.relative)),
      ("selected", boolean(selected)),
    ])
  list(rows)

proc projectFilesTruncatedCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "project-files-truncated?", raises: [EvaluatorError].} =
  ## Whether the last project file scan gave up before seeing the whole tree.
  ## The scan is bounded so a huge root cannot wedge a frame.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("project-files-truncated?", arguments)
  boolean(finderCacheTruncated)

proc filePreviewTextCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "file-preview-text", raises: [EvaluatorError].} =
  ## The leading text of a file, for previewing it without opening it.
  discard layout
  discard bodyNodes
  expectOneArgument("file-preview-text", arguments)
  let path = env.evalTextArgument(arguments, 0, "file-preview-text").expandTilde()
  if path.len == 0 or not fileExists(path):
    return text("")
  try:
    let
      info = getFileInfo(path)
      modified = info.lastWriteTime
      size = getFileSize(path)
    if path == previewCachePath and modified == previewCacheMtime and
        size == previewCacheSize:
      return text(previewCacheText)
    var stream = openFileStream(path, fmRead)
    if stream.isNil:
      return text("")
    defer: stream.close()
    previewCachePath = path
    previewCacheMtime = modified
    previewCacheSize = size
    previewCacheText = stream.readStr(MaxPreviewBytes)
    text(previewCacheText)
  except CatchableError as error:
    raise newException(EvaluatorError, error.msg)

proc recordField(value: Value, name: string): Value {.raises: [].} =
  case value.kind
  of Record:
    value.recordEntries.getOrDefault(name)
  of Dictionary:
    value.entries.getOrDefault(name)
  else:
    nothing()

proc keyBindingStroke(binding: Value): string {.raises: [].} =
  if recordField(binding, "ctrl").isTruthy: result.add "Ctrl+"
  if recordField(binding, "alt").isTruthy: result.add "Alt+"
  if recordField(binding, "shift").isTruthy: result.add "Shift+"
  if recordField(binding, "gui").isTruthy: result.add "Meta+"
  let key = recordField(binding, "key")
  if key.kind == Text:
    result.add key.text

proc collectKeybindingLabels(bindings: Value, prefix: string,
    labels: var OrderedTable[string, string]) {.raises: [].} =
  ## Walk a keymap once, recording the chord that reaches each command id.
  if bindings.kind != List:
    return
  for binding in bindings.items:
    let stroke = keyBindingStroke(binding)
    let chord = if prefix.len == 0: stroke else: prefix & " " & stroke
    let id = recordField(binding, "commandID")
    if id.kind == Text and id.text.len > 0:
      if id.text in labels:
        labels[id.text] = labels.getOrDefault(id.text) & ", " & chord
      else:
        labels[id.text] = chord
    collectKeybindingLabels(recordField(binding, "children"), chord, labels)

proc keybindingLabelsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "keybinding-labels", raises: [EvaluatorError].} =
  ## Map each command id in the given keymaps to the keys that reach it.
  discard layout
  discard bodyNodes
  if arguments.len == 0:
    raise newException(EvaluatorError, "keybinding-labels expects a keymap")
  var labels: OrderedTable[string, string]
  for argument in arguments:
    collectKeybindingLabels(env.eval(argument), "", labels)
  var entries = initTable[string, Value]()
  for id, label in labels:
    entries[id] = text(label)
  dictionary(entries)

proc commandKeybindingLabelCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "command-keybinding-label", raises: [EvaluatorError].} =
  ## The keys that reach a command id in a keybinding-labels map, or "" when
  ## nothing is bound to it.
  discard layout
  discard bodyNodes
  if arguments.len != 2:
    raise newException(EvaluatorError,
        "command-keybinding-label expects a label map and a command id")
  let labels = env.eval(arguments[0])
  let id = env.evalTextArgument(arguments, 1, "command-keybinding-label")
  if labels.kind != Dictionary:
    raise newException(EvaluatorError,
        "command-keybinding-label expects a label map")
  let label = labels.entries.getOrDefault(id)
  if label.kind == Text: label else: text("")

proc commandGenerationCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "command-generation", raises: [EvaluatorError].} =
  ## A number that changes whenever a command is defined or redefined. Include
  ## it in a cache key to notice a script adding commands.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("command-generation", arguments)
  number(commandGeneration().float64)

proc commandIdOfCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "command-id-of", raises: [EvaluatorError].} =
  ## The command id a value names, or "" when the value is a callable rather
  ## than an id.
  discard layout
  discard bodyNodes
  if arguments.len != 1:
    raise newException(EvaluatorError, "command-id-of expects one value")
  let value = env.eval(arguments[0])
  if value.kind == Text: value else: text("")

proc commandPaletteRowsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "command-palette-rows", raises: [EvaluatorError].} =
  ## Palette rows for a list of commands, ranked against a query, with one row
  ## marked selected.
  discard layout
  discard bodyNodes
  if arguments.len notin {2, 3}:
    raise newException(EvaluatorError,
        "command-palette-rows expects commands, query, and optional selected id")
  let
    candidates = env.eval(arguments[0])
    query = env.evalTextArgument(arguments, 1,
        "command-palette-rows").toLowerAscii()
    selectedID =
      if arguments.len == 3:
        env.evalTextArgument(arguments, 2, "command-palette-rows")
      else:
        ""
  if candidates.kind != List:
    raise newException(EvaluatorError, "command-palette-rows expects a list")
  var ranked: seq[tuple[score: int, id: string, row: Value]]
  for row in candidates.items:
    if row.kind != Dictionary:
      continue
    let searchable = (
      row.dictionaryText("id") & " " &
      row.dictionaryText("description") & " " &
      row.dictionaryText("keybindings")
    ).toLowerAscii()
    if not matchesFuzzy(searchable, query):
      continue
    ranked.add((fuzzyScore(searchable, query), row.dictionaryText("id"), row))
  ranked.sort(proc(a, b: tuple[score: int, id: string, row: Value]): int =
    result = cmp(b.score, a.score)
    if result != 0:
      return
    result = cmp(a.id.toLowerAscii(), b.id.toLowerAscii())
  )
  var rows: seq[Value]
  for index, candidate in ranked:
    if index >= MaxFinderRows:
      break
    var row = candidate.row
    row.entries["selected"] = boolean(
      row.dictionaryText("id") == selectedID or
      (selectedID.len == 0 and index == 0)
    )
    rows.add row
  list(rows)

# ---------------------------------------------------------------------------
# Editor movement and editing
#
# The primitives the input drivers bind to. These read editor state before
# deciding what to send; the passthrough table above covers the rest.
# ---------------------------------------------------------------------------

proc editorSetCursorCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "editor-set-cursor", raises: [EvaluatorError].} =
  ## Move the cursor to a character offset.
  discard layout
  discard bodyNodes
  if arguments.len != 1:
    raise newException(EvaluatorError, "editor-set-cursor expects an offset")
  activeBridge.request("active-editor.command", [
    text("set-cursor"),
    number(env.evalNumberArgument(arguments, 0, "editor-set-cursor")),
  ])
  boolean(true)

proc editorSetSelectionCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "editor-set-selection", raises: [EvaluatorError].} =
  ## Select the text between two character offsets.
  discard layout
  discard bodyNodes
  if arguments.len != 2:
    raise newException(EvaluatorError,
        "editor-set-selection expects start and stop")
  activeBridge.request("active-editor.command", [
    text("set-selection"),
    number(env.evalNumberArgument(arguments, 0, "editor-set-selection")),
    number(env.evalNumberArgument(arguments, 1, "editor-set-selection")),
  ])
  boolean(true)

proc editorInsertCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "editor-insert", raises: [EvaluatorError].} =
  ## Insert text at the cursor.
  discard layout
  discard bodyNodes
  if arguments.len != 1:
    raise newException(EvaluatorError, "editor-insert expects text")
  activeBridge.request("active-editor.command", [
    text("insert"),
    text(env.evalTextArgument(arguments, 0, "editor-insert")),
  ])
  boolean(true)

proc setActiveEditorDriverCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideCommand: "set-active-editor-driver", raises: [EvaluatorError].} =
  ## Hand the active editor's key handling to a named input driver.
  discard layout
  discard bodyNodes
  if arguments.len != 1:
    raise newException(EvaluatorError,
        "set-active-editor-driver expects a driver name")
  activeBridge.request("active-editor.command", [
    text("set-input-driver"),
    text(env.evalTextArgument(arguments, 0, "set-active-editor-driver")),
  ])
  boolean(true)

proc editorBackwardCharCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-backward-char", raises: [EvaluatorError].} =
  ## Move the cursor back one character.
  discard layout
  discard bodyNodes
  expectNoArguments("editor-backward-char", arguments)
  let cursor = env.stateNumber("active-editor-cursor")
  if cursor > 0:
    activeBridge.request("active-editor.command", [
      text("set-cursor"), number(cursor - 1)])
  boolean(true)

proc editorForwardCharCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-forward-char", raises: [EvaluatorError].} =
  ## Move the cursor forward one character.
  discard layout
  discard bodyNodes
  expectNoArguments("editor-forward-char", arguments)
  let cursor = env.stateNumber("active-editor-cursor")
  if cursor < env.stateNumber("active-editor-text-length"):
    activeBridge.request("active-editor.command", [
      text("set-cursor"), number(cursor + 1)])
  boolean(true)

proc editorPreviousLineCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-previous-line", raises: [EvaluatorError].} =
  ## Move the cursor up one line, keeping the column.
  discard layout
  discard bodyNodes
  expectNoArguments("editor-previous-line", arguments)
  activeBridge.request("active-editor.command", [
    text("set-line-column"),
    number(env.stateNumber("active-editor-line") - 1),
    number(env.stateNumber("active-editor-column")),
  ])
  boolean(true)

proc editorNextLineCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-next-line", raises: [EvaluatorError].} =
  ## Move the cursor down one line, keeping the column.
  discard layout
  discard bodyNodes
  expectNoArguments("editor-next-line", arguments)
  activeBridge.request("active-editor.command", [
    text("set-line-column"),
    number(env.stateNumber("active-editor-line") + 1),
    number(env.stateNumber("active-editor-column")),
  ])
  boolean(true)

proc editorLineStartCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-line-start", raises: [EvaluatorError].} =
  ## Move the cursor to the start of the current line.
  discard layout
  discard bodyNodes
  expectNoArguments("editor-line-start", arguments)
  activeBridge.request("active-editor.command", [
    text("set-line-column"),
    number(env.stateNumber("active-editor-line")),
    number(1),
  ])
  boolean(true)

proc editorLineEndCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-line-end", raises: [EvaluatorError].} =
  ## Move the cursor to the end of the current line.
  discard layout
  discard bodyNodes
  expectNoArguments("editor-line-end", arguments)
  activeBridge.request("active-editor.command", [
    text("set-line-column"),
    number(env.stateNumber("active-editor-line")),
    number(100000000),
  ])
  boolean(true)

proc editorBufferStartCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-buffer-start", raises: [EvaluatorError].} =
  ## Move the cursor to the start of the buffer.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("editor-buffer-start", arguments)
  activeBridge.request("active-editor.command", [text("set-cursor"), number(0)])
  boolean(true)

proc editorBufferEndCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-buffer-end", raises: [EvaluatorError].} =
  ## Move the cursor to the end of the buffer.
  discard layout
  discard bodyNodes
  expectNoArguments("editor-buffer-end", arguments)
  activeBridge.request("active-editor.command", [
    text("set-cursor"),
    number(env.stateNumber("active-editor-text-length")),
  ])
  boolean(true)

proc editorMarkCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-mark", raises: [EvaluatorError].} =
  ## Start a selection at the cursor.
  discard layout
  discard bodyNodes
  expectNoArguments("editor-mark", arguments)
  let cursor = env.stateNumber("active-editor-cursor")
  activeBridge.request("active-editor.command", [
    text("set-selection"), number(cursor), number(cursor)])
  boolean(true)

proc editorNewlineCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "editor-newline", raises: [EvaluatorError].} =
  ## Insert a newline at the cursor.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("editor-newline", arguments)
  activeBridge.request("active-editor.command", [text("insert"), text("\n")])
  boolean(true)

proc setEditorLineCursorCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "set-editor-line-cursor", raises: [EvaluatorError].} =
  ## Draw the active editor's cursor as a line.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("set-editor-line-cursor", arguments)
  activeBridge.request("active-editor.command", [
    text("set-cursor-style"), text("line")])
  boolean(true)

proc setEditorBlockCursorCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "set-editor-block-cursor", raises: [EvaluatorError].} =
  ## Draw the active editor's cursor as a block.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("set-editor-block-cursor", arguments)
  activeBridge.request("active-editor.command", [
    text("set-cursor-style"), text("block")])
  boolean(true)

# ---------------------------------------------------------------------------
# Files, panels and projects
# ---------------------------------------------------------------------------

proc fileNewCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "file-new", raises: [EvaluatorError].} =
  ## Create a new file.
  discard layout
  discard bodyNodes
  expectNoArguments("file-new", arguments)
  env.requestAction(ActionNewFile)
  boolean(true)

proc fileOpenCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "file-open", raises: [EvaluatorError].} =
  ## Open a file using the system file dialog.
  discard layout
  discard bodyNodes
  expectNoArguments("file-open", arguments)
  env.requestAction(ActionOpenFileDialog)
  boolean(true)

proc findFileCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "find-file", raises: [EvaluatorError].} =
  ## Open the file finder.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("find-file", arguments)
  activeBridge.request("panel.open-floating", [text("find-file")])
  boolean(true)

proc findBufferCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "find-buffer", raises: [EvaluatorError].} =
  ## Open the buffer finder.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("find-buffer", arguments)
  activeBridge.request("panel.open-floating", [text("find-buffer")])
  boolean(true)

proc bufferOpenCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "buffer-open", raises: [EvaluatorError].} =
  ## Open the buffer switcher.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("buffer-open", arguments)
  activeBridge.request("panel.open-floating", [text("find-buffer")])
  boolean(true)

proc commandPaletteCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "command-palette", raises: [EvaluatorError].} =
  ## Open the command palette.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("command-palette", arguments)
  activeBridge.request("panel.open-floating", [text("command-palette")])
  boolean(true)

proc fileSaveCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "file-save", raises: [EvaluatorError].} =
  ## Save the active buffer.
  discard layout
  discard bodyNodes
  expectNoArguments("file-save", arguments)
  let path = env.stateField("active-buffer-path")
  if path.len == 0:
    env.requestAction(ActionSaveFileAsDialog)
    return boolean(true)
  try:
    let content = env.stateField("active-buffer-text")
    var stream = openFileStream(path, fmWrite)
    if stream.isNil:
      raise newException(IOError, "could not open " & path)
    defer: stream.close()
    stream.write(content)
    env.requestAction(ActionMarkBufferSaved)
    env.set(VarStatus, text("Saved " & path))
    boolean(true)
  except CatchableError as error:
    raise newException(EvaluatorError, error.msg)

proc fileSaveAsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "file-save-as", raises: [EvaluatorError].} =
  ## Save the active buffer to a new path.
  discard layout
  discard bodyNodes
  expectNoArguments("file-save-as", arguments)
  env.requestAction(ActionSaveFileAsDialog)
  boolean(true)

proc projectRunCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "project-run", raises: [EvaluatorError].} =
  ## Run the active project.
  discard layout
  discard bodyNodes
  expectNoArguments("project-run", arguments)
  env.set(VarStatus, text("Run project is not implemented"))
  boolean(true)

proc projectBuildCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "project-build", raises: [EvaluatorError].} =
  ## Build the active project.
  discard layout
  discard bodyNodes
  expectNoArguments("project-build", arguments)
  env.set(VarStatus, text("Build project is not implemented"))
  boolean(true)

proc projectSettingsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "project-settings", raises: [EvaluatorError].} =
  ## Open project settings.
  discard layout
  discard bodyNodes
  expectNoArguments("project-settings", arguments)
  env.set(VarStatus, text("Project settings are not implemented"))
  boolean(true)

proc toggleProjectsPanelCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "toggle-projects-panel", raises: [EvaluatorError].} =
  ## Toggle the projects panel.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("toggle-projects-panel", arguments)
  activeBridge.request("panel.toggle", [text("projects")])
  boolean(true)

proc toggleFileExplorerPanelCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    bodyNodes: seq[SyntaxNode],
): Value {.nideAction: "toggle-file-explorer-panel", raises: [EvaluatorError].} =
  ## Toggle the file explorer panel.
  discard env
  discard layout
  discard bodyNodes
  expectNoArguments("toggle-file-explorer-panel", arguments)
  activeBridge.request("panel.toggle", [text("files")])
  boolean(true)

# ---------------------------------------------------------------------------

proc registerInternalCommands*(evaluator: var Evaluator,
    bridge: NideOwlBridge = nil) =
  ## Hand every registered command to Owl under the `nide` module. The set is
  ## whatever registered itself as this module loaded.
  activeBridge = bridge
  var nide = nativeModule"nide"
  nide.define "version", text"0.0.0"
  nide.defineRegisteredCommands()
  evaluator.registerModule(nide)
