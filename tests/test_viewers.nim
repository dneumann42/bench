import std/[os, strutils, unittest]

import nest/[coords, palette, resources, screen, ui]
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

proc initViewerNide(): Nide =
  result = Nide.init()
  result.evaluator.registerInternalCommands(result.bridge)
  result.uiRuntime.evaluator.registerInternalCommands(result.bridge)
  result.uiRuntime.evaluator.registerToolbarBuilderCommands()
  result.uiRuntime.evaluator.registerPanelBuilderCommands()
  registerViewerCommands(result.viewerContext, result.uiRuntime)
  result.modeRegistry = loadModeRegistry()

proc renderRoot(model: var Nide; width = 900; height = 640): UI =
  result = UI.init()
  result.initContext(width, height)
  result.loadFont("font", "", 18)
  result.loadFont("editor", "", 18)
  result.layout:
    result.layoutPane(model, model.panes.rootPane)

proc renderRootWithDraw(model: var Nide; commands: ptr seq[DrawCommand];
    width = 900;height = 640): UI =
  result = UI.init()
  var updateContext = UpdateContext(windowWidth: width, windowHeight: height)
  var drawContext = DrawContext(
    resources: Resources.new(),
    palette: Palette.init(),
    windowWidth: width,
    windowHeight: height,
    dirtyAll: true,
  )
  drawContext.drawCommands = commands
  drawContext.resources.loadFont("font", "", 18)
  drawContext.resources.loadFont("editor", "", 18)
  result.initContext(width, height)
  result.layout(updateContext, drawContext):
    result.layoutPane(model, model.panes.rootPane)

proc openedBuffer(model: Nide): Buffer =
  model.buffers.buffers[model.panes.panes[model.panes.activePane].bufferID]

proc hasDrawText(commands: seq[DrawCommand], needle: string): bool =
  for command in commands:
    if command.kind == DrawText and command.text.contains(needle):
      return true
  false

suite "Nide file viewers":
  setup:
    let originalFontRelays = fontRelays
    let originalDrawRelays = drawRelays
    stubFonts()
    stubDrawRelays()

  teardown:
    fontRelays = originalFontRelays
    drawRelays = originalDrawRelays

  test "regular files still render with the original text editor pane content":
    var model = initViewerNide()
    let path = getTempDir() / "nide-viewer-text.nim"
    writeFile(path, "echo \"still text\"\n")
    defer:
      removeFile(path)

    model.openFile(path)
    let buffer = model.openedBuffer()
    check string(buffer.fileMode) == "nim"
    check buffer.viewer == "text"

    let rendered = model.renderRoot()
    let editorFrame = rendered.widgetFrame(rendered.id("editor", buffer.id))
    check editorFrame.ok
    check editorFrame.frame.height > 500
    check not model.status.contains("Viewer")

  test "CSV viewer builds table UI in Owl and keeps raw editor out of table mode":
    var model = initViewerNide()
    let path = currentSourcePath().parentDir.parentDir / "examples" /
        "viewer-demo.csv"

    model.openFile(path)
    let buffer = model.openedBuffer()
    check string(buffer.fileMode) == "csv"
    check buffer.viewer == "csv"

    let rendered = model.renderRoot()
    let tableFrame = rendered.widgetFrame(rendered.id("csv-viewer", buffer.id,
        "table"))
    let headerFrame = rendered.widgetFrame(rendered.id("csv-viewer", buffer.id,
        "header"))
    let dataRowFrame = rendered.widgetFrame(rendered.id("csv-viewer", buffer.id,
        "row", "1"))
    let rawFrame = rendered.widgetFrame(rendered.id("viewer-editor", buffer.id,
        buffer.id & ":raw"))

    check tableFrame.ok
    check tableFrame.frame.width > 700
    check tableFrame.frame.height > 100
    check headerFrame.ok
    check dataRowFrame.ok
    check not rawFrame.ok
    check not model.status.contains("Viewer csv failed")

    var drawCommands: seq[DrawCommand]
    discard model.renderRootWithDraw(addr drawCommands)
    check drawCommands.hasDrawText("Dustin")
    check not drawCommands.hasDrawText("No CSV rows")

  test "CSV file-explorer open request remains stable across repeated frames":
    var model = initViewerNide()
    model.configureBridge()
    let path = currentSourcePath().parentDir.parentDir / "examples" /
        "viewer-demo.csv"

    model.fileExplorerOpenRequest(NideBridgeRequest(name: "file-explorer.open",
        arguments: @[text(path)]))
    model.processPendingFileAction()

    let buffer = model.openedBuffer()
    check string(buffer.fileMode) == "csv"
    check buffer.viewer == "csv"

    for frame in 0 ..< 8:
      discard frame
      let rendered = model.renderRoot()
      let tableFrame = rendered.widgetFrame(rendered.id("csv-viewer", buffer.id,
          "table"))
      check tableFrame.ok
      check tableFrame.frame.height > 100
      check not model.status.contains("Viewer csv failed")

  test "viewer data commands bind to live model after application model copy":
    let startupModel = initViewerNide()
    var model = startupModel
    let path = currentSourcePath().parentDir.parentDir / "examples" /
        "viewer-demo.csv"

    model.openFile(path)
    let buffer = model.openedBuffer()
    check string(buffer.fileMode) == "csv"

    var drawCommands: seq[DrawCommand]
    discard model.renderRootWithDraw(addr drawCommands)
    check drawCommands.hasDrawText("Dustin")
    check not drawCommands.hasDrawText("No CSV rows")
    check not model.status.contains("unknown viewer buffer id")

  test "image viewer renders toolbar plus a drawable pan/zoom image canvas":
    var model = initViewerNide()
    let path = currentSourcePath().parentDir.parentDir.parentDir /
        "isles-of-chaos" / "res" / "textures" / "water.png"

    model.openFile(path)
    let buffer = model.openedBuffer()
    check string(buffer.fileMode) == "image"
    check buffer.viewer == "image"

    var drawCommands: seq[DrawCommand]
    drawCommands.setLen(0)
    let rendered = model.renderRootWithDraw(addr drawCommands)
    let bodyFrame = rendered.widgetFrame(rendered.id("image-viewer", buffer.id,
        "body"))
    let canvasFrame = rendered.widgetFrame(rendered.id("image-viewer",
        buffer.id, "canvas"))

    check bodyFrame.ok
    check bodyFrame.frame.height > 500
    check canvasFrame.ok
    check canvasFrame.frame.width > 800
    check canvasFrame.frame.height > 500
    var hasDrawnImage = false
    for command in drawCommands:
      if command.kind == DrawImage and command.imagePath == path and
          command.dst.w > 0 and command.dst.h > 0:
        hasDrawnImage = true
    check hasDrawnImage
    check not drawCommands.hasDrawText("No image path")
    check not model.status.contains("Viewer image failed")
