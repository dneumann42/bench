# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# nest requires the sdl3 backend define (mirrors ~/nest/config.nims)
--d:sdl3
