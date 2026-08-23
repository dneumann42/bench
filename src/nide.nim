import std/[algorithm, os, sets, tables]

import nest, owl
import nest/dialogs
import sdl3

import buffers, commands, panes
import widgets/toolbar

const NideCommandsSource = staticRead"commands.owl"
const NideToolbarSource = staticRead"toolbar.owl"
const
  MinPaneWidth = 180.0
  MinPaneHeight = 140.0

type
  PendingFileAction = enum
    NoFileAction
    OpenFileAction
    SaveFileAction

  SaveDialogRequest = ref object
    callback: proc(path: string)

  Nide = object
    evaluator: Evaluator
    toolbars: Toolbars
    statusbar: Statusbar
    buffers: BufferManager
    panes: PaneManager
    requestedActions: HashSet[string]
    splitOrientation: string
    commandStatus: string
    pendingFileAction: PendingFileAction
    pendingPath: string
    status: string
    statusbarStatus: string

var pendingSaveDialogs: seq[SaveDialogRequest]
var pickedFileAction: PendingFileAction
var pickedPath: string

proc removePending(request: SaveDialogRequest) =
  let index = pendingSaveDialogs.find(request)
  if index >= 0:
    pendingSaveDialogs.delete(index)

proc saveFileCallback(
    userdata: pointer, filelist: cstringArray, filter: cint
) {.cdecl.} =
  discard filter
  let request = cast[SaveDialogRequest](userdata)
  if not filelist.isNil and not filelist[0].isNil and
      not request.callback.isNil:
    request.callback($filelist[0])
  removePending(request)

proc pickSaveFile(callback: proc(path: string)) =
  discard sdl3.clearError()
  let request = SaveDialogRequest(callback: callback)
  pendingSaveDialogs.add request
  sdl3.showSaveFileDialog(
    saveFileCallback,
    cast[pointer](request),
    nil,
    nil,
    0,
    nil,
  )

proc initNide(): Nide =
  result = Nide(evaluator: Evaluator.init(), toolbars: initToolbars(),
      statusbar: initStatusbar(),
      buffers: BufferManager.init(),
      requestedActions: initHashSet[string](),
      status: "Ready")
  let rootBuffer = result.buffers.newScratchBuffer()
  result.panes = PaneManager.init(rootBuffer)

proc activeBufferID(model: Nide): BufferID =
  model.panes.activeBufferID()

proc requestOpenFile(model: var Nide) =
  discard model
  dialogs.browse(proc(path: string) =
    pickedFileAction = OpenFileAction
    pickedPath = path
  )

proc requestSaveFile(model: var Nide) =
  discard model
  pickSaveFile(proc(path: string) =
    pickedFileAction = SaveFileAction
    pickedPath = path
  )

proc newFile(model: var Nide) =
  let id = model.activeBufferID()
  model.buffers.replaceWithScratch(id)
  model.status = "New file"

proc openFile(model: var Nide, path: string) =
  let id = model.activeBufferID()
  try:
    model.buffers.replaceWithFile(id, path)
    model.status = "Opened " & path
  except CatchableError as error:
    model.status = "Open failed: " & error.msg

proc saveFileAs(model: var Nide, path: string) =
  let id = model.activeBufferID()
  try:
    model.buffers.saveBufferAs(id, path)
    model.status = "Saved " & path
  except CatchableError as error:
    model.status = "Save failed: " & error.msg

proc markActiveBufferSaved(model: var Nide) =
  let id = model.activeBufferID()
  if model.buffers.hasBuffer(id):
    model.buffers.buffers[id].savedText = model.buffers.buffers[id].editor.text

proc splitColumn(model: var Nide) =
  let bufferID = model.buffers.newScratchBuffer()
  discard model.panes.addColumn(bufferID)
  model.status = "Split column"

proc splitRow(model: var Nide) =
  let bufferID = model.buffers.newScratchBuffer()
  discard model.panes.addRow(bufferID)
  model.status = "Split row"

proc unsplitPane(model: var Nide) =
  let bufferID = model.panes.unsplitActive()
  if bufferID == InvalidBufferID:
    model.status = "Cannot unsplit the last pane"
    return
  if model.buffers.hasBuffer(bufferID):
    model.buffers.buffers.del(bufferID)
  model.status = "Unsplit pane"

proc bufferIDs(model: Nide): seq[string] =
  for id in model.buffers.buffers.keys:
    result.add id
  result.sort()

proc resetCommandBindings(model: var Nide) =
  model.evaluator.env.bindEmptyList(VarRequestedActions)
  var activeBufferPath = ""
  var activeBufferText = ""
  let active = model.activeBufferID()
  if model.buffers.hasBuffer(active):
    let buffer = model.buffers.buffers[active]
    activeBufferPath = buffer.path
    activeBufferText = buffer.editor.text
  model.evaluator.env.bindValue(VarState, stateSnapshot(
    model.bufferIDs(),
    activeBufferPath,
    activeBufferText,
  ))
  model.evaluator.env.bindText(VarSplitOrientation, "")
  model.evaluator.env.bindText(VarStatus, model.status)

proc syncCommandBindings(model: var Nide) =
  model.requestedActions = model.evaluator.env.readTextSet(VarRequestedActions)
  model.splitOrientation = model.evaluator.env.readText(VarSplitOrientation)
  model.commandStatus = model.evaluator.env.readText(VarStatus)

proc processCommandIOState(model: var Nide) =
  if ActionNewFile in model.requestedActions:
    model.newFile()
  if ActionOpenFileDialog in model.requestedActions:
    model.requestOpenFile()
  if ActionSaveFileAsDialog in model.requestedActions:
    model.requestSaveFile()
  if ActionMarkBufferSaved in model.requestedActions:
    model.markActiveBufferSaved()

proc processCommandPaneState(model: var Nide) =
  if ActionUnsplitPane in model.requestedActions:
    model.unsplitPane()
  case model.splitOrientation
  of "column":
    model.splitColumn()
  of "row":
    model.splitRow()
  else:
    discard

proc processCommandState(model: var Nide) =
  model.processCommandIOState()
  model.processCommandPaneState()
  if model.commandStatus.len > 0:
    model.status = model.commandStatus

proc runNideSource(model: var Nide, source, path: string) =
  model.resetCommandBindings()
  try:
    discard model.evaluator.exec(parse(source, path))
    model.syncCommandBindings()
    model.processCommandState()
  except OwlError:
    model.resetCommandBindings()
    raise

proc runCommand(model: var Nide, commandID: string) =
  if commandID.len == 0:
    return
  try:
    model.runNideSource(commandID & "\n", commandID)
  except OwlError as error:
    model.status = "Command failed: " & error.msg

proc handleToolbarEvent(model: var Nide, event: ToolbarEvent) =
  case event.kind
  of MenuClicked:
    discard
  of MenuItemClicked, ToolClicked:
    model.runCommand(event.commandID)

proc handleStatusbarEvent(model: var Nide, event: StatusbarEvent) =
  model.runCommand(event.commandID)

proc refreshStatusbar(model: var Nide) =
  if model.statusbarStatus == model.status:
    return
  model.evaluator.env.bindText(VarStatus, model.status)
  try:
    discard model.evaluator.exec(parse(NideToolbarSource,
        currentSourcePath().parentDir / "toolbar.owl"))
    model.statusbar = model.evaluator.env.readStatusbar("nide-statusbar")
    model.statusbarStatus = model.status
  except OwlError as error:
    model.statusbarStatus = model.status
    model.status = "Statusbar failed: " & error.msg

proc processPendingFileAction(model: var Nide) =
  if pickedFileAction != NoFileAction:
    model.pendingFileAction = pickedFileAction
    model.pendingPath = pickedPath
    pickedFileAction = NoFileAction
    pickedPath = ""

  case model.pendingFileAction
  of NoFileAction:
    discard
  of OpenFileAction:
    model.openFile(model.pendingPath)
  of SaveFileAction:
    model.saveFileAs(model.pendingPath)
  model.pendingFileAction = NoFileAction
  model.pendingPath = ""

proc bufferTitle(buffer: Buffer): string =
  result = buffer.name
  if buffer.dirty:
    result = "*" & result

proc layoutPane(ui: var UI, model: var Nide, paneID: PaneID) =
  if paneID == InvalidPaneID or paneID notin model.panes.panes:
    return

  let pane = model.panes.panes[paneID]
  if pane.isLeaf:
    if not model.buffers.hasBuffer(pane.bufferID):
      return

    let active = paneID == model.panes.activePane
    let panelID = ui.id("pane", paneID)
    let editorID = ui.id("editor", pane.bufferID)
    let background =
      if active: color(42, 94, 118) else: color(35, 40, 44)

    ui.panel(panelID, cfg(width = fill(min = MinPaneWidth),
        height = fill(min = MinPaneHeight), padding = 3, gap = 2,
        alignSelf = AlignStretch).withBackground(background)):
      ui.row(ui.id("paneHeader", paneID), cfg(width = fill(), height = fit(),
          gap = 8, alignItems = AlignCenter)):
        ui.label(ui.id("paneTitle", paneID),
            bufferTitle(model.buffers.buffers[pane.bufferID]), width = fill())
      ui.textEditor(editorID, model.buffers.buffers[pane.bufferID].editor,
          width = fill(min = MinPaneWidth), height = fill(min = MinPaneHeight),
          fontName = "editor", lineNumbers = true, scrollbars = true)

    if ui.clicked(panelID) or ui.focused(editorID):
      model.panes.focus(paneID)
  elif pane.orientation == Row:
    ui.row(ui.id("row", paneID), cfg(width = fill(min = MinPaneWidth),
        height = fill(min = MinPaneHeight), gap = 4,
        alignSelf = AlignStretch)):
      for child in pane.children:
        ui.layoutPane(model, child)
  else:
    ui.column(ui.id("column", paneID), cfg(width = fill(min = MinPaneWidth),
        height = fill(min = MinPaneHeight), gap = 4,
        alignSelf = AlignStretch)):
      for child in pane.children:
        ui.layoutPane(model, child)

widget nideApplication(model: var Nide):
  model.processPendingFileAction()
  model.refreshStatusbar()

  ui.column(ui.id("root"), cfg(width = fill(), height = fill(), gap = 0)):
    for event in ui.toolbarDock(model.toolbars, TopDock):
      model.handleToolbarEvent(event)

    ui.row(ui.id("workspaceDockRow"), cfg(width = fill(), height = fill(),
        gap = 0, alignSelf = AlignStretch)):
      for event in ui.toolbarDock(model.toolbars, LeftDock):
        model.handleToolbarEvent(event)

      ui.panel(ui.id("workspace"), cfg(width = fill(), height = fill(),
          padding = 6, gap = 4)):
        ui.row(ui.id("workspaceRoot"), cfg(width = fill(min = MinPaneWidth),
            height = fill(min = MinPaneHeight), gap = 0,
            alignSelf = AlignStretch)):
          ui.layoutPane(model, model.panes.rootPane)

      for event in ui.toolbarDock(model.toolbars, RightDock):
        model.handleToolbarEvent(event)

    for event in ui.toolbarDock(model.toolbars, BottomDock):
      model.handleToolbarEvent(event)

    for event in ui.statusbar(model.statusbar):
      model.handleStatusbarEvent(event)

when isMainModule:
  let config = AppConfig.init(width = 900, height = 640, title = "Nide")
  var nide = initNide()
  nide.evaluator.registerInternalCommands()
  nide.evaluator.registerToolbarBuilderCommands()

  try:
    nide.runNideSource(NideCommandsSource, currentSourcePath().parentDir /
        "commands.owl")
    nide.runNideSource(NideToolbarSource, currentSourcePath().parentDir /
        "toolbar.owl")
    nide.toolbars = nide.evaluator.env.readToolbars("nide-toolbars")
    nide.statusbar = nide.evaluator.env.readStatusbar("nide-statusbar")
    nide.statusbarStatus = nide.status
  except OwlError as error:
    stderr.write report(error, useColor = true)
    quit 1

  runApp(config, nide, nideApplication)
