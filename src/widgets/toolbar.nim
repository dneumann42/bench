import nest

# Toolbars have menus on the left, and buttons on the right

type
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

  Toolbar* = object
    menus*: seq[ToolbarMenu]
    tools*: seq[ToolbarTool]
    openMenu*: string

  ToolbarEvent* {.variant.} = object
    commandID*: string
    case kind*: ToolbarEventKind
    of MenuClicked:
      clickedMenuID*: string
    of MenuItemClicked:
      itemMenuID*: string
      itemID*: string
    of ToolClicked:
      toolID*: string

proc toolbarMenuItem*(id, label: string, commandID = ""): ToolbarMenuItem =
  ToolbarMenuItem(id: id, label: label,
      commandID: if commandID.len > 0: commandID else: id)

proc toolbarMenu*(id, label: string,
    items: openArray[ToolbarMenuItem] = []): ToolbarMenu =
  ToolbarMenu(id: id, label: label, items: @items)

proc toolbarTool*(id, label: string, commandID = ""): ToolbarTool =
  ToolbarTool(id: id, label: label,
      commandID: if commandID.len > 0: commandID else: id)

proc initToolbar*(): Toolbar =
  Toolbar(menus: @[], tools: @[], openMenu: "")

proc addMenu*(toolbar: var Toolbar, menu: ToolbarMenu) =
  toolbar.menus.add menu

proc addMenu*(toolbar: var Toolbar, id, label: string,
    items: openArray[ToolbarMenuItem] = []) =
  toolbar.addMenu toolbarMenu(id, label, items)

proc addItem*(toolbar: var Toolbar, menuID: string, item: ToolbarMenuItem) =
  for menu in toolbar.menus.mitems:
    if menu.id == menuID:
      menu.items.add item
      return

proc addTool*(toolbar: var Toolbar, tool: ToolbarTool) =
  toolbar.tools.add tool

proc addTool*(toolbar: var Toolbar, id, label: string, commandID = "") =
  toolbar.addTool toolbarTool(id, label, commandID)

widget toolbar*(model: var Toolbar)emits ToolbarEvent:
  ui.menuBar(ui.id("root"), cfg(width = fill(), height = fit(), gap = 2,
      alignItems = AlignCenter)):
    for menu in model.menus:
      if ui.menu(ui.id("menu", menu.id), menu.label):
        ui.events:
          model.openMenu = if model.openMenu == menu.id: "" else: menu.id
        emit ToolbarEvent(kind: MenuClicked, clickedMenuID: menu.id)
    ui.spacer(ui.id("spacer"), width = fill(), height = fixed(1))
    ui.row(ui.id("tools"), cfg(width = fit(), height = fit(), gap = 8,
        alignItems = AlignCenter)):
      for tool in model.tools:
        if ui.button(ui.id("tool", tool.id), tool.label):
          emit ToolbarEvent(kind: ToolClicked, toolID: tool.id,
              commandID: tool.commandID)

  for menu in model.menus:
    if model.openMenu == menu.id:
      ui.floatingCardBelow(ui.id("popover", menu.id), ui.id("menu", menu.id),
          cfg(width = fixed(180), height = fit(), padding = 4, gap = 2)):
        for item in menu.items:
          ui.menuItem(ui.id("item", menu.id, item.id),
              cfg(width = fill(), height = fit())):
            ui.label(ui.id("itemText", menu.id, item.id), item.label)
          if ui.clicked(ui.id("item", menu.id, item.id)):
            ui.events:
              model.openMenu = ""
            emit ToolbarEvent(kind: MenuItemClicked, itemMenuID: menu.id,
                itemID: item.id, commandID: item.commandID)
