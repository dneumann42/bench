import std/os
import seaqt/[qwidget, qpushbutton, qvboxlayout, qhboxlayout, qlayout, qlabel,
              qstackedwidget, qfiledialog, qplaintextedit, qfont,
              qpixmap, qpaintdevice, qpainter, qcolor, qicon, qsize,
              qsvgrenderer, qabstractbutton, qshortcut, qkeysequence]
import bench/[buffers, highlight]

type
  Pane* = ref object
    container: QWidget
    label: QLabel
    statusLabel: QLabel
    stack: QStackedWidget
    openModuleWidget: QWidget
    editor: QPlainTextEdit
    highlighter: NimHighlighter
    changed*: bool
    buffer*: Buffer

const StatusDark = ""
const StatusLight = "★"

const VsplitSvg = staticRead("icons/vsplit.svg")
const HsplitSvg = staticRead("icons/hsplit.svg")
const SaveSvg = staticRead("icons/save.svg")

proc svgIcon(svg: string, size: cint): QIcon =
  var pm = QPixmap.create(size, size)
  pm.fill(QColor.create("transparent"))
  var painter = QPainter.create(QPaintDevice(h: pm.h, owned: false))
  var renderer = QSvgRenderer.create(svg.toOpenArrayByte(0, svg.high))
  renderer.render(painter)
  discard painter.endX()
  QIcon.create(pm)

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
  var editorFont = QFont.create("Monospace")
  editorFont.setStyleHint(cint(QFontStyleHintEnum.TypeWriter))
  QWidget(h: editor.h, owned: false).setFont(editorFont)
  let hl = NimHighlighter()
  hl.attach(editor.document())

  var stack = QStackedWidget.create()
  stack.owned = false
  discard stack.addWidget(QWidget(h: openModuleWidget.h, owned: false))
  discard stack.addWidget(QWidget(h: editor.h, owned: false))

  var label = QLabel.create("")
  label.owned = false

  var statusLabel = QLabel.create(StatusDark)
  statusLabel.owned = false

  const IconSize = 10

  var vSplitBtn = QPushButton.create("")
  vSplitBtn.owned = false
  vSplitBtn.setFlat(true)
  QWidget(h: vSplitBtn.h, owned: false).setFixedSize(cint 18, cint 18)
  QAbstractButton(h: vSplitBtn.h, owned: false).setIcon(svgIcon(VsplitSvg, cint IconSize))
  QAbstractButton(h: vSplitBtn.h, owned: false).setIconSize(QSize.create(cint IconSize, cint IconSize))

  var hSplitBtn = QPushButton.create("")
  hSplitBtn.owned = false
  hSplitBtn.setFlat(true)
  QWidget(h: hSplitBtn.h, owned: false).setFixedSize(cint 18, cint 18)
  QAbstractButton(h: hSplitBtn.h, owned: false).setIcon(svgIcon(HsplitSvg, cint IconSize))
  QAbstractButton(h: hSplitBtn.h, owned: false).setIconSize(QSize.create(cint IconSize, cint IconSize))

  var closeBtn = QPushButton.create("×")
  closeBtn.owned = false
  closeBtn.setFlat(true)
  QWidget(h: closeBtn.h, owned: false).setFixedSize(cint 18, cint 18)

  var saveBtn = QPushButton.create("")
  saveBtn.owned = false
  saveBtn.setFlat(true)
  QWidget(h: saveBtn.h, owned: false).setFixedSize(cint 18, cint 18)
  QAbstractButton(h: saveBtn.h, owned: false).setIcon(svgIcon(SaveSvg, cint IconSize))
  QAbstractButton(h: saveBtn.h, owned: false).setIconSize(QSize.create(cint IconSize, cint IconSize))

  var headerLayout = QHBoxLayout.create()
  headerLayout.owned = false
  QLayout(h: headerLayout.h, owned: false).setContentsMargins(cint 4, cint 2, cint 4, cint 2)
  headerLayout.addWidget(QWidget(h: label.h, owned: false), cint(0), cint(0))
  headerLayout.addWidget(QWidget(h: statusLabel.h, owned: false), cint(0), cint(0))
  headerLayout.addStretch()
  headerLayout.addWidget(QWidget(h: saveBtn.h, owned: false), cint(0), cint(0))
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
  result.statusLabel = statusLabel
  result.stack = stack
  result.openModuleWidget = openModuleWidget
  result.editor = editor
  result.highlighter = hl

  let pane = result
  QPlainTextEdit(h: pane.editor.h, owned: false).onTextChanged do() {.raises: [].}:
    pane.changed = true
    pane.statusLabel.setText(StatusLight)

  btn.onClicked do() {.raises: [].}:
    let fn = QFileDialog.getOpenFileName(QWidget(h: pane.stack.h, owned: false))
    if fn.len > 0:
      onFileSelected(pane, fn)

  proc doSave(pane: Pane) {.raises: [].} =
    if pane.buffer != nil and pane.buffer.path.len > 0:
      try:
        writeFile(pane.buffer.path, QPlainTextEdit(h: pane.editor.h, owned: false).toPlainText())
        pane.changed = false
        pane.statusLabel.setText(StatusDark)
      except:
        discard

  saveBtn.onClicked do() {.raises: [].}: doSave(pane)

  var saveShortcut = QShortcut.create(
    cint(QKeySequenceStandardKeyEnum.Save),
    QObject(h: pane.container.h, owned: false))
  saveShortcut.owned = false
  saveShortcut.setContext(cint 1)  # WidgetWithChildrenShortcut
  saveShortcut.onActivated do() {.raises: [].}: doSave(pane)

  vSplitBtn.onClicked do() {.raises: [].}: onVSplit(pane)
  hSplitBtn.onClicked do() {.raises: [].}: onHSplit(pane)
  closeBtn.onClicked do() {.raises: [].}: onClose(pane)

proc setBuffer*(pane: Pane, buf: Buffer) =
  var displayName = buf.name
  try: displayName = relativePath(buf.name, getCurrentDir())
  except: discard
  pane.label.setText(displayName)
  pane.editor.setPlainText(buf.content)
  pane.changed = false
  pane.statusLabel.setText(StatusDark)
  pane.stack.setCurrentIndex(cint(1))
  pane.buffer = buf

proc clearBuffer*(pane: Pane) =
  pane.label.setText("")
  pane.editor.setPlainText("")
  pane.changed = false
  pane.statusLabel.setText(StatusDark)
  pane.stack.setCurrentIndex(cint(0))
  pane.buffer = nil
