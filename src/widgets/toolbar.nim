import std/tables

import nest, owl

# Toolbars can be docked around an editor surface. Top and bottom docks stack
# horizontal toolbars. Left and right docks line up vertical toolbars.

type
  ToolbarDock* = enum
    TopDock
    BottomDock
    LeftDock
    RightDock

  ToolbarMenuItem* = object
    id*: string
    label*: string
    commandID*: string

  ToolbarMenu* = object
    id*: string
    label*: string
    items*: seq[ToolbarMenuItem]

  ToolbarTool* = object
    id*: string
    label*: string
    commandID*: string

  ToolbarControlKind* = enum
    ToolbarMenuControl
    ToolbarToolControl
    ToolbarSpacerControl

  ToolbarControl* = object
    case kind*: ToolbarControlKind
    of ToolbarMenuControl:
      menu*: ToolbarMenu
    of ToolbarToolControl:
      tool*: ToolbarTool
    of ToolbarSpacerControl:
      spacerID*: string

  Toolbar* = object
    id*: string
    dock*: ToolbarDock
    controls*: seq[ToolbarControl]
    openMenu*: string

  Toolbars* = object
    bars*: seq[Toolbar]

  StatusbarControlKind* = enum
    StatusbarLabelControl
    StatusbarButtonControl
    StatusbarSpacerControl

  StatusbarControl* = object
    case kind*: StatusbarControlKind
    of StatusbarLabelControl:
      labelText*: string
    of StatusbarButtonControl:
      buttonID*: string
      buttonLabel*: string
      buttonCommandID*: string
    of StatusbarSpacerControl:
      statusbarSpacerID*: string

  Statusbar* = object
    controls*: seq[StatusbarControl]

  ToolbarEvent* {.variant.} = object
    toolbarID*: string
    commandID*: string
    case kind*: ToolbarEventKind
    of MenuClicked:
      clickedMenuID*: string
    of MenuItemClicked:
      itemMenuID*: string
      itemID*: string
    of ToolClicked:
      toolID*: string

  StatusbarEvent* = object
    controlID*: string
    commandID*: string

proc toolbarMenuItem*(id, label: string, commandID = ""): ToolbarMenuItem =
  ToolbarMenuItem(id: id, label: label,
      commandID: if commandID.len > 0: commandID else: id)

proc toolbarMenu*(id, label: string,
    items: openArray[ToolbarMenuItem] = []): ToolbarMenu =
  ToolbarMenu(id: id, label: label, items: @items)

proc toolbarTool*(id, label: string, commandID = ""): ToolbarTool =
  ToolbarTool(id: id, label: label,
      commandID: if commandID.len > 0: commandID else: id)

proc toolbarMenuControl*(menu: ToolbarMenu): ToolbarControl =
  ToolbarControl(kind: ToolbarMenuControl, menu: menu)

proc toolbarToolControl*(tool: ToolbarTool): ToolbarControl =
  ToolbarControl(kind: ToolbarToolControl, tool: tool)

proc toolbarSpacer*(id = ""): ToolbarControl =
  ToolbarControl(kind: ToolbarSpacerControl, spacerID: id)

proc toolbarDock*(name: string): ToolbarDock {.raises: [EvaluatorError].} =
  case name
  of "top":
    TopDock
  of "bottom":
    BottomDock
  of "left":
    LeftDock
  of "right":
    RightDock
  else:
    raise newException(EvaluatorError, "unknown toolbar dock: " & name)

proc isVertical*(dock: ToolbarDock): bool =
  dock in {LeftDock, RightDock}

proc initToolbar*(id = "", dock = TopDock): Toolbar =
  Toolbar(id: id, dock: dock, controls: @[], openMenu: "")

proc initToolbars*(): Toolbars =
  Toolbars(bars: @[])

proc initStatusbar*(): Statusbar =
  Statusbar(controls: @[])

proc addToolbar*(toolbars: var Toolbars, id: string, dock: ToolbarDock) =
  toolbars.bars.add initToolbar(id, dock)

proc toolbarView(toolbars: var Toolbars, id: string): var Toolbar =
  for bar in toolbars.bars.mitems:
    if bar.id == id:
      return bar
  raise newException(EvaluatorError, "unknown toolbar: " & id)

proc addMenu*(toolbar: var Toolbar, menu: ToolbarMenu) =
  toolbar.controls.add toolbarMenuControl(menu)

proc addMenu*(toolbar: var Toolbar, id, label: string,
    items: openArray[ToolbarMenuItem] = []) =
  toolbar.addMenu toolbarMenu(id, label, items)

proc addItem*(toolbar: var Toolbar, menuID: string, item: ToolbarMenuItem) =
  for control in toolbar.controls.mitems:
    if control.kind == ToolbarMenuControl and control.menu.id == menuID:
      control.menu.items.add item
      return

proc addTool*(toolbar: var Toolbar, tool: ToolbarTool) =
  toolbar.controls.add toolbarToolControl(tool)

proc addTool*(toolbar: var Toolbar, id, label: string, commandID = "") =
  toolbar.addTool toolbarTool(id, label, commandID)

proc addSpacer*(toolbar: var Toolbar, id = "") =
  toolbar.controls.add toolbarSpacer(id)

proc addMenu*(
    toolbars: var Toolbars, toolbarID, id, label: string,
    items: openArray[ToolbarMenuItem] = []
) {.raises: [EvaluatorError].} =
  toolbars.toolbarView(toolbarID).addMenu(id, label, items)

proc addItem*(
    toolbars: var Toolbars, toolbarID, menuID: string, item: ToolbarMenuItem
) {.raises: [EvaluatorError].} =
  toolbars.toolbarView(toolbarID).addItem(menuID, item)

proc addTool*(
    toolbars: var Toolbars, toolbarID, id, label: string, commandID = ""
) {.raises: [EvaluatorError].} =
  toolbars.toolbarView(toolbarID).addTool(id, label, commandID)

proc addSpacer*(toolbars: var Toolbars, toolbarID: string, id = "") {.raises: [
    EvaluatorError].} =
  toolbars.toolbarView(toolbarID).addSpacer(id)

proc expectArgumentCount(
    commandID: string, actual: int, expected: openArray[int]
) =
  for count in expected:
    if actual == count:
      return
  raise newException(EvaluatorError, commandID & " got " & $actual &
      " arguments")

proc evalTextArgument(
    env: Environment, arguments: seq[SyntaxNode], index: int, commandID: string
): string {.raises: [EvaluatorError].} =
  let value = env.eval(arguments[index])
  if value.kind != Text:
    raise newException(EvaluatorError, commandID & " expects text arguments")
  value.text

proc textField(value: Value, field, owner: string): string {.raises: [
    EvaluatorError].} =
  if value.kind != Dictionary or field notin value.entries:
    raise newException(EvaluatorError, owner & " is missing " & field)
  let entry = value.entries.getOrDefault(field)
  if entry.kind != Text:
    raise newException(EvaluatorError, owner & "." & field & " must be text")
  entry.text

proc listField(value: Value, field, owner: string): seq[Value] {.raises: [
    EvaluatorError].} =
  if value.kind != Dictionary or field notin value.entries:
    raise newException(EvaluatorError, owner & " is missing " & field)
  let entry = value.entries.getOrDefault(field)
  if entry.kind != List:
    raise newException(EvaluatorError, owner & "." & field & " must be a list")
  entry.items

proc toolbarValue(kind: string, fields: openArray[(string, Value)]): Value =
  var entries = initTable[string, Value]()
  entries["kind"] = text(kind)
  for (name, value) in fields:
    entries[name] = value
  dictionary(entries)

proc evalBodyList(env: Environment, bodyNodes: seq[SyntaxNode]): Value {.
    raises: [EvaluatorError].} =
  var values: seq[Value]
  for node in bodyNodes:
    values.add env.eval(node)
  list(values)

proc readToolbarMenuItem(value: Value): ToolbarMenuItem {.raises: [
    EvaluatorError].} =
  if value.textField("kind", "toolbar item") != "item":
    raise newException(EvaluatorError, "expected toolbar item")
  toolbarMenuItem(
    value.textField("id", "toolbar item"),
    value.textField("label", "toolbar item"),
    value.textField("command", "toolbar item"),
  )

proc readToolbarMenu(value: Value): ToolbarMenu {.raises: [EvaluatorError].} =
  if value.textField("kind", "toolbar menu") != "menu":
    raise newException(EvaluatorError, "expected toolbar menu")
  result = toolbarMenu(
    value.textField("id", "toolbar menu"),
    value.textField("label", "toolbar menu"),
  )
  for itemValue in value.listField("items", "toolbar menu"):
    result.items.add readToolbarMenuItem(itemValue)

proc readToolbarTool(value: Value): ToolbarTool {.raises: [EvaluatorError].} =
  if value.textField("kind", "toolbar tool") != "tool":
    raise newException(EvaluatorError, "expected toolbar tool")
  toolbarTool(
    value.textField("id", "toolbar tool"),
    value.textField("label", "toolbar tool"),
    value.textField("command", "toolbar tool"),
  )

proc readToolbarSpacer(value: Value): ToolbarControl {.raises: [
    EvaluatorError].} =
  if value.textField("kind", "toolbar spacer") != "spacer":
    raise newException(EvaluatorError, "expected toolbar spacer")
  toolbarSpacer(value.textField("id", "toolbar spacer"))

proc readToolbar*(value: Value): Toolbar {.raises: [EvaluatorError].} =
  if value.textField("kind", "toolbar") != "toolbar":
    raise newException(EvaluatorError, "expected toolbar")
  result = initToolbar(
    value.textField("id", "toolbar"),
    toolbarDock(value.textField("dock", "toolbar")),
  )
  for child in value.listField("children", "toolbar"):
    let kind = child.textField("kind", "toolbar child")
    case kind
    of "menu":
      result.addMenu readToolbarMenu(child)
    of "tool":
      result.addTool readToolbarTool(child)
    of "spacer":
      result.controls.add readToolbarSpacer(child)
    else:
      raise newException(EvaluatorError, "unknown toolbar child: " & kind)

proc readToolbars*(env: Environment, name: string): Toolbars {.raises: [
    EvaluatorError].} =
  let value = env.get(name)
  if value.kind != List:
    raise newException(EvaluatorError, name & " must be a list")
  result = initToolbars()
  for toolbarValue in value.items:
    result.bars.add readToolbar(toolbarValue)

proc statusbarLabel(value: string): StatusbarControl =
  StatusbarControl(kind: StatusbarLabelControl, labelText: value)

proc statusbarButton(id, label: string, commandID = ""): StatusbarControl =
  StatusbarControl(kind: StatusbarButtonControl, buttonID: id,
      buttonLabel: label, buttonCommandID: if commandID.len >
      0: commandID else: id)

proc statusbarSpacer(id = ""): StatusbarControl =
  StatusbarControl(kind: StatusbarSpacerControl, statusbarSpacerID: id)

proc readStatusbarControl(value: Value): StatusbarControl {.raises: [
    EvaluatorError].} =
  let kind = value.textField("kind", "statusbar control")
  case kind
  of "label":
    statusbarLabel(value.textField("text", "statusbar label"))
  of "button":
    statusbarButton(
      value.textField("id", "statusbar button"),
      value.textField("label", "statusbar button"),
      value.textField("command", "statusbar button"),
    )
  of "spacer":
    statusbarSpacer(value.textField("id", "statusbar spacer"))
  else:
    raise newException(EvaluatorError, "unknown statusbar control: " & kind)

proc readStatusbar*(env: Environment, name: string): Statusbar {.raises: [
    EvaluatorError].} =
  let value = env.get(name)
  if value.kind != List:
    raise newException(EvaluatorError, name & " must be a list")
  result = initStatusbar()
  for controlValue in value.items:
    result.controls.add readStatusbarControl(controlValue)

proc registerToolbarBuilderCommands*(evaluator: var Evaluator) =
  var module = nativeModule"nide/toolbar"

  module.native "toolbars":
    discard layout
    expectArgumentCount("toolbars", arguments.len, [0])
    result = evalBodyList(env, bodyNodes)
    env.set("nide-toolbars", result)

  module.native "toolbar":
    discard layout
    expectArgumentCount("toolbar", arguments.len, [2])
    toolbarValue("toolbar", [
      ("id", text(env.evalTextArgument(arguments, 0, "toolbar"))),
      ("dock", text(env.evalTextArgument(arguments, 1, "toolbar"))),
      ("children", evalBodyList(env, bodyNodes)),
    ])

  module.native "menu":
    discard layout
    expectArgumentCount("menu", arguments.len, [2])
    toolbarValue("menu", [
      ("id", text(env.evalTextArgument(arguments, 0, "menu"))),
      ("label", text(env.evalTextArgument(arguments, 1, "menu"))),
      ("items", evalBodyList(env, bodyNodes)),
    ])

  module.native "item":
    discard layout
    discard bodyNodes
    expectArgumentCount("item", arguments.len, [2, 3])
    let id = env.evalTextArgument(arguments, 0, "item")
    toolbarValue("item", [
      ("id", text(id)),
      ("label", text(env.evalTextArgument(arguments, 1, "item"))),
      ("command", text(
        if arguments.len == 3:
          env.evalTextArgument(arguments, 2, "item")
        else:
          id
      )),
    ])

  module.native "tool":
    discard layout
    discard bodyNodes
    expectArgumentCount("tool", arguments.len, [2, 3])
    let id = env.evalTextArgument(arguments, 0, "tool")
    toolbarValue("tool", [
      ("id", text(id)),
      ("label", text(env.evalTextArgument(arguments, 1, "tool"))),
      ("command", text(
        if arguments.len == 3:
          env.evalTextArgument(arguments, 2, "tool")
        else:
          id
      )),
    ])

  module.native "spacer":
    discard layout
    discard bodyNodes
    expectArgumentCount("spacer", arguments.len, [0, 1])
    toolbarValue("spacer", [
      ("id", text(
        if arguments.len == 1:
          env.evalTextArgument(arguments, 0, "spacer")
        else:
          ""
      )),
    ])

  module.native "statusbar":
    discard layout
    expectArgumentCount("statusbar", arguments.len, [0])
    result = evalBodyList(env, bodyNodes)
    env.set("nide-statusbar", result)

  module.native "label":
    discard layout
    discard bodyNodes
    expectArgumentCount("label", arguments.len, [1])
    let value = env.eval(arguments[0])
    if value.kind != Text:
      raise newException(EvaluatorError, "label expects text")
    toolbarValue("label", [
      ("text", value),
    ])

  module.native "button":
    discard layout
    discard bodyNodes
    expectArgumentCount("button", arguments.len, [2, 3])
    let id = env.evalTextArgument(arguments, 0, "button")
    toolbarValue("button", [
      ("id", text(id)),
      ("label", text(env.evalTextArgument(arguments, 1, "button"))),
      ("command", text(
        if arguments.len == 3:
          env.evalTextArgument(arguments, 2, "button")
        else:
          id
      )),
    ])

  evaluator.registerModule(module)

widget toolbar*(model: var Toolbar)emits ToolbarEvent:
  let vertical = model.dock.isVertical()
  var spacerIndex = model.controls.len
  for index, control in model.controls:
    if control.kind == ToolbarSpacerControl:
      spacerIndex = index
      break

  template renderControl(index: int) =
    let control = model.controls[index]
    case control.kind
    of ToolbarMenuControl:
      let menu = control.menu
      if ui.menu(ui.id("menu", model.id, menu.id), menu.label):
        ui.events:
          model.openMenu = if model.openMenu == menu.id: "" else: menu.id
        emit ToolbarEvent(kind: MenuClicked, toolbarID: model.id,
            clickedMenuID: menu.id)
    of ToolbarToolControl:
      let tool = control.tool
      if ui.button(ui.id("tool", model.id, tool.id), tool.label):
        emit ToolbarEvent(kind: ToolClicked, toolbarID: model.id,
            toolID: tool.id, commandID: tool.commandID)
    of ToolbarSpacerControl:
      discard

  if vertical:
    ui.column(ui.id("root", model.id), cfg(width = fit(), height = fill(),
        gap = 6, alignItems = AlignCenter)):
      for index in 0 ..< spacerIndex:
        renderControl(index)
      if spacerIndex < model.controls.len:
        ui.spacer(ui.id("spacer", model.id), width = fixed(1), height = fill())
        for index in (spacerIndex + 1) ..< model.controls.len:
          renderControl(index)
  else:
    ui.menuBar(ui.id("root", model.id), cfg(width = fill(), height = fit(),
        gap = 2, alignItems = AlignCenter)):
      for index in 0 ..< spacerIndex:
        renderControl(index)
      if spacerIndex < model.controls.len:
        ui.spacer(ui.id("spacer", model.id), width = fill(), height = fixed(1))
        for index in (spacerIndex + 1) ..< model.controls.len:
          renderControl(index)

  for control in model.controls:
    if control.kind == ToolbarMenuControl:
      let menu = control.menu
      if model.openMenu == menu.id:
        ui.floatingCardBelow(ui.id("popover", model.id, menu.id),
            ui.id("menu", model.id, menu.id), cfg(width = fixed(180),
            height = fit(), padding = 4, gap = 2)):
          for item in menu.items:
            ui.menuItem(ui.id("item", model.id, menu.id, item.id),
                cfg(width = fill(), height = fit())):
              ui.label(ui.id("itemText", model.id, menu.id, item.id),
                  item.label)
            if ui.clicked(ui.id("item", model.id, menu.id, item.id)):
              ui.events:
                model.openMenu = ""
              emit ToolbarEvent(kind: MenuItemClicked, toolbarID: model.id,
                  itemMenuID: menu.id, itemID: item.id,
                  commandID: item.commandID)

widget toolbarDock*(model: var Toolbars, dock: ToolbarDock)emits ToolbarEvent:
  let vertical = dock.isVertical()
  let hasBars = block:
    var found = false
    for bar in model.bars:
      if bar.dock == dock:
        found = true
        break
    found

  if hasBars and vertical:
    ui.row(ui.id("dock", $dock), cfg(width = fit(), height = fill(), gap = 0,
        alignSelf = AlignStretch)):
      for index in 0 ..< model.bars.len:
        if model.bars[index].dock == dock:
          for event in ui.toolbar(model.bars[index]):
            emit event
  elif hasBars:
    ui.column(ui.id("dock", $dock), cfg(width = fill(), height = fit(),
        gap = 0)):
      for index in 0 ..< model.bars.len:
        if model.bars[index].dock == dock:
          for event in ui.toolbar(model.bars[index]):
            emit event

widget statusbar*(model: var Statusbar)emits StatusbarEvent:
  var spacerIndex = model.controls.len
  for index, control in model.controls:
    if control.kind == StatusbarSpacerControl:
      spacerIndex = index
      break

  template renderControl(index: int) =
    let control = model.controls[index]
    case control.kind
    of StatusbarLabelControl:
      ui.label(ui.id("statusbarLabel", index), control.labelText)
    of StatusbarButtonControl:
      if ui.button(ui.id("statusbarButton", control.buttonID),
          control.buttonLabel):
        emit StatusbarEvent(controlID: control.buttonID,
            commandID: control.buttonCommandID)
    of StatusbarSpacerControl:
      discard

  ui.row(ui.id("statusbar"), cfg(width = fill(), height = fit(), gap = 8,
      alignItems = AlignCenter)):
    for index in 0 ..< spacerIndex:
      renderControl(index)
    if spacerIndex < model.controls.len:
      ui.spacer(ui.id("statusbarSpacer"), width = fill(), height = fixed(1))
      for index in (spacerIndex + 1) ..< model.controls.len:
        renderControl(index)
