import std/strutils

type
  LogLevel* = enum
    llHint, llWarning, llError, llOther

  LogLine* = object
    raw*:   string
    level*: LogLevel
    file*:  string
    line*:  int
    col*:   int

proc parseLine*(s: string): LogLine =
  result.raw   = s
  result.level = llOther
  # Pattern: /some/path.nim(42, 10) Error: ...
  let paren = s.find('(')
  if paren < 1: return
  let closeParen = s.find(')', paren)
  if closeParen < 0: return
  let coords = s[paren+1 ..< closeParen]
  let comma  = coords.find(',')
  if comma < 0: return
  try:
    result.line = parseInt(coords[0 ..< comma].strip())
    result.col  = parseInt(coords[comma+1 .. ^1].strip())
  except: return
  let after = s[closeParen+1 .. ^1]
  if after.startsWith(" Error:"):
    result.level = llError
    result.file  = s[0 ..< paren]
  elif after.startsWith(" Warning:"):
    result.level = llWarning
    result.file  = s[0 ..< paren]
  elif after.startsWith(" Hint:"):
    result.level = llHint
    result.file  = s[0 ..< paren]
