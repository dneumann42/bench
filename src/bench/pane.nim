import std/os
import seaqt/[qwidget, qpushbutton, qvboxlayout, qhboxlayout, qlayout, qlabel,
              qstackedwidget, qfiledialog, qplaintextedit]
import bench/[buffers, highlight]

type
  Pane* = ref object
    container: QWidget
    label: QLabel
    stack: QStackedWidget
    openModuleWidget: QWidget
    editor: QPlainTextEdit
    highlighter: NimHighlighter
    bufferName*: string

proc widget*(pane: Pane): QWidget =
  QWidget(h: pane.container.h, owned: false)

proc newPane*(
  onFileSelected: proc(pane: Pane, path: string) {.raises: [].},
  onClose: proc(pane: Pane) {.raises: [].},
  onVSplit: proc(pane: Pane) {.raises: [].},
  onHSplit: proc(pane: Pane) {.raises: [].}
): Pane =
  result = Pane()

  var btn = QPushButton.create("Open Module")
  btn.owned = false
  var layout = QVBoxLayout.create()
  layout.owned = false
  layout.addStretch()
  layout.addWidget(QWidget(h: btn.h, owned: false), cint(0), cint(4))  # AlignHCenter = 4
  layout.addStretch()
  var openModuleWidget = QWidget.create()
  openModuleWidget.owned = false
  openModuleWidget.setLayout(QLayout(h: layout.h, owned: false))

  var editor = QPlainTextEdit.create()
  editor.owned = false
  let hl = NimHighlighter()
  hl.attach(editor.document())

  var stack = QStackedWidget.create()
  stack.owned = false
  discard stack.addWidget(QWidget(h: openModuleWidget.h, owned: false))
  discard stack.addWidget(QWidget(h: editor.h, owned: false))

  # Header bar: [label] [stretch] [⊟] [⊞] [×]
  var label = QLabel.create("")
  label.owned = false
  var vSplitBtn = QPushButton.create("⊟")
  vSplitBtn.owned = false
  vSplitBtn.setFlat(true)
  QWidget(h: vSplitBtn.h, owned: false).setFixedSize(cint 18, cint 18)
  var hSplitBtn = QPushButton.create("⊞")
  hSplitBtn.owned = false
  hSplitBtn.setFlat(true)
  QWidget(h: hSplitBtn.h, owned: false).setFixedSize(cint 18, cint 18)
  var closeBtn = QPushButton.create("×")
  closeBtn.owned = false
  closeBtn.setFlat(true)
  QWidget(h: closeBtn.h, owned: false).setFixedSize(cint 18, cint 18)
  var headerLayout = QHBoxLayout.create()
  headerLayout.owned = false
  QLayout(h: headerLayout.h, owned: false).setContentsMargins(cint 4, cint 2, cint 4, cint 2)
  headerLayout.addWidget(QWidget(h: label.h, owned: false), cint(0), cint(0))
  headerLayout.addStretch()
  headerLayout.addWidget(QWidget(h: vSplitBtn.h, owned: false), cint(0), cint(0))
  headerLayout.addWidget(QWidget(h: hSplitBtn.h, owned: false), cint(0), cint(0))
  headerLayout.addWidget(QWidget(h: closeBtn.h, owned: false), cint(0), cint(0))
  var headerBar = QWidget.create()
  headerBar.owned = false
  headerBar.setLayout(QLayout(h: headerLayout.h, owned: false))

  # Outer container: header bar + stack
  var outerLayout = QVBoxLayout.create()
  outerLayout.owned = false
  QLayout(h: outerLayout.h, owned: false).setContentsMargins(cint 0, cint 0, cint 0, cint 0)
  QLayout(h: outerLayout.h, owned: false).setSpacing(cint 0)
  outerLayout.addWidget(QWidget(h: headerBar.h, owned: false), cint(0), cint(0))
  outerLayout.addWidget(QWidget(h: stack.h, owned: false), cint(0), cint(0))
  var container = QWidget.create()
  container.owned = false
  container.setLayout(QLayout(h: outerLayout.h, owned: false))

  result.container = container
  result.label = label
  result.stack = stack
  result.openModuleWidget = openModuleWidget
  result.editor = editor
  result.highlighter = hl

  let pane = result
  btn.onClicked(proc() {.raises: [].} =
    let fn = QFileDialog.getOpenFileName(QWidget(h: pane.stack.h, owned: false))
    if fn.len > 0:
      onFileSelected(pane, fn))

  vSplitBtn.onClicked(proc() {.raises: [].} = onVSplit(pane))
  hSplitBtn.onClicked(proc() {.raises: [].} = onHSplit(pane))
  closeBtn.onClicked(proc() {.raises: [].} =
    onClose(pane))

proc setBuffer*(pane: Pane, buf: Buffer) =
  var displayName = buf.name
  try: displayName = relativePath(buf.name, getCurrentDir())
  except: discard
  pane.label.setText(displayName)
  pane.editor.setPlainText(buf.content)
  pane.stack.setCurrentIndex(cint(1))
  pane.bufferName = buf.name

proc clearBuffer*(pane: Pane) =
  pane.label.setText("")
  pane.editor.setPlainText("")
  pane.stack.setCurrentIndex(cint(0))
  pane.bufferName = ""
