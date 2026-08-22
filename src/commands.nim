# Low-level native bindings and environment helpers for Nide's Owl command layer.

import std/[sets, tables]
import owl

const
  ActionNewFile* = "new-file"
  ActionOpenFileDialog* = "open-file-dialog"
  ActionSaveFileAsDialog* = "save-file-as-dialog"
  ActionMarkBufferSaved* = "mark-buffer-saved"
  ActionUnsplitPane* = "unsplit-pane"

  VarState* = "nide-state"
  VarRequestedActions* = "nide-requested-actions"
  VarSplitOrientation* = "nide-split-orientation"

  VarStatus* = "nide-status"

proc textList*(items: openArray[string]): Value =
  var values: seq[Value]
  for item in items:
    values.add text(item)
  list(values)

proc bindValue*(env: Environment, name: string, value: Value) =
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

proc requestAction(env: Environment, action: string) =
  var actions =
    if env.contains(VarRequestedActions):
      env.get(VarRequestedActions)
    else:
      list(@[])
  if actions.kind != List:
    raise newException(EvaluatorError, VarRequestedActions & " must be a list")
  actions.items.add text(action)
  env.set(VarRequestedActions, actions)

proc defineRequestAction(module: var NativeModule) =
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
    env.requestAction(action.text)
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

proc registerInternalCommands*(evaluator: var Evaluator) =
  var nide = nativeModule"nide"
  nide.define "version", text"0.0.0"
  nide.defineRequestAction()
  nide.defineSetter("set-split-orientation", VarSplitOrientation)
  nide.defineSetter("set-status", VarStatus)

  evaluator.registerModule(nide)
