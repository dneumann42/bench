import std/[tables]

import owl

type
  PanelDock* = enum
    PanelLeft
    PanelRight
    PanelTop
    PanelBottom

  NidePanel* = object
    id*: string
    title*: string
    dock*: PanelDock
    source*: string
    widget*: string
    open*: bool
    size*: float64

proc panelDock*(name: string): PanelDock {.raises: [EvaluatorError].} =
  case name
  of "left": PanelLeft
  of "right": PanelRight
  of "top": PanelTop
  of "bottom": PanelBottom
  else:
    raise newException(EvaluatorError, "unknown panel dock: " & name)

proc name*(dock: PanelDock): string =
  case dock
  of PanelLeft: "left"
  of PanelRight: "right"
  of PanelTop: "top"
  of PanelBottom: "bottom"

proc textField(value: Value, field, owner: string): string {.raises: [
    EvaluatorError].} =
  if value.kind != Dictionary or field notin value.entries:
    raise newException(EvaluatorError, owner & " is missing " & field)
  let entry = value.entries.getOrDefault(field)
  if entry.kind != Text:
    raise newException(EvaluatorError, owner & "." & field & " must be text")
  entry.text

proc boolField(value: Value, field, owner: string): bool {.raises: [
    EvaluatorError].} =
  if value.kind != Dictionary or field notin value.entries:
    return false
  value.entries.getOrDefault(field).isTruthy

proc numberField(value: Value, field, owner: string,
    fallback: float64): float64 {.
    raises: [EvaluatorError].} =
  if value.kind != Dictionary or field notin value.entries:
    return fallback
  let entry = value.entries.getOrDefault(field)
  if entry.kind != Number:
    raise newException(EvaluatorError, owner & "." & field & " must be a number")
  entry.number

proc panelValue(kind: string, fields: openArray[(string, Value)]): Value =
  var entries = initTable[string, Value]()
  entries["kind"] = text(kind)
  for (name, value) in fields:
    entries[name] = value
  dictionary(entries)

proc expectArgumentCount(commandID: string, actual: int,
    expected: openArray[int]) {.raises: [EvaluatorError].} =
  for count in expected:
    if actual == count:
      return
  raise newException(EvaluatorError, commandID & " got " & $actual & " arguments")

proc evalTextArgument(env: Environment, arguments: seq[SyntaxNode], index: int,
    commandID: string): string {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    raise newException(EvaluatorError, commandID & " missing argument")
  let value = env.eval(arguments[index])
  if value.kind != Text:
    raise newException(EvaluatorError, commandID & " expects text")
  value.text

proc evalListArgument(env: Environment, arguments: seq[SyntaxNode], index: int,
    commandID: string): Value {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    raise newException(EvaluatorError, commandID & " missing argument")
  result = env.eval(arguments[index])
  if result.kind != List:
    raise newException(EvaluatorError, commandID & " expects a list")

proc readPanel*(value: Value): NidePanel {.raises: [EvaluatorError].} =
  if value.textField("kind", "panel") != "panel":
    raise newException(EvaluatorError, "expected panel")
  NidePanel(
    id: value.textField("id", "panel"),
    title: value.textField("title", "panel"),
    dock: panelDock(value.textField("dock", "panel")),
    source: value.textField("source", "panel"),
    widget: value.textField("widget", "panel"),
    open: value.boolField("open", "panel"),
    size: value.numberField("size", "panel", 280),
  )

proc readPanels*(env: Environment, name: string): seq[NidePanel] {.raises: [
    EvaluatorError].} =
  let value = env.get(name)
  if value.kind != List:
    raise newException(EvaluatorError, name & " must be a list")
  for panelValue in value.items:
    result.add readPanel(panelValue)

proc registerPanelBuilderCommands*(evaluator: var Evaluator) =
  var module = nativeModule"nide/panels"

  module.native "set-panels":
    discard layout
    discard bodyNodes
    expectArgumentCount("set-panels", arguments.len, [1])
    result = env.evalListArgument(arguments, 0, "set-panels")
    let targetEnv = if env.parent.isNil: env else: env.parent
    targetEnv.set("nide-panels", result)

  module.native "panel-value":
    discard layout
    discard bodyNodes
    expectArgumentCount("panel-value", arguments.len, [7])
    panelValue("panel", [
      ("id", text(env.evalTextArgument(arguments, 0, "panel-value"))),
      ("title", text(env.evalTextArgument(arguments, 1, "panel-value"))),
      ("dock", text(env.evalTextArgument(arguments, 2, "panel-value"))),
      ("source", text(env.evalTextArgument(arguments, 3, "panel-value"))),
      ("widget", text(env.evalTextArgument(arguments, 4, "panel-value"))),
      ("open", env.eval(arguments[5])),
      ("size", env.eval(arguments[6])),
    ])

  evaluator.registerModule(module)
