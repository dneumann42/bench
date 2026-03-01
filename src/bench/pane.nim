import seaqt/[qwidget, qpushbutton, qvboxlayout, qlayout,
              qstackedwidget, qfiledialog]
import bench/buffers

type
  Pane* = ref object
    stack: QStackedWidget
    openModuleWidget: QWidget
    currentEditorH: pointer   # handle of editor currently in stack (nil = none)
    bufferName*: string

proc widget*(pane: Pane): QWidget =
  QWidget(h: pane.stack.h, owned: false)

proc newPane*(onFileSelected: proc(pane: Pane, path: string) {.raises: [].}): Pane =
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

  var stack = QStackedWidget.create()
  stack.owned = false
  discard stack.addWidget(QWidget(h: openModuleWidget.h, owned: false))

  result.stack = stack
  result.openModuleWidget = openModuleWidget

  let pane = result
  btn.onClicked(proc() {.raises: [].} =
    let fn = QFileDialog.getOpenFileName(QWidget(h: pane.stack.h, owned: false))
    if fn.len > 0:
      onFileSelected(pane, fn))

proc setBuffer*(pane: Pane, buf: Buffer) =
  if pane.currentEditorH != nil:
    pane.stack.removeWidget(QWidget(h: pane.currentEditorH, owned: false))
    pane.currentEditorH = nil
  let editorW = QWidget(h: buf.editor.h, owned: false)
  discard pane.stack.addWidget(editorW)
  pane.stack.setCurrentWidget(editorW)
  pane.currentEditorH = buf.editor.h
  pane.bufferName = buf.name

proc clearBuffer*(pane: Pane) =
  if pane.currentEditorH != nil:
    pane.stack.removeWidget(QWidget(h: pane.currentEditorH, owned: false))
    pane.currentEditorH = nil
  pane.stack.setCurrentIndex(cint(0))
  pane.bufferName = ""
