import seaqt/[qwidget, qdialog]
import toml_serialization, os

import theme

type
  AppearanceSettings* = object
    themeMode: Theme
    transparent: bool
    lineNumbers: bool

  Settings* = object
    appearance: AppearanceSettings
  
proc load*(T: typedesc[Settings]): T {.raises: [].} =
  result = T(themeMode: Dark)
  try:
    if not dirExists(getConfigDir() / "bench"):
      createDir(getConfigDir() / "bench")
    let path = getConfigDir() / "bench" / "settings.toml"
    if fileExists(path):
      result = Toml.decode(readFile(path), typeof result)
  except:
    echo getCurrentExceptionMsg()

proc write*(settings: Settings) {.raises: [].} =
  try:
    if not dirExists(getConfigDir() / "bench"):
      createDir(getConfigDir() / "bench")

    let path = getConfigDir() / "bench" / "settings.toml"
    writeFile(path, Toml.encode(settings))
  except:
    echo getCurrentExceptionMsg()

proc showSettingsDialog*(
  parent: QWidget
) {.raises: [].} =
  try:
    var dialog = QDialog.create(parent)
    dialog.owned = false
    let dialogH = dialog.h
    
    QWidget(h: dialogH, owned: false).setWindowTitle("Settings")
    QWidget(h: dialogH, owned: false).resize(cint 640, cint 480)

    discard QDialog(h: dialogH, owned: false).exec()
  except:
    discard

when isMainModule:
  var settings = Settings.load()
  echo settings
  settings.transparent = not settings.transparent
  settings.write()
  block:
    var settings = Settings.load()
    echo settings
  