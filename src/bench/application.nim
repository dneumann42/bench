import seaqt/[qapplication, qwidget, qfiledialog, qmainwindow, qtoolbar,
              qsplitter]
import bench/[toolbar, buffers, projects, projectdialog, moduledialog, theme, pane]

type
  Application* = ref object
    bufferManager: BufferManager
    toolbar: Toolbar
    projectManager: ProjectManager
    root: QMainWindow
    splitter: QSplitter
    panels: seq[Pane]
    theme: Theme

proc buffers*(app: Application): lent BufferManager =
  result = app.bufferManager

proc new*(T: typedesc[Application]): T =
  result = T(
    bufferManager: BufferManager.init(),
    toolbar: Toolbar(),
    projectManager: ProjectManager.init()
  )
  result.projectManager.load()

proc equalizeSplits*(self: Application) =
  # Equalise all column widths
  let n = self.splitter.count().int
  var sizes = newSeq[cint](n)
  for i in 0..<n:
    sizes[i] = cint(1)
  self.splitter.setSizes(sizes)

# Forward declarations
proc insertCol(self: Application, afterPane: Pane, col: QSplitter)
proc insertRow(self: Application, afterPane: Pane, col: QSplitter)

proc makePane(self: Application, col: QSplitter): Pane =
  let colH = col.h  # capture raw pointer — avoids QSplitter copy restriction
  newPane(
    proc(pane: Pane, path: string) {.raises: [].} =
      let buf = self.bufferManager.openFile(path)
      pane.setBuffer(buf),
    proc(pane: Pane) {.raises: [].} =
      pane.widget().hide()
      try:
        for i in countdown(self.panels.high, 0):
          if self.panels[i] == pane:
            self.panels.delete(i)
            break
      except: discard,
    proc(pane: Pane) {.raises: [].} =
      try: self.insertCol(pane, QSplitter(h: colH, owned: false))
      except: discard,
    proc(pane: Pane) {.raises: [].} =
      try: self.insertRow(pane, QSplitter(h: colH, owned: false))
      except: discard)

proc insertCol(self: Application, afterPane: Pane, col: QSplitter) =
  let colW = QWidget(h: col.h, owned: false)
  let idx = self.splitter.indexOf(colW)
  if idx < 0: return
  let oldSizes = self.splitter.sizes()
  let srcW = oldSizes[idx]
  var newCol = QSplitter.create(cint 2)   # vertical
  newCol.setHandleWidth(cint 1)
  newCol.owned = false
  let p = self.makePane(newCol)
  newCol.addWidget(p.widget())
  self.splitter.insertWidget(cint(idx + 1), QWidget(h: newCol.h, owned: false))
  var newSizes = newSeq[cint](oldSizes.len + 1)
  for i in 0..<idx:               newSizes[i]     = oldSizes[i]
  newSizes[idx]                   = cint(srcW div 2)
  newSizes[idx + 1]               = cint(srcW - srcW div 2)
  for i in idx+1..<oldSizes.len:  newSizes[i + 1] = oldSizes[i]
  self.splitter.setSizes(newSizes)
  self.panels.add(p)

proc insertRow(self: Application, afterPane: Pane, col: QSplitter) =
  let idx = col.indexOf(afterPane.widget())
  if idx < 0: return
  let oldSizes = col.sizes()
  let srcH = oldSizes[idx]
  let p = self.makePane(col)
  col.insertWidget(cint(idx + 1), p.widget())
  var newSizes = newSeq[cint](oldSizes.len + 1)
  for i in 0..<idx:               newSizes[i]     = oldSizes[i]
  newSizes[idx]                   = cint(srcH div 2)
  newSizes[idx + 1]               = cint(srcH - srcH div 2)
  for i in idx+1..<oldSizes.len:  newSizes[i + 1] = oldSizes[i]
  col.setSizes(newSizes)
  self.panels.add(p)

proc addColumn(self: Application) =
  var col = QSplitter.create(cint 2)    # vertical
  col.setHandleWidth(cint 1)
  col.owned = false
  let p = self.makePane(col)
  col.addWidget(p.widget())
  self.splitter.addWidget(QWidget(h: col.h, owned: false))
  self.panels.add(p)

proc closeBuffer*(self: Application, name: string) =
  for panel in self.panels:
    if panel.buffer != nil and panel.buffer.name == name:
      panel.clearBuffer()
  self.bufferManager.close(name)

proc build*(self: Application) =
  self.root = QMainWindow.create()
  QWidget(h: self.root.h, owned: false).setMinimumSize(cint(800), cint(480))
  self.toolbar.build()

  self.root.addToolBar(QToolBar(h: self.toolbar.widget().h, owned: false))

  self.splitter = QSplitter.create(cint(1))          # 1 = Horizontal
  self.splitter.setHandleWidth(cint 1)
  self.root.setCentralWidget(QWidget(h: self.splitter.h, owned: false))
  self.splitter.owned = false   # Qt (QMainWindow) owns the C++ object now

  self.theme = Dark
  applyTheme(Dark)

  self.toolbar.onThemeToggle do():
    self.theme = if self.theme == Dark: Light else: Dark
    applyTheme(self.theme)
    self.toolbar.setThemeBtnText(if self.theme == Dark: "☀" else: "☾")

  self.toolbar.onTriggered(NewProject) do():
    showNewProjectDialog(QWidget(h: self.root.h, owned: false), self.projectManager)

  self.toolbar.onTriggered(NewFile) do():
    if self.panels.len > 0:
      let path = showNewModuleDialog(QWidget(h: self.root.h, owned: false))
      if path.len > 0:
        let buf = self.bufferManager.openFile(path)
        self.panels[0].setBuffer(buf)

  self.toolbar.onTriggered(OpenFile) do():
    if self.panels.len > 0:
      let fn = QFileDialog.getOpenFileName(QWidget(h: self.root.h, owned: false))
      if fn.len > 0:
        let buf = self.bufferManager.openFile(fn)
        self.panels[0].setBuffer(buf)

  self.toolbar.onTriggered(Quit) do():
    QApplication.quit()

  self.toolbar.onNewPane do():
    self.addColumn()
    self.equalizeSplits()

  self.addColumn()  # initialize at least one
  self.equalizeSplits()

proc show*(self: Application) =
  self.root.show()
