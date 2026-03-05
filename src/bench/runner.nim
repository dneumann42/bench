import std/os
import std/posix
import seaqt/[qwidget, qvboxlayout, qhboxlayout, qlayout, qplaintextedit, qfont,
              qdialog, qpushbutton, qlabel, qprocess, qobject]

proc runCommand*(parent: QWidget, title, command: string,
                 onBackground: proc(reopen: proc() {.raises: [].}) {.raises: [].} = nil) {.raises: [].} =
  try:
    var dialog = QDialog.create(parent)
    dialog.owned = false
    let dialogH = dialog.h
    QWidget(h: dialogH, owned: false).setWindowTitle(title)
    QWidget(h: dialogH, owned: false).resize(cint 640, cint 400)

    var output = QPlainTextEdit.create()
    output.owned = false
    output.setReadOnly(true)
    var font = QFont.create("Monospace")
    font.setStyleHint(cint 2)  # TypeWriter
    QWidget(h: output.h, owned: false).setFont(font)

    var killBtn = QPushButton.create("Kill")
    killBtn.owned = false

    var closeBtn = QPushButton.create("Close")
    closeBtn.owned = false

    var statusLabel = QLabel.create("Running...")
    statusLabel.owned = false

    var btnRow = QHBoxLayout.create()
    btnRow.owned = false
    btnRow.addWidget(QWidget(h: statusLabel.h, owned: false))
    btnRow.addStretch()
    btnRow.addWidget(QWidget(h: killBtn.h, owned: false))
    btnRow.addWidget(QWidget(h: closeBtn.h, owned: false))

    var mainLayout = QVBoxLayout.create()
    mainLayout.owned = false
    mainLayout.addWidget(QWidget(h: output.h, owned: false))
    mainLayout.addLayout(QLayout(h: btnRow.h, owned: false))
    QWidget(h: dialogH, owned: false).setLayout(QLayout(h: mainLayout.h, owned: false))

    # Process parented to dialog — Qt auto-cleans on dialog destroy
    var process = QProcess.create(QObject(h: dialogH, owned: false))
    process.owned = false
    let processH = process.h
    let outputH  = output.h
    let statusH  = statusLabel.h
    let killBtnH = killBtn.h

    var running: ref bool
    new(running)
    running[] = true

    process.setProcessChannelMode(cint 1)   # MergedChannels
    process.setWorkingDirectory(getCurrentDir())

    process.onReadyReadStandardOutput do() {.raises: [].}:
      try:
        let bytes = QProcess(h: processH, owned: false).readAllStandardOutput()
        if bytes.len > 0:
          let pte = QPlainTextEdit(h: outputH, owned: false)
          pte.moveCursor(cint 11)   # End
          pte.insertPlainText(toOpenArray(
            cast[ptr UncheckedArray[char]](unsafeAddr bytes[0]), 0, bytes.high))
          pte.ensureCursorVisible()
      except: discard

    process.onFinished do(exitCode: cint) {.raises: [].}:
      try:
        running[] = false
        let bytes = QProcess(h: processH, owned: false).readAllStandardOutput()
        if bytes.len > 0:
          let pte = QPlainTextEdit(h: outputH, owned: false)
          pte.moveCursor(cint 11)
          pte.insertPlainText(toOpenArray(
            cast[ptr UncheckedArray[char]](unsafeAddr bytes[0]), 0, bytes.high))
          pte.ensureCursorVisible()
        QLabel(h: statusH, owned: false).setText(
          "Finished (exit code: " & $exitCode & ")")
        QWidget(h: killBtnH, owned: false).setEnabled(false)
      except: discard

    killBtn.onClicked do() {.raises: [].}:
      let pid = QProcess(h: processH, owned: false).processId()
      if pid > 0:
        discard posix.kill(Pid(-pid), SIGKILL)  # kill entire process group
      QProcess(h: processH, owned: false).kill()

    closeBtn.onClicked do() {.raises: [].}:
      QWidget(h: dialogH, owned: false).hide()
      if running[] and onBackground != nil:
        let reopenProc = proc() {.raises: [].} =
          QWidget(h: dialogH, owned: false).show()
        onBackground(reopenProc)

    dialog.onRejected do() {.raises: [].}:
      if running[] and onBackground != nil:
        let reopenProc = proc() {.raises: [].} =
          QWidget(h: dialogH, owned: false).show()
        onBackground(reopenProc)

    process.start("bash", @["-c", command])
    QWidget(h: dialogH, owned: false).show()
  except: discard
