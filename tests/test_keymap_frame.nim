## Drives real frames with real key presses.
##
## Everything else stops at the Owl layer. This boots the editor the way
## `start` does, pushes keys through nest's input, and checks what the frame
## actually did -- which is the only way a key sequence that hangs or silently
## does nothing shows up in a test.

import std/[os, strutils, unittest]

import nest/[coords, input, palette, resources, screen, ui]
import nest/owldsl
import owl

include ../src/nide

proc fakeDrawImage(img: Image, src, dst: coords.Rect) =
  discard img
  discard src
  discard dst

proc fakeDrawImageOpacity(img: Image, src, dst: coords.Rect, opacity: float64) =
  discard img
  discard src
  discard dst
  discard opacity

proc stubFonts() =
  fontRelays = FontRelays(
    openFont: proc(path: string, size: int, metrics: var FontMetrics): Font =
    discard path
    metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
    Font(size),
    closeFont: proc(f: Font) =
    discard f,
    getFontMetrics: proc(f: Font): FontMetrics =
    discard f
    FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
    measureText: proc(f: Font, text: string): TextExtent =
    discard f
    TextExtent(w: max(text.len, 1) * 9, h: 18),
    drawText: proc(f: Font, x, y: int, text: string, fg,
        bg: screen.Color): TextExtent =
    discard f
    discard x
    discard y
    discard fg
    discard bg
    TextExtent(w: max(text.len, 1) * 9, h: 18),
  )

proc stubDrawRelays() =
  drawRelays = DrawRelays(
    fillRect: proc(r: coords.Rect, color: screen.Color) =
    discard r
    discard color,
    lineRect: proc(r: coords.Rect, color: screen.Color) =
    discard r
    discard color,
    drawLine: proc(x1, y1, x2, y2: int, color: screen.Color) =
    discard x1
    discard y1
    discard x2
    discard y2
    discard color,
    drawPoint: proc(x, y: int, color: screen.Color) =
    discard x
    discard y
    discard color,
    loadImage: proc(path: string): Image =
    discard path
    Image(7),
    freeImage: proc(img: Image) =
    discard img,
    drawImage: fakeDrawImage,
    drawImageOpacity: fakeDrawImageOpacity,
    imageSize: proc(img: Image): TextExtent =
    discard img
    TextExtent(w: 320, h: 200),
  )

proc bootedNide(): Nide =
  ## The same boot `start` performs, minus the window.
  result = Nide.init()
  result.configureBridge()
  result.evaluator.registerInternalCommands(result.bridge)
  result.uiRuntime.evaluator.registerInternalCommands(result.bridge)
  result.uiRuntime.evaluator.registerToolbarBuilderCommands()
  result.uiRuntime.evaluator.registerPanelBuilderCommands()
  result.ensureNideUserFiles()
  result.modeRegistry = loadModeRegistry()
  result.loadProjectManager()
  let commandsPath = NideSourceDir / "commands.owl"
  result.runNideSource(NideCommandsSource, commandsPath)
  discard result.uiRuntime.evaluator.exec(parse(NideCommandsSource, commandsPath))
  result.uiRuntime.evaluator.env.bindText(VarStatus, result.status)
  discard result.uiRuntime.evaluator.exec(
    parse(NideLoadSource, NideSourceDir / "load.owl"))
  result.runUserConfig()
  result.toolbars = result.uiRuntime.evaluator.env.readToolbars("nide-toolbars")
  result.panels = result.uiRuntime.evaluator.env.readPanels("nide-panels")

proc newUI(): UI =
  result = UI.init()
  result.initContext(900, 640)
  result.loadFont("font", "", 18)
  result.loadFont("editor", "", 18)

proc pressKey(ui: var UI, model: var Nide, key: input.KeyCode,
    mods: set[Modifier] = {}) =
  ui.beginInputFrame()
  ui.keyDown(key, mods)
  ui.layout:
    ui.nideApplication(model)
  ui.finishInputFrame()

proc floatingPanelOpen(model: Nide, id: string): bool =
  for panel in model.panels:
    if panel.id == id and panel.open:
      return true

proc settle(ui: var UI, model: var Nide, frames = 3) =
  ## Render a few more frames with no input. A panel that throws while drawing
  ## only does so once it is actually on screen.
  for _ in 1 .. frames:
    ui.beginInputFrame()
    ui.layout:
      ui.nideApplication(model)
    ui.finishInputFrame()

suite "buffer modes":
  setup:
    let originalFontRelays = fontRelays
    let originalDrawRelays = drawRelays
    stubFonts()
    stubDrawRelays()
    var model = bootedNide()
    var ui = newUI()

  teardown:
    fontRelays = originalFontRelays
    drawRelays = originalDrawRelays

  test "opening a nim file applies syntax highlighting":
    # The mode script binds its hook to a plain `fun`, so this also guards the
    # by-name invocation path that mode hooks depend on.
    let path = NideSourceDir / "nide.nim"
    model.openFile(path)
    ui.settle(model)
    let id = model.activeBufferID()
    check model.buffers.hasBuffer(id)
    check string(model.buffers.buffers[id].fileMode) == "nim"
    check model.buffers.buffers[id].editor.syntax.rules.len > 0
    check not model.status.contains("failed")

suite "key sequences drive real frames":
  setup:
    let originalFontRelays = fontRelays
    let originalDrawRelays = drawRelays
    stubFonts()
    stubDrawRelays()
    var model = bootedNide()
    var ui = newUI()

  teardown:
    fontRelays = originalFontRelays
    drawRelays = originalDrawRelays

  test "ctrl-x f works when the key also produces text input":
    ui.beginInputFrame()
    ui.keyDown(KeyX, {CtrlPressed})
    ui.layout:
      ui.nideApplication(model)
    ui.finishInputFrame()
    ui.beginInputFrame()
    ui.keyDown(KeyF, {})
    ui.textInput("f")
    ui.layout:
      ui.nideApplication(model)
    ui.finishInputFrame()
    check model.floatingPanelOpen("find-file")

  test "ctrl-x f still works with idle frames between the two keys":
    ui.pressKey(model, KeyX, {CtrlPressed})
    ui.settle(model, 3)
    ui.pressKey(model, KeyF)
    ui.settle(model)
    check model.floatingPanelOpen("find-file")
    check model.owlErrorApp.lastError == ""

  test "ctrl-x f works when the same key press renders twice":
    ui.pressKey(model, KeyX, {CtrlPressed})
    ui.pressKey(model, KeyX, {CtrlPressed})
    ui.pressKey(model, KeyF)
    check model.floatingPanelOpen("find-file")

  test "ctrl-x f opens the file finder and it draws":
    ui.pressKey(model, KeyX, {CtrlPressed})
    ui.pressKey(model, KeyF)
    check model.floatingPanelOpen("find-file")
    ui.settle(model)
    check model.owlErrorApp.lastError == ""
    check not model.status.contains("failed")

  test "ctrl-x b opens the buffer finder and it draws":
    ui.pressKey(model, KeyX, {CtrlPressed})
    ui.pressKey(model, KeyB)
    check model.floatingPanelOpen("find-buffer")
    ui.settle(model)
    check model.owlErrorApp.lastError == ""
    check not model.status.contains("failed")

  test "ctrl-shift-p opens the command palette and it draws":
    ui.pressKey(model, KeyP, {CtrlPressed, ShiftPressed})
    check model.floatingPanelOpen("command-palette")
    ui.settle(model)
    check model.owlErrorApp.lastError == ""
    check not model.status.contains("failed")

  test "alt-x opens the command palette and it draws":
    ui.pressKey(model, KeyX, {AltPressed})
    check model.floatingPanelOpen("command-palette")
    ui.settle(model)
    check model.owlErrorApp.lastError == ""
    check not model.status.contains("failed")

  test "a half-typed prefix leaves the editor usable":
    ui.pressKey(model, KeyX, {CtrlPressed})
    ui.pressKey(model, KeyG, {CtrlPressed})
    ui.settle(model)
    check model.owlErrorApp.lastError == ""
    check not model.floatingPanelOpen("find-file")

  test "opening a panel twice does not wedge the frame":
    ui.pressKey(model, KeyX, {CtrlPressed})
    ui.pressKey(model, KeyF)
    ui.settle(model)
    ui.pressKey(model, KeyX, {CtrlPressed})
    ui.pressKey(model, KeyB)
    ui.settle(model)
    check model.owlErrorApp.lastError == ""
