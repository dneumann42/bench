# Low-level native bindings and environment helpers for Nide's Owl command layer.

import std/[os, sets, strutils, tables, sugar]
import owl

const
  ActionNewFile* = "new-file"
  ActionOpenFileDialog* = "open-file-dialog"
  ActionSaveFileAsDialog* = "save-file-as-dialog"
  ActionMarkBufferSaved* = "mark-buffer-saved"
  ActionToggleProjectsPanel* = "toggle-projects-panel"

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

proc bindvalue*(env: Environment, name: string, value: Value) =
  env.define(name, value)

proc bindText*(env: Environment, name, value: string) =
  env.bindValue(name, text(value))

proc bindTextList*(env: Environment, name: string, values: openArray[string]) =
  env.bindValue(name, textList(values))

proc bindEmptyList*(env: Environment, name: string) =
  env.bindValue(name, list(@[]))

proc stateSnapshot*(
    bufferIDs: openArray[string],
    activeBufferPath,
    activeBufferText: string,
): Value =
  var entries = initTable[string, Value]()
  entries["buffers"] = textList(bufferIDs)
  entries["active-buffer-path"] = text(activeBufferPath)
  entries["active-buffer-text"] = text(activeBufferText)
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

proc defineBridgeRequest(module: var NativeModule, commandID, requestName: string,
    bridge: NideOwlBridge, expectedArgumentCounts: openArray[int]) =
  let counts = @expectedArgumentCounts
  module.defineNative(commandID, proc(
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
  nide.defineBridgeGetter("get-active-project", "active-project", bridge)
  nide.defineBridgeGetter("auto-track-opened-projects",
      "auto-track-opened-projects", bridge)
  nide.defineBridgeRequest("open-project", "project.open", bridge, [1])
  nide.defineBridgeRequest("pick-project-directory", "project.pick-directory", bridge, [0])
  nide.defineBridgeRequest("add-project", "project.add", bridge, [2])
  nide.defineBridgeRequest("unload-project", "project.unload", bridge, [0])
  nide.defineBridgeRequest("reload-projects", "projects.reload", bridge, [0])
  nide.defineBridgeRequest("save-projects", "projects.save", bridge, [0])
  nide.defineBridgeRequest("set-nide-status", "status.set", bridge, [1])
  nide.defineFileSystemCommands()
  nide.defineStringCommand()
  nide.defineTextContains()

  evaluator.registerModule(nide)
