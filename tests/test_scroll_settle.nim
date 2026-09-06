## Scrolling in the real editor, driven by the real main loop.
##
## A wheel notch moves a scroll container's target and the offset eases toward
## it over the frames that follow. Those frames have to come from the container
## asking for them: if the loop answers with a repaint of the retained frame,
## or does not consider the request due, the list stops dead the instant the
## wheel does and only moves again when unrelated input forces a rebuild --
## which is what a scroll that animates only while the mouse is moving is.
##
## This boots the editor and runs `application` over a scripted event stream,
## because that is the only place the bug lives. A hand-rolled stand-in for the
## loop does not advance the frame clock the way the real one does, and the
## frame clock is exactly what the bug is about.
##
##   nim c -r -d:release -d:nideNoMain tests/test_scroll_settle.nim

import std/[strformat, unittest]

import nest/[appConfig, coords, input, palette, resources, runtime, screen, ui]
import nest/owldsl
import owl

include ../src/nide

type Script = object
  pending: seq[input.Event]
  next: int
  ticks: int
  timeouts: int
  blockedForever: bool

var script: Script

proc scriptedPoll(e: var input.Event, flags: set[InputFlag]): bool {.nimcall.} =
  discard (e, flags)
  false

proc scriptedWait(
    e: var input.Event, timeoutMs: int, flags: set[InputFlag]
): bool {.nimcall.} =
  discard flags
  if script.next < script.pending.len:
    e = script.pending[script.next]
    inc script.next
    inc script.ticks
    return true
  if timeoutMs < 0:
    script.blockedForever = true
    e = input.Event(kind: QuitEvent)
    return true
  inc script.timeouts
  if script.timeouts > 500:
    e = input.Event(kind: QuitEvent)
    return true
  script.ticks += max(timeoutMs, 1)
  false

proc scriptedTicks(): int {.nimcall.} =
  script.ticks

proc scriptedSleep(ms: int) {.nimcall.} =
  script.ticks += max(ms, 0)

proc scriptedShutdown() {.nimcall.} =
  discard

proc installScript(events: seq[input.Event]) =
  script = Script(pending: events, next: 0, ticks: 1)
  inputRelays = InputRelays(
    pollEvent: scriptedPoll,
    waitEvent: scriptedWait,
    getTicks: scriptedTicks,
    sleep: scriptedSleep,
    shutdown: scriptedShutdown,
  )

proc stubFonts() =
  fontRelays = FontRelays(
    openFont: proc(path: string, size: int, metrics: var FontMetrics): Font =
    discard path
    metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
    Font(max(size, 1)),
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
    discard (f, x, y, fg, bg)
    TextExtent(w: max(text.len, 1) * 9, h: 18),
  )

proc stubScreen() =
  drawRelays = DrawRelays(
    fillRect: proc(r: coords.Rect, color: screen.Color) =
    discard (r, color),
    lineRect: proc(r: coords.Rect, color: screen.Color) =
    discard (r, color),
    drawLine: proc(x1, y1, x2, y2: int, color: screen.Color) =
    discard (x1, y1, x2, y2, color),
    drawPoint: proc(x, y: int, color: screen.Color) =
    discard (x, y, color),
    loadImage: proc(path: string): screen.Image =
    discard path
    screen.Image(1),
    freeImage: proc(img: screen.Image) =
    discard img,
    drawImage: proc(img: screen.Image, src, dst: coords.Rect) =
    discard (img, src, dst),
    drawImageOpacity: proc(img: screen.Image, src, dst: coords.Rect,
        opacity: float64) =
    discard (img, src, dst, opacity),
    imageSize: proc(img: screen.Image): TextExtent =
    discard img
    TextExtent(w: 32, h: 32),
  )
  windowRelays.createWindow = proc(layout: var ScreenLayout) =
    layout = ScreenLayout(width: 900, height: 640, scaleX: 1, scaleY: 1)
  windowRelays.refresh = proc() = discard
  windowRelays.saveState = proc() = discard
  windowRelays.restoreState = proc() = discard
  windowRelays.setClipRect = proc(r: coords.Rect) = discard
  windowRelays.setCursor = proc(c: CursorKind) = discard
  windowRelays.setWindowTitle = proc(title: string) = discard
  windowRelays.moveWindowBy = proc(dx, dy: int) = discard

proc bootedNide(): Nide =
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

type Run = object
  offsets: seq[float64]
  fullFrames: int
  wentIdle: bool
  wheelSent: bool
  listFrame: Frame

proc runPalette(notches: float64): Run =
  ## Boot the editor with the command palette open and run the real loop.
  ##
  ## The wheel is aimed from the solved layout rather than guessed at: a notch
  ## delivered outside the list is not a scroll, and a test that scrolls
  ## nothing proves nothing.
  var model = bootedNide()
  var ui = UI.init()
  var installed = false
  var wheelSent = false
  var listID = InvalidWidgetID
  var offsets: seq[float64]
  var fullFrames = 0
  let cfg = AppConfig.init(width = 900, height = 640, title = "settle")
  application cfg, ui:
    if not installed:
      installed = true
      installScript(@[input.Event(kind: KeyDownEvent, key: KeyP,
          mods: {CtrlPressed, ShiftPressed})])
      stubScreen()
    ui.layout:
      ui.nideApplication(model)
    inc fullFrames
    if listID != InvalidWidgetID:
      offsets.add ui.scrollOffset(listID).y
    if not wheelSent:
      # Find the list by asking the UI which of its scroll containers can
      # actually scroll, rather than guessing at the id the panel gave it.
      for (id, frame) in ui.scrollContainers:
        if ui.scrollExtent(id).maxY > 1.0 and frame.height > 40.0:
          wheelSent = true
          listID = id
          result.listFrame = frame
          script.pending.add input.Event(
            kind: MouseWheelEvent,
            mouseX: (frame.x + frame.width * 0.5).toInt,
            mouseY: (frame.y + frame.height * 0.5).toInt,
            wheelY: notches,
          )
          break
  result.offsets = offsets
  result.fullFrames = fullFrames
  result.wentIdle = script.blockedForever
  result.wheelSent = wheelSent

proc movingFrames(offsets: seq[float64]): int =
  for i in 1 ..< offsets.len:
    if abs(offsets[i] - offsets[i - 1]) > 0.01:
      inc result

suite "editor scroll settling":
  setup:
    stubFonts()
    stubScreen()

  test "a wheel notch keeps easing with no further input":
    let run = runPalette(-4.0)
    let moving = movingFrames(run.offsets)
    checkpoint(&"{run.fullFrames} full frames, {moving} moving, list " &
      &"{run.listFrame}, offsets {run.offsets}")
    check run.wheelSent
    check run.listFrame.height > 0
    check run.offsets[^1] > 0.0
    check moving >= 3

  test "the editor goes back to sleep once the scroll has settled":
    let run = runPalette(-4.0)
    checkpoint(&"settled at {run.offsets[^1]} after {run.fullFrames} frames")
    check run.wentIdle
    check run.fullFrames < 80
