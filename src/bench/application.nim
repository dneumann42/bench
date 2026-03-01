import seaqt/[qapplication, qwidget, qfiledialog, qmainwindow, qtoolbar,
              qsplitter, qpushbutton, qvboxlayout]
import bench/[toolbar, buffers, projects, projectdialog]

type
  BenchPanel = object
    pane: QWidget
    bufferName: string

  Application* = ref object
    bufferManager: BufferManager
    toolbar: Toolbar
    projectManager: ProjectManager
    root: QMainWindow
    splitter: QSplitter
    panels: seq[BenchPanel]

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

proc onNewPane(root: QMainWindow, splitter: QSplitter) =
  var btn = QPushButton.create("Open Module")
  btn.owned = false
  var layout = QVBoxLayout.create()
  layout.owned = false
  layout.addStretch()
  layout.addWidget(QWidget(h: btn.h, owned: false), cint(0), cint(4))  # AlignHCenter = 4
  layout.addStretch()
  var pane = QWidget.create()
  pane.owned = false
  pane.setLayout(QLayout(h: layout.h, owned: false))
  let root = QWidget(h: root.h, owned: false)
  btn.onClicked do():
    let fn = QFileDialog.getOpenFileName(root)
    echo fn
  splitter.addWidget(QWidget(h: pane.h, owned: false))

proc build*(self: Application) =
  self.root = QMainWindow.create()
  self.toolbar.build()

  self.root.addToolBar(QToolBar(h: self.toolbar.widget().h, owned: false))

  self.splitter = QSplitter.create(cint(1))          # 1 = Horizontal
  self.root.setCentralWidget(QWidget(h: self.splitter.h, owned: false))
  self.splitter.owned = false   # Qt (QMainWindow) owns the C++ object now

  self.toolbar.onTriggered(NewProject) do():
    showNewProjectDialog(QWidget(h: self.root.h, owned: false), self.projectManager)

  self.toolbar.onTriggered(OpenFile) do():
    let fn = QFileDialog.getOpenFileName(QWidget(h: self.root.h, owned: false))
    echo fn

  self.toolbar.onTriggered(Quit) do():
    QApplication.quit()

  self.toolbar.onNewPane do():
    self.root.onNewPane(self.splitter)

  self.root.onNewPane(self.splitter) # initialize at least one
  self.equalizeSplits()

proc show*(self: Application) =
  self.root.show()
