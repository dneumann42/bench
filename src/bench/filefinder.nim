import std/[os, algorithm, strutils]
import seaqt/[qwidget, qvboxlayout, qlayout, qdialog, qlineedit, qlistwidget,
              qlistwidgetitem, qshortcut, qkeysequence, qobject,
              qsplitter, qplaintextedit, qfont]
import bench/highlight

proc toStr(oa: openArray[char]): string {.raises: [].} =
  result = newString(oa.len)
  if oa.len > 0:
    copyMem(addr result[0], unsafeAddr oa[0], oa.len)

proc fuzzyScore(query, target: string): int {.raises: [].} =
  ## Returns -1 if query is not a subsequence of target, else match count (higher = better).
  if query.len == 0: return 0
  var qi = 0
  for ch in target:
    if qi < query.len and ch == query[qi]: inc qi
  if qi == query.len: qi else: -1

proc findNimFiles(root: string): seq[string] {.raises: [].} =
  try:
    for path in walkDirRec(root):
      if path.endsWith(".nim"):
        result.add(path.relativePath(root))
  except: discard

proc showFileFinder*(parent: QWidget,
                     onFileSelected: proc(path: string) {.raises: [].}) {.raises: [].} =
  try:
    var dialog = QDialog.create(parent)
    dialog.owned = false
    let dialogH = dialog.h
    QWidget(h: dialogH, owned: false).setWindowTitle("Open File")
    QWidget(h: dialogH, owned: false).resize(cint 900, cint 500)

    var searchBox = QLineEdit.create()
    searchBox.owned = false
    searchBox.setPlaceholderText("Search .nim files...")

    var listWidget = QListWidget.create()
    listWidget.owned = false
    let listH = listWidget.h

    var leftLayout = QVBoxLayout.create()
    leftLayout.owned = false
    leftLayout.addWidget(QWidget(h: searchBox.h, owned: false))
    leftLayout.addWidget(QWidget(h: listWidget.h, owned: false))

    var leftPanel = QWidget.create()
    leftPanel.owned = false
    leftPanel.setLayout(QLayout(h: leftLayout.h, owned: false))

    var preview = QPlainTextEdit.create()
    preview.owned = false
    preview.setReadOnly(true)
    var previewFont = QFont.create("Monospace")
    previewFont.setStyleHint(cint(QFontStyleHintEnum.TypeWriter))
    QWidget(h: preview.h, owned: false).setFont(previewFont)
    let previewHl = NimHighlighter()
    previewHl.attach(preview.document())
    let previewH = preview.h

    var splitter = QSplitter.create(cint 1)
    splitter.owned = false
    splitter.addWidget(QWidget(h: leftPanel.h, owned: false))
    splitter.addWidget(QWidget(h: preview.h, owned: false))
    splitter.setStretchFactor(cint 0, cint 1)
    splitter.setStretchFactor(cint 1, cint 2)

    var outerLayout = QVBoxLayout.create()
    outerLayout.owned = false
    outerLayout.addWidget(QWidget(h: splitter.h, owned: false))
    QWidget(h: dialogH, owned: false).setLayout(QLayout(h: outerLayout.h, owned: false))

    let root = try: getCurrentDir() except OSError: "."
    let allFiles = findNimFiles(root)

    proc populate(query: string) {.raises: [].} =
      try:
        let lw = QListWidget(h: listH, owned: false)
        lw.clear()
        var matches: seq[(int, string)]
        for f in allFiles:
          let score = fuzzyScore(query, f)
          if score >= 0:
            matches.add((score, f))
        matches.sort(proc(a, b: (int, string)): int {.raises: [].} = cmp(b[0], a[0]))
        for (_, path) in matches:
          lw.addItem(path)
        if lw.count() > 0:
          lw.setCurrentRow(cint 0)
      except: discard

    populate("")

    listWidget.onCurrentRowChanged do(row: cint) {.raises: [].}:
      if row >= 0:
        try:
          let path = root / QListWidget(h: listH, owned: false).item(row).text()
          let content = readFile(path)
          QPlainTextEdit(h: previewH, owned: false).setPlainText(content)
        except:
          QPlainTextEdit(h: previewH, owned: false).setPlainText("(could not read file)")

    searchBox.onTextChanged do(text: openArray[char]) {.raises: [].}:
      populate(toStr(text))

    # Ctrl+N = next item
    var nextSc = QShortcut.create(QKeySequence.create("Ctrl+N"),
                                  QObject(h: dialogH, owned: false))
    nextSc.owned = false
    nextSc.setContext(cint 2)   # WindowShortcut
    nextSc.onActivated do() {.raises: [].}:
      let lw = QListWidget(h: listH, owned: false)
      let next = min(lw.currentRow() + cint 1, lw.count() - cint 1)
      lw.setCurrentRow(next)

    # Ctrl+P = previous item
    var prevSc = QShortcut.create(QKeySequence.create("Ctrl+P"),
                                  QObject(h: dialogH, owned: false))
    prevSc.owned = false
    prevSc.setContext(cint 2)   # WindowShortcut
    prevSc.onActivated do() {.raises: [].}:
      let lw = QListWidget(h: listH, owned: false)
      let prev = max(lw.currentRow() - cint 1, cint 0)
      lw.setCurrentRow(prev)

    # Enter = open current selection
    var enterSc = QShortcut.create(QKeySequence.create("Return"),
                                   QObject(h: dialogH, owned: false))
    enterSc.owned = false
    enterSc.setContext(cint 2)
    enterSc.onActivated do() {.raises: [].}:
      let lw = QListWidget(h: listH, owned: false)
      let row = lw.currentRow()
      if row >= 0:
        let path = root / lw.item(row).text()
        QDialog(h: dialogH, owned: false).accept()
        onFileSelected(path)

    # Double-click = open
    listWidget.onItemDoubleClicked do(item: QListWidgetItem) {.raises: [].}:
      let path = root / item.text()
      QDialog(h: dialogH, owned: false).accept()
      onFileSelected(path)

    discard QDialog(h: dialogH, owned: false).exec()
  except: discard

proc showBufferFinder*(parent: QWidget,
                       entries: seq[(string, string)],
                       onSelected: proc(key: string) {.raises: [].}) {.raises: [].} =
  try:
    var dialog = QDialog.create(parent)
    dialog.owned = false
    let dialogH = dialog.h
    QWidget(h: dialogH, owned: false).setWindowTitle("Switch Buffer")
    QWidget(h: dialogH, owned: false).resize(cint 480, cint 320)

    var searchBox = QLineEdit.create()
    searchBox.owned = false
    searchBox.setPlaceholderText("Search open buffers...")

    var listWidget = QListWidget.create()
    listWidget.owned = false
    let listH = listWidget.h

    var layout = QVBoxLayout.create()
    layout.owned = false
    layout.addWidget(QWidget(h: searchBox.h, owned: false))
    layout.addWidget(QWidget(h: listWidget.h, owned: false))
    QWidget(h: dialogH, owned: false).setLayout(QLayout(h: layout.h, owned: false))

    var filteredKeys: seq[string]

    proc populate(query: string) {.raises: [].} =
      try:
        let lw = QListWidget(h: listH, owned: false)
        lw.clear()
        var matches: seq[(int, string, string)]
        for (display, key) in entries:
          let score = fuzzyScore(query, display)
          if score >= 0:
            matches.add((score, display, key))
        matches.sort(proc(a, b: (int, string, string)): int {.raises: [].} = cmp(b[0], a[0]))
        filteredKeys.setLen(0)
        for (_, display, key) in matches:
          lw.addItem(display)
          filteredKeys.add(key)
        if lw.count() > 0:
          lw.setCurrentRow(cint 0)
      except: discard

    populate("")

    searchBox.onTextChanged do(text: openArray[char]) {.raises: [].}:
      populate(toStr(text))

    # Ctrl+N = next item
    var nextSc = QShortcut.create(QKeySequence.create("Ctrl+N"),
                                  QObject(h: dialogH, owned: false))
    nextSc.owned = false
    nextSc.setContext(cint 2)
    nextSc.onActivated do() {.raises: [].}:
      let lw = QListWidget(h: listH, owned: false)
      let next = min(lw.currentRow() + cint 1, lw.count() - cint 1)
      lw.setCurrentRow(next)

    # Ctrl+B = previous item
    var prevSc = QShortcut.create(QKeySequence.create("Ctrl+B"),
                                  QObject(h: dialogH, owned: false))
    prevSc.owned = false
    prevSc.setContext(cint 2)
    prevSc.onActivated do() {.raises: [].}:
      let lw = QListWidget(h: listH, owned: false)
      let prev = max(lw.currentRow() - cint 1, cint 0)
      lw.setCurrentRow(prev)

    # Enter = open current selection
    var enterSc = QShortcut.create(QKeySequence.create("Return"),
                                   QObject(h: dialogH, owned: false))
    enterSc.owned = false
    enterSc.setContext(cint 2)
    enterSc.onActivated do() {.raises: [].}:
      let lw = QListWidget(h: listH, owned: false)
      let row = lw.currentRow()
      if row >= 0 and row < cint(filteredKeys.len):
        let key = filteredKeys[row]
        QDialog(h: dialogH, owned: false).accept()
        onSelected(key)

    # Double-click = open
    listWidget.onItemDoubleClicked do(item: QListWidgetItem) {.raises: [].}:
      try:
        let lw = QListWidget(h: listH, owned: false)
        let row = lw.row(item)
        if row >= 0 and row < cint(filteredKeys.len):
          let key = filteredKeys[row]
          QDialog(h: dialogH, owned: false).accept()
          onSelected(key)
      except: discard

    discard QDialog(h: dialogH, owned: false).exec()
  except: discard
