import std/[tables]
import seaqt/[qtoolbar, qtoolbutton, qmenu, qwidget, qaction, qapplication]

type
  ToolMenuId* = enum
    NewFile
    SaveFile
    OpenFile
    NewProject
    AddProject
    SaveProject
    OpenProject
    Quit

  ToolMenu* = ref object
    label: string
    button: QToolButton
    menu: QMenu
    actions: Table[ToolMenuId, QAction]

  Toolbar* = ref object
    toolbar: QToolbar
    fileMenu: ToolMenu
    newPaneBtn: QToolButton
    themeBtn: QToolButton

proc build(self: ToolMenu) =
  self.button = QToolButton.create()
  self.button.setText(self.label)

  self.menu = QMenu.create()

  self.button.setMenu(self.menu)
  self.button.setPopupMode(QToolButtonToolButtonPopupModeEnum.InstantPopup)

proc widget*(self: Toolbar): lent QWidget =
  result = self.toolbar

proc onTriggered*(
  self: Toolbar, 
  event: ToolMenuId, 
  triggered: proc(): void {.raises: [].}
) =
  self.fileMenu.actions[event].onTriggered(triggered)

proc build*(self: Toolbar) =
  self.toolbar = QToolbar.create()
  QWidget(h: self.toolbar.h, owned: false).setStyleSheet("QToolBar { padding: 0px; spacing: 0px; border: none; }")

  self.fileMenu = ToolMenu(label: "File")
  self.fileMenu.build()

  self.fileMenu.actions[NewFile] = self.fileMenu.menu.addAction("New Module")
  self.fileMenu.actions[NewProject] = self.fileMenu.menu.addAction("New Project")
  self.fileMenu.actions[AddProject] = self.fileMenu.menu.addAction("Add Project")
  self.fileMenu.actions[OpenFile] = self.fileMenu.menu.addAction("Open Module")
  self.fileMenu.actions[SaveFile] = self.fileMenu.menu.addAction("Save Module")
  discard self.fileMenu.menu.addSeparator()
  self.fileMenu.actions[Quit] = self.fileMenu.menu.addAction("Quit")

  discard self.toolbar.addWidget(self.fileMenu.button)

  self.newPaneBtn = QToolButton.create()
  self.newPaneBtn.setText("New Pane")
  discard self.toolbar.addWidget(self.newPaneBtn)

  var spacer = QWidget.create()
  spacer.owned = false
  spacer.setSizePolicy(cint(7), cint(5))  # Expanding x Preferred
  discard self.toolbar.addWidget(spacer)

  self.themeBtn = QToolButton.create()
  self.themeBtn.setText("☀")  # dark is default; show sun = switch to light
  discard self.toolbar.addWidget(self.themeBtn)

proc onNewPane*(self: Toolbar, triggered: proc() {.raises: [].}) =
  self.newPaneBtn.onClicked(triggered)

proc onThemeToggle*(self: Toolbar, triggered: proc() {.raises: [].}) =
  self.themeBtn.onClicked(triggered)

proc setThemeBtnText*(self: Toolbar, text: string) =
  self.themeBtn.setText(text)
