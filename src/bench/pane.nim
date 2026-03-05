import std/os
import seaqt/[qwidget, qpushbutton, qvboxlayout, qhboxlayout, qlayout, qlabel,
              qstackedwidget, qfiledialog, qplaintextedit, qfont,
              qpixmap, qpaintdevice, qpainter, qcolor, qicon, qsize,
              qsvgrenderer, qabstractbutton, qshortcut, qkeysequence,
              qpalette, qlineargradient,
              qlineedit, qcheckbox, qtextdocument, qtextcursor, qtextedit,
              qregularexpression, qbrush, qtextformat, qtextobject]
import bench/[buffers, highlight]

{.compile("search_extra.cpp", gorge("pkg-config --cflags Qt6Widgets")).}
proc createDefaultExtraSelection(): pointer {.importc: "QTextEditExtraSelection_createDefault".}

type
  Pane* = ref object
    container: QWidget
    headerBar: QWidget
    label: QLabel
    statusLabel: QLabel
    stack: QStackedWidget
    openModuleWidget: QWidget
    editor: QPlainTextEdit
    highlighter: NimHighlighter
    changed*: bool
    buffer*: Buffer
    fileSelectedCb: proc(pane: Pane, path: string) {.raises: [].}
    newModuleCb: proc(pane: Pane) {.raises: [].}
    moduleBtnsRowH: pointer
    openProjectRowH: pointer
    openModuleCb: proc(pane: Pane) {.raises: [].}
    openProjectCb: proc(pane: Pane) {.raises: [].}
    searchBarH:     pointer
    searchInputH:   pointer
    caseCheckH:     pointer
    regexCheckH:    pointer
    matchPositions: seq[(cint, cint)]
    matchIndex:     int

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
  onHSplit: proc(pane: Pane) {.raises: [].},
  onNewModule: proc(pane: Pane) {.raises: [].},
  onOpenModule: proc(pane: Pane) {.raises: [].},
  onOpenProject: proc(pane: Pane) {.raises: [].}
): Pane =
  result = Pane()

  # --- Open Project row (shown when no project is open) ---
  var openProjectBtn = QPushButton.create("Open Project")
  openProjectBtn.owned = false

  var openProjectLayout = QHBoxLayout.create(); openProjectLayout.owned = false
  openProjectLayout.addStretch()
  openProjectLayout.addWidget(QWidget(h: openProjectBtn.h, owned: false))
  openProjectLayout.addStretch()

  var openProjectRow = QWidget.create()
  openProjectRow.owned = false
  openProjectRow.setLayout(QLayout(h: openProjectLayout.h, owned: false))

  # --- Module buttons row (shown when project is open) ---
  var newModuleBtn = QPushButton.create("New Module")
  newModuleBtn.owned = false
  var openModuleBtn = QPushButton.create("Open Module")
  openModuleBtn.owned = false

  var moduleBtnsLayout = QHBoxLayout.create(); moduleBtnsLayout.owned = false
  moduleBtnsLayout.addStretch()
  moduleBtnsLayout.addWidget(QWidget(h: newModuleBtn.h, owned: false))
  moduleBtnsLayout.addWidget(QWidget(h: openModuleBtn.h, owned: false))
  moduleBtnsLayout.addStretch()

  var moduleBtnsRow = QWidget.create()
  moduleBtnsRow.owned = false
  moduleBtnsRow.setLayout(QLayout(h: moduleBtnsLayout.h, owned: false))
  QWidget(h: moduleBtnsRow.h, owned: false).hide()  # hidden until project opened

  # --- Outer layout for page 0 ---
  var layout = QVBoxLayout.create(); layout.owned = false
  layout.addStretch()
  layout.addWidget(QWidget(h: openProjectRow.h, owned: false))
  layout.addWidget(QWidget(h: moduleBtnsRow.h, owned: false))
  layout.addStretch()

  var openModuleWidget = QWidget.create()
  openModuleWidget.owned = false
  openModuleWidget.setLayout(QLayout(h: layout.h, owned: false))
  openModuleWidget.setFocusPolicy(cint 2)  # Qt::ClickFocus

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

  # --- Search bar ---
  var searchInput = QLineEdit.create()
  searchInput.owned = false
  searchInput.setPlaceholderText("Search…")

  var caseCheck = QCheckBox.create("Aa")
  caseCheck.owned = false

  var regexCheck = QCheckBox.create(".*")
  regexCheck.owned = false

  var prevBtn = QPushButton.create("▲")
  prevBtn.owned = false
  prevBtn.setFlat(true)
  QWidget(h: prevBtn.h, owned: false).setFixedSize(cint 22, cint 22)

  var nextBtn = QPushButton.create("▼")
  nextBtn.owned = false
  nextBtn.setFlat(true)
  QWidget(h: nextBtn.h, owned: false).setFixedSize(cint 22, cint 22)

  var searchCloseBtn = QPushButton.create("×")
  searchCloseBtn.owned = false
  searchCloseBtn.setFlat(true)
  QWidget(h: searchCloseBtn.h, owned: false).setFixedSize(cint 22, cint 22)

  var searchLayout = QHBoxLayout.create()
  searchLayout.owned = false
  QLayout(h: searchLayout.h, owned: false).setContentsMargins(cint 4, cint 2, cint 4, cint 2)
  searchLayout.addWidget(QWidget(h: searchInput.h, owned: false), cint 1, cint 0)
  searchLayout.addWidget(QWidget(h: caseCheck.h, owned: false), cint 0, cint 0)
  searchLayout.addWidget(QWidget(h: regexCheck.h, owned: false), cint 0, cint 0)
  searchLayout.addWidget(QWidget(h: prevBtn.h, owned: false), cint 0, cint 0)
  searchLayout.addWidget(QWidget(h: nextBtn.h, owned: false), cint 0, cint 0)
  searchLayout.addWidget(QWidget(h: searchCloseBtn.h, owned: false), cint 0, cint 0)

  var searchBar = QWidget.create()
  searchBar.owned = false
  searchBar.setLayout(QLayout(h: searchLayout.h, owned: false))
  QWidget(h: searchBar.h, owned: false).hide()

  # Outer container: header bar + search bar + stack
  var outerLayout = QVBoxLayout.create()
  outerLayout.owned = false
  QLayout(h: outerLayout.h, owned: false).setContentsMargins(cint 0, cint 0, cint 0, cint 0)
  QLayout(h: outerLayout.h, owned: false).setSpacing(cint 0)
  outerLayout.addWidget(QWidget(h: headerBar.h, owned: false), cint(0), cint(0))
  outerLayout.addWidget(QWidget(h: searchBar.h, owned: false), cint(0), cint(0))
  outerLayout.addWidget(QWidget(h: stack.h, owned: false), cint(0), cint(0))
  var container = QWidget.create()
  container.owned = false
  container.setAutoFillBackground(true)
  container.setLayout(QLayout(h: outerLayout.h, owned: false))

  result.container = container
  result.headerBar = headerBar
  result.label = label
  result.statusLabel = statusLabel
  result.stack = stack
  result.openModuleWidget = openModuleWidget
  result.editor = editor
  result.highlighter = hl
  result.fileSelectedCb  = onFileSelected
  result.newModuleCb     = onNewModule
  result.moduleBtnsRowH  = moduleBtnsRow.h
  result.openProjectRowH = openProjectRow.h
  result.openModuleCb    = onOpenModule
  result.openProjectCb   = onOpenProject
  result.searchBarH      = searchBar.h
  result.searchInputH    = searchInput.h
  result.caseCheckH      = caseCheck.h
  result.regexCheckH     = regexCheck.h

  let pane = result
  QPlainTextEdit(h: pane.editor.h, owned: false).onTextChanged do() {.raises: [].}:
    pane.changed = true
    pane.statusLabel.setText(StatusLight)

  openProjectBtn.onClicked do() {.raises: [].}: onOpenProject(pane)
  newModuleBtn.onClicked   do() {.raises: [].}: onNewModule(pane)
  openModuleBtn.onClicked  do() {.raises: [].}: onOpenModule(pane)

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

  # --- Search helpers ---
  proc moveToCurrent(pane: Pane) {.raises: [].} =
    if pane.matchPositions.len == 0: return
    let (s, e) = pane.matchPositions[pane.matchIndex]
    let ed = QPlainTextEdit(h: pane.editor.h, owned: false)
    var cur = ed.textCursor()
    cur.setPosition(s)
    cur.setPosition(e, cint(QTextCursorMoveModeEnum.KeepAnchor))
    ed.setTextCursor(cur)
    ed.ensureCursorVisible()

  proc doSearch(pane: Pane) {.raises: [].} =
    let ed    = QPlainTextEdit(h: pane.editor.h, owned: false)
    let inp   = QLineEdit(h: pane.searchInputH, owned: false)
    let query = inp.text()
    if query.len == 0:
      ed.setExtraSelections(newSeq[QTextEditExtraSelection]())
      pane.matchPositions = @[]
      return
    let caseSens = QAbstractButton(h: pane.caseCheckH, owned: false).isChecked()
    let useRx    = QAbstractButton(h: pane.regexCheckH, owned: false).isChecked()
    let flags    = if caseSens: cint(QTextDocumentFindFlagEnum.FindCaseSensitively)
                   else: cint(0)

    var fmt = QTextCharFormat.create()
    QTextFormat(h: fmt.h, owned: false).setBackground(
      QBrush.create(QColor.create("#4a4a00")))

    var rx = QRegularExpression.create(query)
    if not caseSens:
      rx.setPatternOptions(
        cint(QRegularExpressionPatternOptionEnum.CaseInsensitiveOption))

    let doc = ed.document()
    var pos     = cint(0)
    var matches: seq[(cint, cint)]
    var sels:    seq[QTextEditExtraSelection]

    while true:
      var cur = if useRx: doc.find(rx, pos)
                else:     doc.find(query, pos, flags)
      if cur.isNull(): break
      let s = cur.selectionStart()
      let e = cur.selectionEnd()
      if e <= pos: break  # zero-length match guard
      matches.add((s, e))
      var sel = QTextEditExtraSelection(h: createDefaultExtraSelection(), owned: true)
      sel.setCursor(cur)
      sel.setFormat(fmt)
      sels.add(sel)
      pos = e

    pane.matchPositions = matches
    pane.matchIndex     = 0
    ed.setExtraSelections(sels)
    moveToCurrent(pane)

  proc closeSearch(pane: Pane) {.raises: [].} =
    QWidget(h: pane.searchBarH, owned: false).hide()
    QPlainTextEdit(h: pane.editor.h, owned: false).setExtraSelections(
      newSeq[QTextEditExtraSelection]())
    pane.matchPositions = @[]
    QWidget(h: pane.editor.h, owned: false).setFocus()

  # --- Search signal connections ---
  searchInput.onTextChanged do(text: openArray[char]) {.raises: [].}:
    doSearch(pane)

  caseCheck.onStateChanged do(state: cint) {.raises: [].}:
    doSearch(pane)

  regexCheck.onStateChanged do(state: cint) {.raises: [].}:
    doSearch(pane)

  searchInput.onReturnPressed do() {.raises: [].}:
    if pane.matchPositions.len > 0:
      pane.matchIndex = (pane.matchIndex + 1) mod pane.matchPositions.len
      moveToCurrent(pane)

  nextBtn.onClicked do() {.raises: [].}:
    if pane.matchPositions.len > 0:
      pane.matchIndex = (pane.matchIndex + 1) mod pane.matchPositions.len
      moveToCurrent(pane)

  prevBtn.onClicked do() {.raises: [].}:
    if pane.matchPositions.len > 0:
      pane.matchIndex =
        (pane.matchPositions.len + pane.matchIndex - 1) mod pane.matchPositions.len
      moveToCurrent(pane)

  searchCloseBtn.onClicked do() {.raises: [].}:
    closeSearch(pane)

  # --- Ctrl+F shortcut ---
  var findSc = QShortcut.create(QKeySequence.create("Ctrl+F"),
                                QObject(h: pane.container.h, owned: false))
  findSc.owned = false
  findSc.setContext(cint 1)  # WidgetWithChildrenShortcut
  findSc.onActivated do() {.raises: [].}:
    QWidget(h: pane.searchBarH, owned: false).show()
    QWidget(h: pane.searchInputH, owned: false).setFocus()
    doSearch(pane)

  # --- Escape shortcut ---
  var escapeSc = QShortcut.create(QKeySequence.create("Escape"),
                                  QObject(h: pane.container.h, owned: false))
  escapeSc.owned = false
  escapeSc.setContext(cint 1)  # WidgetWithChildrenShortcut
  escapeSc.onActivated do() {.raises: [].}:
    closeSearch(pane)

proc setHeaderFocus*(pane: Pane, focused: bool, isDark: bool) =
  let hbw = QWidget(h: pane.headerBar.h, owned: false)
  if focused:
    var grad = QLinearGradient.create(0.0, 0.0, 0.0, 1.0)
    QGradient(h: grad.h, owned: false).setCoordinateMode(cint QGradientCoordinateModeEnum.ObjectMode)
    if isDark:
      QGradient(h: grad.h, owned: false).setColorAt(0.0, QColor.create("#1e3a5c"))
      QGradient(h: grad.h, owned: false).setColorAt(1.0, QColor.create("#000000"))
    else:
      QGradient(h: grad.h, owned: false).setColorAt(0.0, QColor.create("#b8d4f0"))
      QGradient(h: grad.h, owned: false).setColorAt(1.0, QColor.create("#e8e8e8"))
    var brush = QBrush.create(QGradient(h: grad.h, owned: false))
    var pal = QPalette.create()
    pal.setBrush(cint QPaletteColorRoleEnum.Window, brush)
    hbw.setPalette(pal)
    hbw.setAutoFillBackground(true)
  else:
    var grad = QLinearGradient.create(0.0, 0.0, 0.0, 1.0)
    QGradient(h: grad.h, owned: false).setCoordinateMode(cint QGradientCoordinateModeEnum.ObjectMode)
    if isDark:
      QGradient(h: grad.h, owned: false).setColorAt(0.0, QColor.create("#0b1623"))
      QGradient(h: grad.h, owned: false).setColorAt(1.0, QColor.create("#000000"))
    else:
      QGradient(h: grad.h, owned: false).setColorAt(0.0, QColor.create("#596b7c"))
      QGradient(h: grad.h, owned: false).setColorAt(1.0, QColor.create("#e8e8e8"))
    var brush = QBrush.create(QGradient(h: grad.h, owned: false))
    var pal = QPalette.create()
    pal.setBrush(cint QPaletteColorRoleEnum.Window, brush)
    hbw.setPalette(pal)
    hbw.setAutoFillBackground(true)

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
  QWidget(h: pane.searchBarH, owned: false).hide()
  pane.matchPositions = @[]

proc clearBuffer*(pane: Pane) =
  pane.label.setText("")
  pane.editor.setPlainText("")
  pane.changed = false
  pane.statusLabel.setText(StatusDark)
  pane.stack.setCurrentIndex(cint(0))
  pane.buffer = nil
  QWidget(h: pane.searchBarH, owned: false).hide()
  pane.matchPositions = @[]

proc openModuleDialog*(pane: Pane) {.raises: [].} =
  let fn = QFileDialog.getOpenFileName(QWidget(h: pane.container.h, owned: false))
  if fn.len > 0:
    pane.fileSelectedCb(pane, fn)

proc triggerNewModule*(pane: Pane) {.raises: [].} =
  pane.newModuleCb(pane)

proc triggerOpenModule*(pane: Pane) {.raises: [].} =
  pane.openModuleCb(pane)

proc setProjectOpen*(pane: Pane, open: bool) =
  QWidget(h: pane.moduleBtnsRowH, owned: false).setVisible(open)
  QWidget(h: pane.openProjectRowH, owned: false).setVisible(not open)

proc focus*(pane: Pane) {.raises: [].} =
  if pane.buffer != nil:
    QWidget(h: pane.editor.h, owned: false).setFocus()
  else:
    pane.container.setFocus()

proc jumpToLine*(pane: Pane, lineNum: int) {.raises: [].} =
  if pane.buffer == nil: return
  let ed  = QPlainTextEdit(h: pane.editor.h, owned: false)
  let doc = ed.document()
  let blk = doc.findBlockByNumber(cint(lineNum - 1))
  var cur = ed.textCursor()
  cur.setPosition(blk.position())
  ed.setTextCursor(cur)
  ed.ensureCursorVisible()
