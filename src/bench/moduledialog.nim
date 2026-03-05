import std/os
import seaqt/[qwidget, qdialog, qlineedit, qformlayout, qvboxlayout, qhboxlayout,
              qdialogbuttonbox, qpushbutton, qfiledialog]

proc showNewModuleDialog*(parent: QWidget): string =
  var dialog = QDialog.create(parent)

  var nameEdit = QLineEdit.create(); nameEdit.owned = false
  nameEdit.setPlaceholderText("module_name")

  var
    pathEditRow = QWidget.create()
    pathEditRowLayout = QHBoxLayout.create()

  pathEditRow.setLayout(QLayout(h: pathEditRowLayout.h, owned: false))
  pathEditRowLayout.owned = false
  pathEditRow.owned = false

  var pathEdit = QLineEdit.create(); pathEdit.owned = false
  pathEdit.setMinimumWidth(150)
  let defaultPath = try: getCurrentDir() / "src" except OSError: "src"
  pathEdit.setText(defaultPath)
  pathEditRowLayout.addWidget(QWidget(h: pathEdit.h, owned: false))
  QLayout(h: pathEditRowLayout.h, owned: false).setContentsMargins(0, 0, 0, 0)

  var browseBtn = QPushButton.create("Browse"); browseBtn.owned = false
  pathEditRowLayout.addWidget(QWidget(h: browseBtn.h, owned: false))
  let dialogRef = QWidget(h: dialog.h, owned: false)
  browseBtn.onClicked do():
    let dir = QFileDialog.getExistingDirectory(dialogRef)
    if dir.len > 0:
      pathEdit.setText(dir)

  var form = QFormLayout.create(); form.owned = false
  form.addRow("Name", QWidget(h: nameEdit.h, owned: false))
  form.addRow("Path", QWidget(h: pathEditRow.h, owned: false))

  # Ok=1024, Cancel=4194304 (QDialogButtonBox::StandardButton)
  var buttons = QDialogButtonBox.create2(cint(1024 or 4194304))
  buttons.owned = false
  buttons.onAccepted do(): dialog.accept()
  buttons.onRejected do(): dialog.reject()

  var mainLayout = QVBoxLayout.create(); mainLayout.owned = false
  mainLayout.addLayout(QLayout(h: form.h, owned: false))
  mainLayout.addWidget(QWidget(h: buttons.h, owned: false))

  QWidget(h: dialog.h, owned: false).setWindowTitle("New Module")
  QWidget(h: dialog.h, owned: false).setLayout(QLayout(h: mainLayout.h, owned: false))

  if dialog.exec() == 1:
    let name = nameEdit.text()
    let dir  = pathEdit.text()
    if name.len > 0 and dir.len > 0:
      let path = dir / name & ".nim"
      try:
        createDir(dir)
        writeFile(path, "when isMainModule:\n  discard\n")
        return path
      except: discard
