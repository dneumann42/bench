import seaqt/[qapplication]

import bench/[application, toolbar, buffers]

proc start() =
  let _ = QApplication.create()
  var application = Application.new()
  QApplication.setApplicationName("Bench DEV 0.0.0")
  application.build()
  application.show()
  quit QApplication.exec().int

when isMainModule:
  start()
