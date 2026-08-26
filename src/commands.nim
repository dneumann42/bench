# Low-level native bindings and environment helpers for Nide's Owl command layer.

import std/[algorithm, math, os, sets, streams, strutils, tables, sugar, times]
import owl

const
  ActionNewFile* = "new-file"
  ActionOpenFileDialog* = "open-file-dialog"
  ActionSaveFileAsDialog* = "save-file-as-dialog"
  ActionMarkBufferSaved* = "mark-buffer-saved"
  ActionToggleProjectsPanel* = "toggle-projects-panel"
  ActionToggleFileExplorerPanel* = "toggle-file-explorer-panel"
  MaxFinderRows = 400
  MaxPreviewBytes = 200_000

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

proc requestAction(env: Environment, bridge: NideOwlBridge, action: string) =
  if not bridge.isNil:
    bridge.request(action)
    return
  var actions =
    if env.contains(VarRequestedActions):
      env.get(VarRequestedActions)
    else:
      list(@[])
  if actions.kind != List:
    raise newException(EvaluatorError, VarRequestedActions & " must be a list")
  actions.items.add text(action)
  env.set(VarRequestedActions, actions)

proc defineRequestAction(module: var NativeModule, bridge: NideOwlBridge) =
  module.defineNative("request-action", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    expectOneArgument("request-action", arguments)
    let action = env.eval(arguments[0])
    if action.kind != Text:
      raise newException(EvaluatorError, "request-action expects text")
    env.requestAction(bridge, action.text)
    boolean(true)
  )

proc defineSetter(module: var NativeModule, commandID, variable: string) =
  module.defineNative(commandID, proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    expectOneArgument(commandID, arguments)
    result = env.eval(arguments[0])
    env.set(variable, result)
  )

proc defineGetter(module: var NativeModule, commandID, variable: string) =
  module.defineNative(commandID, proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, commandID & " expects no arguments")
    env.get(variable)
  )

proc defineTextContains(module: var NativeModule) =
  module.defineNative("text-contains", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

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

proc defineCommand(module: var NativeModule, commandID, description: string,
    implementation: NativeCommand) =
  module.define(commandID, nativeCommand(implementation, id = commandID,
      description = description, interactive = true))

proc defineBridgeRequest(module: var NativeModule, commandID,
    requestName: string,

bridge: NideOwlBridge, expectedArgumentCounts: openArray[int], description = "",
    interactive = false) =
  let counts = @expectedArgumentCounts
  let implementation = proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    var valid = false
    for count in counts:
      if arguments.len == count:
        valid = true
        break
    if not valid:
      raise newException(EvaluatorError, commandID & " got " &
          $arguments.len & " arguments")
    var values: seq[Value]
    for argument in arguments:
      values.add env.eval(argument)
    bridge.request(requestName, values)
    boolean(true)
  if interactive:
    module.define(commandID, nativeCommand(implementation, id = commandID,
        description = description, interactive = true))
  else:
    module.defineNative(commandID, implementation)

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

proc collectProjectFiles(
    root, baseRoot, query: string,
    ignoredDirs: HashSet[string],
    rows: var seq[tuple[score: int, path, name, relative: string]],
) =
  try:
    for kind, path in walkDir(root, relative = false):
      let name = path.extractFilename
      if name.len == 0:
        continue
      if kind == pcDir:
        if name in ignoredDirs:
          continue
        collectProjectFiles(path, baseRoot, query, ignoredDirs, rows)
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

proc defineFileExplorerCommands(module: var NativeModule,
    bridge: NideOwlBridge) =
  var
    finderCacheRoot = ""
    finderCacheQuery = ""
    finderCacheIgnored: seq[string]
    finderCacheRows: seq[tuple[score: int, path, name, relative: string]]
    previewCachePath = ""
    previewCacheMtime: Time
    previewCacheSize: BiggestInt = -1
    previewCacheText = ""

  module.defineNative("file-icon-mode", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "file-icon-mode expects no arguments")
    text(detectFileIconMode())
  )

  module.defineNative("text-list-contains?", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 2:
      raise newException(EvaluatorError, "text-list-contains? expects list and text")
    let items = env.evalTextListArgument(arguments, 0, "text-list-contains?")
    let target = env.evalTextArgument(arguments, 1, "text-list-contains?")
    boolean(items.textListContains(target))
  )

  module.defineNative("text-list-toggle", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

  module.defineNative("file-tree-visible", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 7:
      raise newException(EvaluatorError,
          "file-tree-visible expects root, expanded, selected, query, sort, show-hidden, filter")
    let
      root = env.evalTextArgument(arguments, 0,
          "file-tree-visible").expandTilde()
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
  )

  module.defineNative("file-tree-window", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 11:
      raise newException(EvaluatorError,
          "file-tree-window expects root, expanded, selected, query, sort, show-hidden, filter, scroll-y, viewport-height, row-height, overscan")
    let
      root = env.evalTextArgument(arguments, 0,
          "file-tree-window").expandTilde()
      expandedList = env.evalTextListArgument(arguments, 1, "file-tree-window")
      selectedPath = env.evalTextArgument(arguments, 2, "file-tree-window")
      query = env.evalTextArgument(arguments, 3, "file-tree-window")
      sortMode = env.evalTextArgument(arguments, 4, "file-tree-window")
      showHidden = env.evalBoolArgument(arguments, 5, "file-tree-window")
      filterMode = env.evalTextArgument(arguments, 6, "file-tree-window")
      scrollY = env.evalNumberArgument(arguments, 7, "file-tree-window")
      viewportHeight = env.evalNumberArgument(arguments, 8, "file-tree-window")
      rowHeight = max(env.evalNumberArgument(arguments, 9,
          "file-tree-window").int, 1)
      overscan = max(env.evalNumberArgument(arguments, 10,
          "file-tree-window").int, 0)
      showDirs = filterMode != "files"
      showFiles = filterMode != "directories"
      allRows = fileTreeRows(root, expandedList, selectedPath, query, sortMode,
          showHidden, showDirs, showFiles)
      total = allRows.len
      first = max(floor(scrollY / rowHeight.float64).int - overscan, 0)
      count = max(ceil(viewportHeight / rowHeight.float64).int + overscan * 2, 1)
      stop = min(first + count, total)
    var rows: seq[Value]
    for index in first ..< stop:
      rows.add allRows[index]
    dictionaryValue([
      ("rows", list(rows)),
      ("before", number((first * rowHeight).float64)),
      ("after", number(((total - stop) * rowHeight).float64)),
      ("total", number(total.float64)),
    ])
  )

  module.defineNative("file-explorer-event", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len < 1 or arguments.len > 2:
      raise newException(EvaluatorError, "file-explorer-event expects action and optional path")
    let action = env.evalTextArgument(arguments, 0, "file-explorer-event")
    let target =
      if arguments.len == 2:
        env.eval(arguments[1])
      else:
        text("")
    bridge.request("file-explorer." & action, [target])
    boolean(true)
  )

  module.defineNative("project-files-window", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len notin {2, 3, 4}:
      raise newException(EvaluatorError,
          "project-files-window expects root, query, optional selected path, and optional ignored directories")
    let
      root = env.evalTextArgument(arguments, 0,
          "project-files-window").expandTilde()
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
      collectProjectFiles(root, root, query, ignoredSet, finderCacheRows)
      finderCacheRows.sort(proc(a, b: tuple[score: int, path, name, relative: string]): int =
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
  )

  module.defineNative("file-preview-text", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

  module.defineNative("command-palette-rows", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len notin {2, 3}:
      raise newException(EvaluatorError,
          "command-palette-rows expects commands, query, and optional selected id")
    let
      commands = env.eval(arguments[0])
      query = env.evalTextArgument(arguments, 1, "command-palette-rows").toLowerAscii()
      selectedID =
        if arguments.len == 3:
          env.evalTextArgument(arguments, 2, "command-palette-rows")
        else:
          ""
    if commands.kind != List:
      raise newException(EvaluatorError, "command-palette-rows expects a list")
    var ranked: seq[tuple[score: int, id: string, row: Value]]
    for row in commands.items:
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
  )

proc defineStringCommand(module: var NativeModule) =
  module.defineNative("string", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

proc defineSyntaxCommands(module: var NativeModule) =
  module.defineNative("rgb", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len notin {3, 4}:
      raise newException(EvaluatorError, "rgb expects red, green, blue, and optional alpha")
    dictionaryValue([
      ("r", number(env.evalNumberArgument(arguments, 0, "rgb"))),
      ("g", number(env.evalNumberArgument(arguments, 1, "rgb"))),
      ("b", number(env.evalNumberArgument(arguments, 2, "rgb"))),
      ("a", number(if arguments.len == 4:
        env.evalNumberArgument(arguments, 3, "rgb")
      else:
        255.0)),
    ])
  )

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

  module.defineNative("regex", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    env.syntaxRule(arguments, "regex", "regex", [2])
  )

  module.defineNative("word", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    env.syntaxRule(arguments, "word", "word", [2])
  )

  module.defineNative("starts-with", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    env.syntaxRule(arguments, "starts-with", "starts-with", [2])
  )

  module.defineNative("contains", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    env.syntaxRule(arguments, "contains", "contains", [2])
  )

  module.defineNative("span", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    env.syntaxRule(arguments, "span", "span", [3])
  )

  module.defineNative("syntax", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

proc defineBridgeGetter(module: var NativeModule, commandID, getterName: string,
    bridge: NideOwlBridge) =
  module.defineNative(commandID, proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, commandID & " expects no arguments")
    bridge.bridgeGet(getterName)
  )

proc defineFileSystemCommands(module: var NativeModule) =
  module.defineNative("path-normalize", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

  module.defineNative("path-parent", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    expectOneArgument("path-parent", arguments)
    let value = env.eval(arguments[0])
    if value.kind != Text:
      raise newException(EvaluatorError, "path-parent expects text")
    text(value.text.parentDir)
  )

  module.defineNative("path-base-name", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    expectOneArgument("path-base-name", arguments)
    let value = env.eval(arguments[0])
    if value.kind != Text:
      raise newException(EvaluatorError, "path-base-name expects text")
    text(value.text.extractFilename)
  )

  module.defineNative("path-stem", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    expectOneArgument("path-stem", arguments)
    let value = env.eval(arguments[0])
    if value.kind != Text:
      raise newException(EvaluatorError, "path-stem expects text")
    text(value.text.splitFile.name)
  )

  module.defineNative("path-join", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

  module.defineNative("file-exists?", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

  module.defineNative("dir-exists?", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

  module.defineNative("directory-files", proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
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
  )

proc registerInternalCommands*(evaluator: var Evaluator,
    bridge: NideOwlBridge = nil) =
  var nide = nativeModule"nide"
  nide.define "version", text"0.0.0"
  nide.defineRequestAction(bridge)
  nide.defineSetter("set-status", VarStatus)
  nide.defineGetter("get-status", VarStatus)
  nide.defineBridgeGetter("get-project-manager", "project-manager", bridge)
  nide.defineBridgeGetter("get-projects", "projects", bridge)
  nide.defineBridgeGetter("get-project-profile-templates",
      "project-profile-templates", bridge)
  nide.defineBridgeGetter("get-active-project", "active-project", bridge)
  nide.defineBridgeGetter("get-active-project-path", "active-project-path", bridge)
  nide.defineBridgeGetter("get-home-directory", "home-directory", bridge)
  nide.defineBridgeGetter("get-panels", "panels", bridge)
  nide.defineBridgeGetter("get-floating-activation-generation",
      "floating-activation-generation", bridge)
  nide.defineBridgeGetter("get-buffers", "buffers", bridge)
  nide.defineBridgeGetter("get-buffer-preview-text", "buffer-preview-text", bridge)
  nide.defineBridgeGetter("get-current-mode", "active-buffer-mode", bridge)
  nide.defineBridgeGetter("get-active-buffer-id", "active-buffer-id", bridge)
  nide.defineBridgeGetter("get-active-buffer-path", "active-buffer-path", bridge)
  nide.defineBridgeGetter("get-active-editor-text-length",
      "active-editor-text-length", bridge)
  nide.defineBridgeGetter("get-active-editor-cursor", "active-editor-cursor", bridge)
  nide.defineBridgeGetter("get-active-editor-line", "active-editor-line", bridge)
  nide.defineBridgeGetter("get-active-editor-column", "active-editor-column", bridge)
  nide.defineBridgeGetter("get-active-editor-selection-start",
      "active-editor-selection-start", bridge)
  nide.defineBridgeGetter("get-active-editor-selection-stop",
      "active-editor-selection-stop", bridge)
  nide.defineBridgeGetter("get-active-editor-has-selection",
      "active-editor-has-selection", bridge)
  nide.defineBridgeGetter("get-active-editor-selected-text",
      "active-editor-selected-text", bridge)
  nide.defineBridgeGetter("get-active-editor-input-driver",
      "active-editor-input-driver", bridge)
  nide.defineBridgeGetter("get-active-editor-cursor-style",
      "active-editor-cursor-style", bridge)
  nide.defineBridgeGetter("auto-track-opened-projects",
      "auto-track-opened-projects", bridge)
  nide.defineBridgeGetter("open-build-launch-tab", "open-build-launch-tab", bridge)
  nide.defineBridgeGetter("open-run-launch-tab", "open-run-launch-tab", bridge)
  nide.defineBridgeGetter("open-check-launch-tab", "open-check-launch-tab", bridge)
  nide.defineCommand("file-new", "Create a new file.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "file-new expects no arguments")
    env.requestAction(bridge, ActionNewFile)
    boolean(true)
  )
  nide.defineCommand("file-open", "Open a file using the system file dialog.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "file-open expects no arguments")
    env.requestAction(bridge, ActionOpenFileDialog)
    boolean(true)
  )
  nide.defineCommand("find-file", "Open the file finder.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "find-file expects no arguments")
    bridge.request("panel.open-floating", [text("find-file")])
    boolean(true)
  )
  nide.defineCommand("find-buffer", "Open the buffer finder.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "find-buffer expects no arguments")
    bridge.request("panel.open-floating", [text("find-buffer")])
    boolean(true)
  )
  nide.defineCommand("buffer-open", "Open the buffer switcher.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "buffer-open expects no arguments")
    bridge.request("panel.open-floating", [text("find-buffer")])
    boolean(true)
  )
  nide.defineCommand("command-palette", "Open the command palette.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "command-palette expects no arguments")
    bridge.request("panel.open-floating", [text("command-palette")])
    boolean(true)
  )
  nide.defineCommand("file-save", "Save the active buffer.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "file-save expects no arguments")
    let path = env.stateField("active-buffer-path")
    if path.len == 0:
      env.requestAction(bridge, ActionSaveFileAsDialog)
      return boolean(true)
    try:
      let content = env.stateField("active-buffer-text")
      var stream = openFileStream(path, fmWrite)
      if stream.isNil:
        raise newException(IOError, "could not open " & path)
      defer: stream.close()
      stream.write(content)
      env.requestAction(bridge, ActionMarkBufferSaved)
      env.set(VarStatus, text("Saved " & path))
      boolean(true)
    except CatchableError as error:
      raise newException(EvaluatorError, error.msg)
  )
  nide.defineCommand("file-save-as", "Save the active buffer to a new path.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "file-save-as expects no arguments")
    env.requestAction(bridge, ActionSaveFileAsDialog)
    boolean(true)
  )
  nide.defineBridgeRequest("project-open", "project.pick-directory", bridge, [0],
      description = "Open a project directory.", interactive = true)
  nide.defineCommand("project-run", "Run the active project.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "project-run expects no arguments")
    env.set(VarStatus, text("Run project is not implemented"))
    boolean(true)
  )
  nide.defineCommand("project-build", "Build the active project.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "project-build expects no arguments")
    env.set(VarStatus, text("Build project is not implemented"))
    boolean(true)
  )
  nide.defineCommand("project-settings", "Open project settings.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "project-settings expects no arguments")
    env.set(VarStatus, text("Project settings are not implemented"))
    boolean(true)
  )
  nide.defineCommand("toggle-projects-panel", "Toggle the projects panel.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "toggle-projects-panel expects no arguments")
    bridge.request("panel.toggle", [text("projects")])
    boolean(true)
  )
  nide.defineCommand("toggle-file-explorer-panel",
      "Toggle the file explorer panel.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError,
          "toggle-file-explorer-panel expects no arguments")
    bridge.request("panel.toggle", [text("files")])
    boolean(true)
  )
  nide.defineBridgeRequest("pane-split-column", "pane.split-column", bridge, [0],
      description = "Split the current pane into columns.", interactive = true)
  nide.defineBridgeRequest("pane-split-row", "pane.split-row", bridge, [0],
      description = "Split the current pane into rows.", interactive = true)
  nide.defineBridgeRequest("pane-unsplit", "pane.unsplit", bridge, [0],
      description = "Remove the current pane split.", interactive = true)
  nide.defineCommand("editor-line-start",
      "Move the cursor to the start of the current line.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "editor-line-start expects no arguments")
    bridge.request("active-editor.command", [
      text("set-line-column"),
      number(env.stateNumber("active-editor-line")),
      number(1),
    ])
    boolean(true)
  )
  nide.defineCommand("editor-line-end",
      "Move the cursor to the end of the current line.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "editor-line-end expects no arguments")
    bridge.request("active-editor.command", [
      text("set-line-column"),
      number(env.stateNumber("active-editor-line")),
      number(100000000),
    ])
    boolean(true)
  )
  nide.defineCommand("editor-buffer-start", "Move the cursor to the start of the buffer.",
      proc(env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "editor-buffer-start expects no arguments")
    bridge.request("active-editor.command", [text("set-cursor"), number(0)])
    boolean(true)
  )
  nide.defineCommand("editor-buffer-end", "Move the cursor to the end of the buffer.",
      proc(env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "editor-buffer-end expects no arguments")
    bridge.request("active-editor.command", [
      text("set-cursor"),
      number(env.stateNumber("active-editor-text-length")),
    ])
    boolean(true)
  )
  for (id, editorCommand, description) in [
    ("editor-forward-word", "word-forward", "Move the cursor forward by one word."),
    ("editor-backward-word", "word-backward", "Move the cursor backward by one word."),
    ("editor-delete-word-forward", "delete-word-forward", "Delete the word after the cursor."),
    ("editor-delete-word-backward", "delete-word-backward", "Delete the word before the cursor."),
    ("editor-delete-backward", "delete-backward", "Delete the character before the cursor."),
    ("editor-delete-forward", "delete-forward", "Delete the character after the cursor."),
    ("editor-select-all", "select-all", "Select the entire buffer."),
    ("editor-copy", "copy-selection", "Copy the current selection."),
    ("editor-cut", "cut-selection", "Cut the current selection."),
    ("editor-paste", "paste-clipboard", "Paste from the clipboard."),
    ("editor-undo", "undo", "Undo the last editor change."),
    ("editor-redo", "redo", "Redo the last undone editor change."),
  ]:
    nide.defineCommand(id, description, proc(
        env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
        bodyNodes: seq[SyntaxNode],
    ): Value {.closure, raises: [EvaluatorError].} =
      discard env
      discard layout
      discard bodyNodes
      if arguments.len != 0:
        raise newException(EvaluatorError, id & " expects no arguments")
      bridge.request("active-editor.command", [text(editorCommand)])
      boolean(true)
    )
  nide.defineCommand("editor-newline", "Insert a newline.", proc(
      env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "editor-newline expects no arguments")
    bridge.request("active-editor.command", [text("insert"), text("\n")])
    boolean(true)
  )
  nide.defineBridgeRequest("open-project", "project.open", bridge, [1])
  nide.defineBridgeRequest("pick-project-directory", "project.pick-directory",
      bridge, [0])
  nide.defineBridgeRequest("add-project", "project.add", bridge, [2])
  nide.defineBridgeRequest("save-project-profile", "project.profile.save",
      bridge, [7])
  nide.defineBridgeRequest("run-project-profile", "project.profile.run",
      bridge, [3])
  nide.defineBridgeRequest("set-process-launch-tab", "process.launch-tab.set",
      bridge, [2])
  nide.defineBridgeRequest("unload-project", "project.unload", bridge, [0])
  nide.defineBridgeRequest("reload-projects", "projects.reload", bridge, [0])
  nide.defineBridgeRequest("save-projects", "projects.save", bridge, [0])
  nide.defineBridgeRequest("set-nide-status", "status.set", bridge, [1])
  nide.defineBridgeRequest("toggle-panel", "panel.toggle", bridge, [1])
  nide.defineBridgeRequest("open-floating-panel", "panel.open-floating", bridge, [1])
  nide.defineBridgeRequest("float-panel", "panel.float", bridge, [1])
  nide.defineBridgeRequest("dock-panel", "panel.dock", bridge, [1])
  nide.defineBridgeRequest("float-active-pane", "pane.float-active", bridge, [0])
  nide.defineBridgeRequest("dock-pane", "pane.dock", bridge, [1])
  nide.defineBridgeRequest("open-file-path", "file.open-path", bridge, [1])
  nide.defineBridgeRequest("switch-buffer", "buffer.switch", bridge, [1])
  nide.defineBridgeRequest("kill-buffer", "buffer.kill", bridge, [1])
  nide.defineBridgeRequest("preview-buffer", "buffer.preview", bridge, [1])
  nide.defineBridgeRequest("close-floating", "floating.close", bridge, [0])
  nide.defineBridgeRequest("toggle-floating", "floating.toggle", bridge, [0])
  nide.defineBridgeRequest("set-editor-syntax", "buffer.set-syntax", bridge, [1])
  nide.defineBridgeRequest("clear-editor-syntax", "buffer.clear-syntax", bridge, [0])
  nide.defineBridgeRequest("set-mode-hook", "buffer.set-mode-hook", bridge, [2])
  nide.defineBridgeRequest("active-editor-command", "active-editor.command",
      bridge, [1, 2, 3])
  nide.defineFileSystemCommands()
  nide.defineFileExplorerCommands(bridge)
  nide.defineStringCommand()
  nide.defineSyntaxCommands()
  nide.defineTextContains()

  evaluator.registerModule(nide)
