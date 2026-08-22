--path:"../nest/src"
--path:"../owl/src"
--path:"/home/dneumann/.nimble/pkgs2/chroma-1.0.0-76a12834f1b7e211e4232c1e13960accba6bd477/src"
--path:"/home/dneumann/.nimble/pkgs2/sdl3-1.0-5ecbff9ffa24a0e532bb20bccd4ea4552a2f4093/src"
--path:"/home/dneumann/.nimble/pkgs2/micros-0.1.18-69d90af9f9cfd03cf1cf89fac8dd0674146e5d83"
--path:"/home/dneumann/.nimble/pkgs2/fungus-0.1.19-f34a2327c3f2d9082836d363096ab2f99040faa4"
--path:"/home/dneumann/.nimble/pkgs2/kiwiberry-0.5.0-23a3b4115fe376c314e62dc4c9baef8dc09f7287"

# nest requires the sdl3 backend define (mirrors ~/nest/config.nims)
--d:sdl3
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
