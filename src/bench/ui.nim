import std/[tables, sequtils, sugar]
import seaqt/[
  qapplication, qmainwindow, qstackedwidget,
  qwidget, qpushbutton,
  qplaintextedit, qtoolbar, qboxlayout,
  qmenu, qtoolbutton, qaction, qkeysequence, qfiledialog,
  qfont, qfontdatabase, qtabwidget]
import seaqt/QtWidgets/gen_qlayout_types

type
  FileMenuAction* = enum
    OpenFile
    SaveFile
    SaveFileAs
    Separator
    Dashboard
    Quit
  
  ProjectMenuAction* = enum
    NewProject,
    OpenProject
    Separator

const FileMenuActionLabels = {
    OpenFile: "&Open",
    SaveFile: "&Save",
    SaveFileAs: "Save &As",
    Separator: "---",
    Dashboard: "Dashboard",
    Quit: "&Quit",
}.toTable

const ProjectMenuActionLabels = {
  NewProject: "&New Project",
  OpenProject: "&Open Project",
}.toTable

const FileMenuActionKeybindings = {
    OpenFile: "Ctrl+O",
    SaveFile: "Ctrl+S",
    SaveFileAs: "Ctrl+Shift+S",
    Quit: "Ctrl+Q",
    Dashboard: "Ctrl+D",
}.toTable

const ProjectMenuActionKeybindings = {
    OpenProject: "Ctrl+o",
    NewProject: "Ctrl+n",
}.toTable

type
  MenuAction* [A: enum] = object
    action: A
    onAction: proc() {.closure, raises: [].}

proc menuAction*[A: enum](
  action: A,
  onAction: proc() {.closure, raises: [].}
): MenuAction[A] =
  result = MenuAction[A](action: action, onAction: onAction)

proc buildMenu*[A: enum](
  label: string,
  labels: Table[A, string],
  keybindings: Table[A, string],
  actions: varargs[MenuAction[A]],
): QToolButton =
  result = QToolButton.create()
  var widget = QMenu.create(QWidget(h: result.h, owned: false))
  widget.owned = false
  let menuWidget = QWidget(h: widget.h, owned: false)
  for a in actions:
    if a.action == Separator:
      discard widget.addSeparator()
      continue
    let act = menuWidget.addAction(
      labels[a.action],
      QKeySequence.create(keybindings[a.action])
    )
    act.onTriggered(a.onAction)
  result.setText(label)
  result.setMenu(widget)
  result.setPopupMode(cint QToolButtonToolButtonPopupModeEnum.InstantPopup)

proc buildFileMenu*(
  actions: varargs[MenuAction[FileMenuAction]]
): QToolButton =
  result = buildMenu[FileMenuAction](
    "File",
    FileMenuActionLabels,
    FileMenuActionKeybindings,
    actions
  )

proc buildProjectMenu*(
  actions: varargs[MenuAction[ProjectMenuAction]]
): QToolButton =
  result = buildMenu[ProjectMenuAction](
    "Project",
    ProjectMenuActionLabels,
    ProjectMenuActionKeybindings,
    actions
  )
