import seaqt/[qwidget, qdialog, qlineedit, qformlayout, qvboxlayout, qhboxlayout, qdialogbuttonbox, qpushbutton, qfiledialog]
import bench/projects

proc showNewProjectDialog*(parent: QWidget, pm: var ProjectManager) =
  var dialog = QDialog.create(parent)

  var nameEdit    = QLineEdit.create(); nameEdit.owned    = false
  var versionEdit = QLineEdit.create(); versionEdit.owned = false
  var authorEdit  = QLineEdit.create(); authorEdit.owned  = false
  var descEdit    = QLineEdit.create(); descEdit.owned    = false
  var licenseEdit = QLineEdit.create(); licenseEdit.owned = false

  var
    pathEditRow = QWidget.create()
    pathEditRowLayout = QHBoxLayout.create()

  pathEditRow.setLayout(QLayout(h: pathEditRowLayout.h, owned: false))
  pathEditRowLayout.owned = false
  pathEditRow.owned = false

  var pathEdit = QLineEdit.create(); pathEdit.owned = false
  pathEditRowLayout.addWidget(QWidget(h: pathEdit.h, owned: false))
  QLayout(h: pathEditRowLayout.h, owned: false).setContentsMargins(0, 0, 0, 0)

  var pathEditButton = QPushButton.create("Browse"); pathEditButton.owned = false
  pathEditRowLayout.addWidget(QWidget(h: pathEditButton.h, owned: false))
  let dialogRef = QWidget(h: dialog.h, owned: false)
  pathEditButton.onClicked do():
    let dir = QFileDialog.getExistingDirectory(dialogRef)
    if dir.len > 0:
      pathEdit.setText(dir)

  nameEdit.setPlaceholderText("Project name")
  versionEdit.setPlaceholderText("0.0.1")
  pathEdit.setPlaceholderText("/path/to/project")

  var form = QFormLayout.create(); form.owned = false
  form.addRow("Name",        QWidget(h: nameEdit.h,    owned: false))
  form.addRow("Version",     QWidget(h: versionEdit.h, owned: false))
  form.addRow("Author",      QWidget(h: authorEdit.h,  owned: false))
  form.addRow("Description", QWidget(h: descEdit.h,    owned: false))
  form.addRow("License",     QWidget(h: licenseEdit.h, owned: false))
  form.addRow("Path",        QWidget(h: pathEditRow.h,    owned: false))

  # Ok=1024, Cancel=4194304 (QDialogButtonBox::StandardButton)
  var buttons = QDialogButtonBox.create2(cint(1024 or 4194304))
  buttons.owned = false
  buttons.onAccepted do(): dialog.accept()
  buttons.onRejected do(): dialog.reject()

  var mainLayout = QVBoxLayout.create(); mainLayout.owned = false
  mainLayout.addLayout(QLayout(h: form.h, owned: false))
  mainLayout.addWidget(QWidget(h: buttons.h, owned: false))

  QWidget(h: dialog.h, owned: false).setWindowTitle("New Project")
  QWidget(h: dialog.h, owned: false).setLayout(QLayout(h: mainLayout.h, owned: false))

  if dialog.exec() == 1:  # QDialog::Accepted
    pm.createProject(Project(
      name:        nameEdit.text(),
      version:     versionEdit.text(),
      author:      authorEdit.text(),
      description: descEdit.text(),
      license:     licenseEdit.text(),
      path:        pathEdit.text(),
    ))
