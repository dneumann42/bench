# Package

version       = "0.0.0"
author        = "dneumann42"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["bench"]
# backend       = "cpp"


# Dependencies

requires "nim >= 2.2.6"
requires "https://github.com/seaqt/nim-seaqt#qt-6.4"

requires "db_connector >= 0.1.0"
requires "toml_serialization >= 0.2.18"