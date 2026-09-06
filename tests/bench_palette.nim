## Frame-cost benchmark for the command palette.
##
## Boots the editor headlessly, renders a fixed number of real frames in a few
## states, and reports milliseconds per frame and bytes allocated per frame.
## Run it before and after a change; the numbers are what say whether the change
## was worth making.
##
##   nim c -r -d:release -d:nideNoMain tests/bench_palette.nim [frames]
##
## Add `-d:nestBench` to get the per-phase breakdown of every scenario, and
## `-d:nestBenchDetail` on top of that to break the draw pass down per
## component. `NEST_BENCH_JSON=path` also writes the last scenario as JSON.

import std/[monotimes, os, sequtils, strformat, strutils]
from std/times import inNanoseconds

import nest/[bench, coords, input, palette, resources, screen, ui]
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

proc frame(ui: var UI, model: var Nide) =
  bench.frame:
    ui.beginInputFrame()
    ui.layout:
      ui.nideApplication(model)
    ui.finishInputFrame()

proc frameWithKey(ui: var UI, model: var Nide, key: input.KeyCode,
    mods: set[Modifier] = {}) =
  bench.frame:
    ui.beginInputFrame()
    ui.keyDown(key, mods)
    ui.layout:
      ui.nideApplication(model)
    ui.finishInputFrame()

proc frameWithText(ui: var UI, model: var Nide, text: string) =
  bench.frame:
    ui.beginInputFrame()
    ui.textInput(text)
    ui.layout:
      ui.nideApplication(model)
    ui.finishInputFrame()

proc frameResized(ui: var UI, model: var Nide, width, height: int) =
  bench.frame:
    ui.beginInputFrame()
    ui.resizeWindow(width, height)
    ui.layout:
      ui.nideApplication(model)
    ui.finishInputFrame()

type Sample = object
  label: string
  msPerFrame: float64
  bytesPerFrame: int

proc report(samples: seq[Sample]) =
  echo ""
  echo "  ", "state".alignLeft(28), "ms/frame".align(10), "KB/frame".align(12)
  echo "  ", repeat('-', 50)
  for sample in samples:
    echo "  ", sample.label.alignLeft(28),
      (&"{sample.msPerFrame:.3f}").align(10),
      (&"{sample.bytesPerFrame.float64 / 1024.0:.1f}").align(12)
  echo ""

proc measure(label: string, frames: int, body: proc(index: int)): Sample =
  # One warm pass first: the first frame after a state change pays for caches
  # and font loads that steady-state frames do not.
  body(0)
  bench.reset()
  bench.setLabel(label)
  let
    startMem = getOccupiedMem()
    start = getMonoTime()
  for index in 1 .. frames:
    body(index)
  let
    elapsed = (getMonoTime() - start).inNanoseconds.float64 / 1_000_000.0
    usedMem = getOccupiedMem() - startMem
  when bench.enabled():
    echo bench.summary()
  Sample(
    label: label,
    msPerFrame: elapsed / frames.float64,
    bytesPerFrame: usedMem div frames,
  )

proc main() =
  stubFonts()
  stubDrawRelays()
  let frames =
    if paramCount() >= 1:
      try: parseInt(paramStr(1)) except ValueError: 120
    else:
      120

  var samples: seq[Sample]

  block:
    var model = bootedNide()
    var ui = newUI()
    samples.add measure("editor only", frames, proc(index: int) =
      frame(ui, model))

  block:
    var model = bootedNide()
    var ui = newUI()
    ui.frameWithKey(model, KeyP, {CtrlPressed, ShiftPressed})
    doAssert model.panels.anyIt(it.id == "command-palette" and it.open),
      "palette did not open; benchmark is measuring the wrong thing"
    samples.add measure("palette open, idle", frames, proc(index: int) =
      frame(ui, model))

  block:
    var model = bootedNide()
    var ui = newUI()
    samples.add measure("editor only, inert key", frames, proc(index: int) =
      ui.frameWithKey(model, KeyF12))

  block:
    var model = bootedNide()
    var ui = newUI()
    const editorQuery = "editorfind"
    samples.add measure("editor only, typing", frames, proc(index: int) =
      frameWithText(ui, model, $editorQuery[index mod editorQuery.len]))

  block:
    var model = bootedNide()
    var ui = newUI()
    ui.frameWithKey(model, KeyP, {CtrlPressed, ShiftPressed})
    const query = "editorfind"
    samples.add measure("palette, typing", frames, proc(index: int) =
      frameWithText(ui, model, $query[index mod query.len]))

  block:
    var model = bootedNide()
    var ui = newUI()
    ui.frameWithKey(model, KeyP, {CtrlPressed, ShiftPressed})
    samples.add measure("palette, moving selection", frames, proc(index: int) =
      ui.frameWithKey(model, if index mod 2 == 0: KeyDown else: KeyUp))

  block:
    var model = bootedNide()
    var ui = newUI()
    frame(ui, model)
    samples.add measure("resize, rebuilt", frames, proc(index: int) =
      # A compositor drag reports a new size every frame; this is the shape of
      # the event stream, not a single jump to a final size.
      let step = index mod 120
      frameResized(ui, model, 900 + step * 4, 640 + step * 2))

  block:
    var model = bootedNide()
    var ui = newUI()
    frame(ui, model)
    samples.add measure("resize, fast pass", frames, proc(index: int) =
      # What the runtime actually does with a resize event: re-solve the
      # frame that is already on screen rather than rebuild it.
      let step = index mod 120
      bench.frame:
        ui.beginInputFrame()
        doAssert ui.resolveRetainedFrame(900 + step * 4, 640 + step * 2),
          "the resize fast pass refused; this is measuring the wrong thing"
        ui.finishInputFrame())

  block:
    var model = bootedNide()
    var ui = newUI()
    frame(ui, model)
    samples.add measure("hover, rebuilt", frames, proc(index: int) =
      bench.frame:
        ui.beginInputFrame()
        ui.mouseMove(40 + index mod 400, 20 + index mod 300)
        ui.layout:
          ui.nideApplication(model)
        ui.finishInputFrame())

  block:
    var model = bootedNide()
    var ui = newUI()
    frame(ui, model)
    samples.add measure("hover, fast pass", frames, proc(index: int) =
      # What the runtime actually does with pointer motion: hit test against
      # the frame on screen and repaint only if the hover changed.
      bench.frame:
        ui.beginInputFrame()
        ui.mouseMove(40 + index mod 400, 20 + index mod 300)
        discard ui.updateRetainedFrame()
        ui.finishInputFrame())

  block:
    var model = bootedNide()
    var ui = newUI()
    frame(ui, model)
    samples.add measure("keybindings widget alone", frames, proc(index: int) =
      bench.frame:
        ui.beginInputFrame()
        ui.keyDown(KeyF12, {})
        ui.layout:
          model.uiRuntime.renderWidget(ui, NideSourceDir / "keybindings.owl",
              "nide-keybindings")
        ui.finishInputFrame())

  report(samples)
  bench.finish()

when isMainModule:
  main()
