## Nide — a simple nest counter for now: two buttons and a label bound to the
## model's count.

import nest

type
  Nide = object

widget nideApplication(model: Nide):
  ui.label(ui.id(), "Hello, World!")

when isMainModule:
  runApp(AppConfig.init(width = 360, height = 180, title = "Nide Counter"),
         Nide(), nideApplication)
