import std/[os]
import seaqt/[qapplication, qwidget, qfiledialog, qmainwindow, qtoolbar, qsplitter,
              qcoreapplication, qtoolbutton, qabstractbutton,
              qshortcut, qkeysequence, qobject, qgraphicsopacityeffect,
              qgraphicseffect]
import bench/[toolbar, buffers, projects, projectdialog, moduledialog, theme, pane, runner,
              filefinder, rgfinder, settings]

type
  Application* = ref object
    bufferManager: BufferManager
    toolbar: Toolbar
    projectManager: ProjectManager
    root: QMainWindow
    splitter: QSplitter
    panels: seq[Pane]
    theme: Theme
    currentProject: string
    runStatusBtnH:  pointer
    buildStatusBtnH: pointer
    runReopen:  proc() {.raises: [].}
    buildReopen: proc() {.raises: [].}
    lastFocusedPane: Pane
    opacityActive: bool
    opacityEffect: QGraphicsOpacityEffect

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

proc openProject(self: Application) {.raises: [].} =
  let file = QFileDialog.getOpenFileName(
    QWidget(h: self.root.h, owned: false), "", "", "Nimble files (*.nimble)")
  if file.len == 0: return
  let dir = file.parentDir()
  self.currentProject = dir
  for panel in self.panels:
    panel.clearBuffer()
    panel.setProjectOpen(true)
  self.bufferManager = BufferManager.init()
  try: setCurrentDir(dir) except OSError: discard
  self.toolbar.setProjectName(dir.lastPathPart)

# Forward declarations
proc insertCol(self: Application, afterPane: Pane, col: QSplitter)
proc insertRow(self: Application, afterPane: Pane, col: QSplitter)

proc makePane(self: Application, col: QSplitter): Pane =
  let colH = col.h  # capture raw pointer — avoids QSplitter copy restriction
  result = newPane(
    proc(pane: Pane, path: string) {.raises: [].} =
      let buf = self.bufferManager.openFile(path)
      pane.setBuffer(buf),
    proc(pane: Pane) {.raises: [].} =
      if self.panels.len <= 1:
        pane.clearBuffer()
      else:
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
      except: discard,
    proc(pane: Pane) {.raises: [].} =
      let path = showNewModuleDialog(QWidget(h: self.root.h, owned: false))
      if path.len > 0:
        let buf = self.bufferManager.openFile(path)
        pane.setBuffer(buf),
    proc(pane: Pane) {.raises: [].} =
      showFileFinder(QWidget(h: self.root.h, owned: false),
        proc(path: string) {.raises: [].} =
          let buf = self.bufferManager.openFile(path)
          pane.setBuffer(buf)),
    proc(pane: Pane) {.raises: [].} =
      self.openProject())
  if self.currentProject.len > 0:
    result.setProjectOpen(true)

proc insertCol(self: Application, afterPane: Pane, col: QSplitter) =
  let colW = QWidget(h: col.h, owned: false)
  let idx = self.splitter.indexOf(colW)
  if idx < 0: return
  let oldSizes = self.splitter.sizes()
  let srcW = oldSizes[idx]
  var newCol = QSplitter.create(cint 2)   # vertical
  newCol.setHandleWidth(cint 1)
  QWidget(h: newCol.h, owned: false).setAutoFillBackground(true)
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
  p.focus()

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
  p.focus()

proc addColumn(self: Application) =
  var col = QSplitter.create(cint 2)    # vertical
  col.setHandleWidth(cint 1)
  QWidget(h: col.h, owned: false).setAutoFillBackground(true)
  col.owned = false
  let p = self.makePane(col)
  col.addWidget(p.widget())
  self.splitter.addWidget(QWidget(h: col.h, owned: false))
  self.panels.add(p)
  p.focus()

proc closeBuffer*(self: Application, name: string) =
  for panel in self.panels:
    if panel.buffer != nil and panel.buffer.name == name:
      panel.clearBuffer()
  self.bufferManager.close(name)

proc build*(self: Application) =
  self.root = QMainWindow.create()
  QWidget(h: self.root.h, owned: false).setAttribute(cint(120))  # WA_TranslucentBackground
  QWidget(h: self.root.h, owned: false).setMinimumSize(cint(800), cint(480))
  self.toolbar.build()

  self.root.addToolBar(QToolBar(h: self.toolbar.widget().h, owned: false))

  self.splitter = QSplitter.create(cint(1))
  self.splitter.setHandleWidth(cint 1)
  QWidget(h: self.splitter.h, owned: false).setAutoFillBackground(true)
  self.root.setCentralWidget(QWidget(h: self.splitter.h, owned: false))
  self.splitter.owned = false

  var opEff = QGraphicsOpacityEffect.create()
  opEff.setOpacity(1.0)
  QWidget(h: self.splitter.h, owned: false).setGraphicsEffect(
    QGraphicsEffect(h: opEff.h, owned: false))
  opEff.owned = false
  self.opacityEffect = opEff

  self.theme = Dark
  applyTheme(Dark)

  # Floating background-process indicator buttons (initially hidden, child of root)
  var runStatusBtn = QToolButton.create()
  runStatusBtn.owned = false
  QAbstractButton(h: runStatusBtn.h, owned: false).setText("nimble run")
  QWidget(h: runStatusBtn.h, owned: false).setParent(QWidget(h: self.root.h, owned: false))
  QWidget(h: runStatusBtn.h, owned: false).hide()
  self.runStatusBtnH = runStatusBtn.h

  var buildStatusBtn = QToolButton.create()
  buildStatusBtn.owned = false
  QAbstractButton(h: buildStatusBtn.h, owned: false).setText("nimble build")
  QWidget(h: buildStatusBtn.h, owned: false).setParent(QWidget(h: self.root.h, owned: false))
  QWidget(h: buildStatusBtn.h, owned: false).hide()
  self.buildStatusBtnH = buildStatusBtn.h

  let runBtnH = self.runStatusBtnH
  runStatusBtn.onClicked do() {.raises: [].}:
    QWidget(h: runBtnH, owned: false).hide()
    if self.runReopen != nil:
      self.runReopen()
      self.runReopen = nil

  let buildBtnH = self.buildStatusBtnH
  buildStatusBtn.onClicked do() {.raises: [].}:
    QWidget(h: buildBtnH, owned: false).hide()
    if self.buildReopen != nil:
      self.buildReopen()
      self.buildReopen = nil

  self.toolbar.onRun do():
    let onBg = proc(reopen: proc() {.raises: [].}) {.raises: [].} =
      self.runReopen = reopen
      let rw = QWidget(h: self.root.h, owned: false)
      let btn = QWidget(h: self.runStatusBtnH, owned: false)
      btn.move(rw.width() - cint(110), rw.height() - cint(40))
      btn.show()
      btn.raiseX()
    let gotoRun = proc(file: string, line, col: int) {.raises: [].} =
      try:
        var target = self.lastFocusedPane
        if target == nil and self.panels.len > 0:
          target = self.panels[0]
        if target == nil: return
        let buf = self.bufferManager.openFile(file)
        target.setBuffer(buf)
        target.jumpToLine(line, col)
      except: discard
    runCommand(QWidget(h: self.root.h, owned: false), "nimble run", "n=$(ls *.nimble | head -1); b=${n%.nimble}; nim cpp --out:./$b src/$b.nim && ./$b", onBg, gotoRun)

  self.toolbar.onBuild do():
    let onBg = proc(reopen: proc() {.raises: [].}) {.raises: [].} =
      self.buildReopen = reopen
      let rw = QWidget(h: self.root.h, owned: false)
      let btn = QWidget(h: self.buildStatusBtnH, owned: false)
      btn.move(rw.width() - cint(110), rw.height() - cint(80))
      btn.show()
      btn.raiseX()
    let gotoBuild = proc(file: string, line, col: int) {.raises: [].} =
      try:
        var target = self.lastFocusedPane
        if target == nil and self.panels.len > 0:
          target = self.panels[0]
        if target == nil: return
        let buf = self.bufferManager.openFile(file)
        target.setBuffer(buf)
        target.jumpToLine(line, col)
      except: discard
    runCommand(QWidget(h: self.root.h, owned: false), "nimble build", "n=$(ls *.nimble | head -1); b=${n%.nimble}; nim cpp --out:./$b src/$b.nim", onBg, gotoBuild)

  self.toolbar.onThemeToggle do():
    self.theme = if self.theme == Dark: Light else: Dark
    applyTheme(self.theme)
    self.toolbar.setThemeIcon(self.theme == Dark)
    let fw = QApplication.focusWidget()
    for p in self.panels:
      p.setHeaderFocus(fw.h != nil and p.widget().isAncestorOf(fw), self.theme == Dark)

  self.toolbar.onOpacityToggle do():
    self.opacityActive = not self.opacityActive
    let level = if self.opacityActive: 0.95 else: 1.0
    self.opacityEffect.setOpacity(level)

  self.toolbar.onTriggered(NewProject) do():
    showNewProjectDialog(QWidget(h: self.root.h, owned: false), self.projectManager)

  self.toolbar.onTriggered(NewModule) do():
    if self.panels.len > 0:
      self.panels[0].triggerNewModule()

  self.toolbar.onTriggered(OpenModule) do():
    if self.panels.len > 0:
      self.panels[0].triggerOpenModule()
  
  self.toolbar.onTriggered(OpenFile) do():
    let file = QFileDialog.getOpenFileName(
        QWidget(h: self.root.h, owned: false), "", "", "All files (*.*)")
    if file.len == 0: return
    let buf = self.bufferManager.openFile(file)
    
    var target = self.lastFocusedPane
    if target == nil and self.panels.len > 0:
      target = self.panels[0]
    if target == nil: return
    target.setBuffer(buf)

  self.toolbar.onTriggered(OpenProject) do():
    self.openProject()

  self.toolbar.onTriggered(Quit) do():
    QApplication.quit()

  self.toolbar.onNewPane do():
    self.addColumn()
    self.equalizeSplits()

  self.toolbar.onSettings do():
    showSettingsDialog(QWidget(h: self.root.h, owned: false))

  var finderSc = QShortcut.create(QKeySequence.create("Ctrl+P"),
                                  QObject(h: self.root.h, owned: false))
  finderSc.owned = false
  finderSc.setContext(cint 2)   # WindowShortcut
  finderSc.onActivated do() {.raises: [].}:
    var target = self.lastFocusedPane
    if target == nil and self.panels.len > 0:
      target = self.panels[0]
    if target == nil: return
    showFileFinder(
      QWidget(h: self.root.h, owned: false),
      proc(path: string) {.raises: [].} =
        let buf = self.bufferManager.openFile(path)
        target.setBuffer(buf))

  var bufferSc = QShortcut.create(QKeySequence.create("Ctrl+B"),
                                  QObject(h: self.root.h, owned: false))
  bufferSc.owned = false
  bufferSc.setContext(cint 2)   # WindowShortcut
  bufferSc.onActivated do() {.raises: [].}:
    var target = self.lastFocusedPane
    if target == nil and self.panels.len > 0:
      target = self.panels[0]
    if target == nil: return
    var entries: seq[(string, string)]
    let cwd = try: getCurrentDir() except OSError: ""
    for buf in self.bufferManager:
      var display = buf.name
      if cwd.len > 0:
        try: display = relativePath(buf.name, cwd)
        except: discard
      entries.add((display, buf.name))
    if entries.len == 0: return
    showBufferFinder(
      QWidget(h: self.root.h, owned: false),
      entries,
      proc(key: string) {.raises: [].} =
        for buf in self.bufferManager:
          if buf.name == key:
            target.setBuffer(buf)
            break)

  var rgSc = QShortcut.create(QKeySequence.create("Ctrl+Shift+F"),
                              QObject(h: self.root.h, owned: false))
  rgSc.owned = false
  rgSc.setContext(cint 2)
  rgSc.onActivated do() {.raises: [].}:
    var target = self.lastFocusedPane
    if target == nil and self.panels.len > 0:
      target = self.panels[0]
    if target == nil: return
    showRipgrepFinder(
      QWidget(h: self.root.h, owned: false),
      proc(file: string, lineNum: int) {.raises: [].} =
        let buf = self.bufferManager.openFile(file)
        target.setBuffer(buf)
        target.jumpToLine(lineNum))

  self.addColumn()  # initialize at least one
  self.equalizeSplits()

  let appInstance = QApplication(h: QCoreApplication.instance().h, owned: false)
  appInstance.onFocusChanged do(old, now: QWidget):
    try:
      for p in self.panels:
        let focused = now.h != nil and p.widget().isAncestorOf(now)
        p.setHeaderFocus(focused, self.theme == Dark)
        if focused:
          self.lastFocusedPane = p
    except: discard

proc show*(self: Application) =
  self.root.show()
