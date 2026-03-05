import std/unittest
import bench/logparser

suite "parseLine":
  test "error line":
    let ll = parseLine("/home/user/proj/src/main.nim(42, 10) Error: undeclared identifier: 'foo'")
    check ll.level == llError
    check ll.file  == "/home/user/proj/src/main.nim"
    check ll.line  == 42
    check ll.col   == 10
    check ll.raw   == "/home/user/proj/src/main.nim(42, 10) Error: undeclared identifier: 'foo'"

  test "warning line":
    let ll = parseLine("/home/user/proj/src/main.nim(7, 3) Warning: deprecated")
    check ll.level == llWarning
    check ll.file  == "/home/user/proj/src/main.nim"
    check ll.line  == 7
    check ll.col   == 3

  test "hint line":
    let ll = parseLine("/home/user/proj/src/main.nim(1, 1) Hint: processing [Processing]")
    check ll.level == llHint
    check ll.file  == "/home/user/proj/src/main.nim"
    check ll.line  == 1
    check ll.col   == 1

  test "plain output line is llOther":
    let ll = parseLine("Building bench/bench using c backend")
    check ll.level == llOther
    check ll.file  == ""
    check ll.line  == 0
    check ll.col   == 0

  test "empty string is llOther":
    let ll = parseLine("")
    check ll.level == llOther

  test "line with parens but unknown level is llOther":
    let ll = parseLine("/some/file.nim(5, 2) Note: something")
    check ll.level == llOther
    check ll.file  == ""

  test "missing close paren is llOther":
    let ll = parseLine("/some/file.nim(5, 2 Error: oops")
    check ll.level == llOther

  test "non-numeric coords are llOther":
    let ll = parseLine("/some/file.nim(abc, def) Error: oops")
    check ll.level == llOther

  test "raw is always preserved":
    let s = "some random output"
    check parseLine(s).raw == s

  test "single-char path before paren is ignored (paren < 1 guard)":
    # paren at index 0 should return llOther
    let ll = parseLine("(1, 2) Error: x")
    check ll.level == llOther
