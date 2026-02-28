import std/[os, sets]
import seaqt/[
  qapplication, qmainwindow, qstackedwidget,
  qwidget, qpushbutton,
  qplaintextedit, qtoolbar, qboxlayout,
  qmenu, qtoolbutton, qaction, qfiledialog,
  qfont, qfontdatabase, qtabwidget]
import seaqt/QtWidgets/gen_qlayout_types

import bench/[buffers, ui]

proc buildApplication() =
  let _ = QApplication.create()

  var bufferManager = BufferManager.init()
  var bufferTabs = initHashSet[string]()

  let dashboard = QWidget.create()
  let dashLayout = QVBoxLayout.create()
  let startBtn = QPushButton.create("Start")
  startBtn.setFixedWidth(120)
  dashLayout.addStretch()
  dashLayout.addWidget(QWidget(h: startBtn.h, owned: false), 0, 132) # AlignCenter
  dashLayout.addStretch()
  dashboard.setLayout(QLayout(h: dashLayout.h, owned: false))

  let editPage = QWidget.create()
  let editLayout = QVBoxLayout.create()
  let toolbar = QToolBar.create()
  toolbar.setMovable(true)
  toolbar.setFloatable(false)

  let buffersMenu = QMenu.create()
  let monoFont = QFontDatabase.systemFont(cint QFontDatabaseSystemFontEnum.FixedFont)

  let tabs = QTabWidget.create()
  tabs.setTabsClosable(true)

  proc tabTitle(buf: Buffer): string =
    if buf.path.len == 0: ScratchBufferName
    else: splitFile(buf.path).name & splitFile(buf.path).ext

  proc tabIndexOf(buf: Buffer): cint =
    var t: cint = 0
    for b in bufferManager:
      if b == buf: return t
      if bufferTabs.contains(b.name): inc t
    -1

  proc bufferAtTab(tabIdx: cint): Buffer =
    var t: cint = 0
    for b in bufferManager:
      if bufferTabs.contains(b.name):
        if t == tabIdx: return b
        inc t
    nil

  proc openBuffer(path = "", content = "") =
    let buf = Buffer.new(path)
    QWidget(h: buf.editor.h, owned: false).setFont(monoFont)
    if content.len > 0:
      buf.editor.setPlainText(content)
    bufferTabs.incl(buf.name)
    discard tabs.addTab(QWidget(h: buf.editor.h, owned: false), tabTitle(buf))
    bufferManager.add(buf)
    tabs.setCurrentIndex(tabs.count() - 1)

  editLayout.setSpacing(0)
  editLayout.addWidget(QWidget(h: toolbar.h, owned: false))
  editLayout.addWidget(QWidget(h: tabs.h, owned: false), 1)
  editPage.setLayout(QLayout(h: editLayout.h, owned: false))

  let win = QMainWindow.create()
  win.setWindowTitle("Bench DEV 0.0.0")
  win.resize(800, 600)

  let stack = QStackedWidget.create()
  win.setCentralWidget(QWidget(h: stack.h, owned: false))

  let idxDash = stack.addWidget(dashboard)
  let idxEdit = stack.addWidget(editPage)

  openBuffer()

  proc showBuffer(buf: Buffer) =
    if bufferTabs.contains(buf.name):
      tabs.setCurrentIndex(tabIndexOf(buf))
    else:
      bufferTabs.incl(buf.name)
      discard tabs.addTab(QWidget(h: buf.editor.h, owned: false), tabTitle(buf))
      tabs.setCurrentIndex(tabs.count() - 1)
    stack.setCurrentIndex(idxEdit)
  proc addBufMenuItem(buf: Buffer) =
    let label = tabTitle(buf) & (if bufferTabs.contains(buf.name): "" else: " (closed)")
    let act = QWidget(h: buffersMenu.h, owned: false).addAction(label)
    act.onTriggered do():
      showBuffer(buf)

  buffersMenu.onAboutToShow do():
    buffersMenu.clear()
    for buf in bufferManager:
      addBufMenuItem(buf)

  tabs.onTabCloseRequested do(index: cint):
    let buf = bufferAtTab(index)
    if buf != nil:
      bufferTabs.excl(buf.name)
      tabs.removeTab(index)

  startBtn.onPressed do():
    stack.setCurrentIndex(idxEdit)

  let 
    openFileAction = menuAction(OpenFile) do():
      let path = QFileDialog.getOpenFileName(
        QWidget(h: win.h, owned: false),
        "Open File", "", "Nim files (*.nim *.nimble *.nims);;All files (*)"
      )
      if path.len > 0:
        for buf in bufferManager:
          if buf.path == path:
            showBuffer(buf)
            return
        try:
          openBuffer(path, readFile(path))
          stack.setCurrentIndex(idxEdit)
        except IOError:
          discard

    saveFileAsAction = menuAction(SaveFileAs) do():
      let idx = tabs.currentIndex()
      if idx < 0: return
      let buf = bufferAtTab(idx)
      if buf == nil: return
      let path = QFileDialog.getSaveFileName(
        QWidget(h: win.h, owned: false),
        "Save File", buf.path, "Nim files (*.nim *.nimble *.nims);;All files (*)")
      if path.len > 0:
        try:
          writeFile(path, buf.editor.toPlainText())
          buf.path = path
          tabs.setTabText(idx, tabTitle(buf))
        except IOError:
          discard

    saveFileAction = menuAction(SaveFile) do():
      let idx = tabs.currentIndex()
      if idx < 0: return
      let buf = bufferAtTab(idx)
      if buf == nil: return
      if buf.path.len > 0:
        try:
          writeFile(buf.path, buf.editor.toPlainText())
        except IOError:
          discard
      else:
        # SaveFileAs.triggered()
        discard

    quitAction = menuAction(Quit) do():
      QApplication.quit() 

  let fileMenu = buildFileMenu(
    openFileAction,
    saveFileAction,
    saveFileAsAction,
    quitAction
  )
  discard toolbar.addWidget(QWidget(h: fileMenu.h, owned: false))

  let
    projectNewAction = menuAction(NewProject) do():
      discard
    projectOpenAction = menuAction(OpenProject) do():
      discard

  let projectMenu = buildProjectMenu(
    projectNewAction,
    projectOpenAction
  )
  discard toolbar.addWidget(QWidget(h: projectMenu.h, owned: false))

  let buffersBtn = QToolButton.create()
  buffersBtn.setText("Buffers")
  buffersBtn.setMenu(buffersMenu)
  buffersBtn.setPopupMode(cint QToolButtonToolButtonPopupModeEnum.InstantPopup)
  discard toolbar.addWidget(QWidget(h: buffersBtn.h, owned: false))

  stack.setCurrentIndex(idxEdit)

  win.show()
  quit QApplication.exec().int

when isMainModule:
  buildApplication()
