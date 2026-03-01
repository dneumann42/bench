import seaqt/[qapplication, qwidget, qfiledialog, qmainwindow, qtoolbar,
              qsplitter]
import bench/[toolbar, buffers, projects, projectdialog, theme, pane]

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
  # Equalise all pane widths
  let n = self.splitter.count().int
  var sizes = newSeq[cint](n)
  for i in 0..<n:
    sizes[i] = cint(1)
  self.splitter.setSizes(sizes)

proc addPane(self: Application) =
  var p: Pane
  p = newPane(proc(pane: Pane, path: string) {.raises: [].} =
    let buf = self.bufferManager.openFile(path)
    pane.setBuffer(buf))
  self.splitter.addWidget(p.widget())
  self.panels.add(p)

proc closeBuffer*(self: Application, name: string) =
  for panel in self.panels:
    if panel.bufferName == name:
      panel.clearBuffer()
  self.bufferManager.close(name)

proc build*(self: Application) =
  self.root = QMainWindow.create()
  QWidget(h: self.root.h, owned: false).setMinimumSize(cint(800), cint(480))
  self.toolbar.build()

  self.root.addToolBar(QToolBar(h: self.toolbar.widget().h, owned: false))

  self.splitter = QSplitter.create(cint(1))          # 1 = Horizontal
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

  self.toolbar.onTriggered(OpenFile) do():
    if self.panels.len > 0:
      let fn = QFileDialog.getOpenFileName(QWidget(h: self.root.h, owned: false))
      if fn.len > 0:
        let buf = self.bufferManager.openFile(fn)
        self.panels[0].setBuffer(buf)

  self.toolbar.onTriggered(Quit) do():
    QApplication.quit()

  self.toolbar.onNewPane do():
    self.addPane()
    self.equalizeSplits()

  self.addPane()  # initialize at least one
  self.equalizeSplits()

proc show*(self: Application) =
  self.root.show()
