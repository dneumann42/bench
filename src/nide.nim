import std/[algorithm, os, streams, tables]

import nest, owl
import nest/dialogs
import nest/owldsl
import sdl3

import buffers, commands, panes, projects
import widgets/toolbar

const NideCommandsSource = staticRead"commands.owl"
const NideLoadSource = staticRead"load.owl"
const NideRunPermissiveUserConfig* {.booldefine.} = true
const NideAutoTrackOpenedProjects* {.booldefine.} = true
const
  MinPaneWidth = 180.0
  MinPaneHeight = 140.0
  NideConfigDirName = "nide"
  NideProjectsFileName = "projects.owl"
  NideConfigFileName = "config.owl"

type
  PendingFileAction = enum
    NoFileAction
    OpenFileAction
    SaveFileAction

  SaveDialogRequest = ref object
    callback: proc(path: string)

  NideRequestHandler = proc(model: var Nide, request: NideBridgeRequest)

  Nide = object
    evaluator: Evaluator
    uiRuntime: NestOwlRuntime
    bridge: NideOwlBridge
    requestHandlers: Table[string, NideRequestHandler]
    toolbars: Toolbars
    projectManager: ProjectManager
    buffers: BufferManager
    panes: PaneManager
    commandStatus: string
    showProjectsPanel: bool
    pendingFileAction: PendingFileAction
    pendingPath: string
    status: string

var pendingSaveDialogs: seq[SaveDialogRequest]
var pickedFileAction: PendingFileAction
var pickedPath: string
var pickedProjectPath: string

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

proc init(T: typedesc[Nide]): T =
  result = Nide(evaluator: Evaluator.init(), uiRuntime: NestOwlRuntime.init(),
      bridge: NideOwlBridge.init(),
      requestHandlers: initTable[string, NideRequestHandler](),
      toolbars: Toolbars.init(),
      projectManager: ProjectManager.init(),
      buffers: BufferManager.init(),
      status: "Ready")
  let rootBuffer = result.buffers.newScratchBuffer()
  result.panes = PaneManager.init(rootBuffer)

proc nideConfigDir(): string =
  getConfigDir() / NideConfigDirName

proc nideProjectsPath(): string =
  nideConfigDir() / NideProjectsFileName

proc nideConfigPath(): string =
  nideConfigDir() / NideConfigFileName

proc ensureNideUserFiles(model: var Nide) =
  let dir = nideConfigDir()
  createDir(dir)

  let projectsPath = nideProjectsPath()
  if not fileExists(projectsPath):
    var stream = openFileStream(projectsPath, fmWrite)
    if stream.isNil:
      raise newException(IOError, "could not create " & projectsPath)
    stream.write(model.projectManager)
    stream.close()

  let configPath = nideConfigPath()
  if not fileExists(configPath):
    writeFile(configPath, "; Nide user config\n")

proc loadProjectManager(model: var Nide) =
  let path = nideProjectsPath()
  var stream = openFileStream(path, fmRead)
  if stream.isNil:
    raise newException(IOError, "could not open " & path)
  model.projectManager = stream.read(ProjectManager)
  stream.close()

proc saveProjectManager(model: var Nide) =
  let path = nideProjectsPath()
  var stream = openFileStream(path, fmWrite)
  if stream.isNil:
    raise newException(IOError, "could not open " & path)
  stream.write(model.projectManager)
  stream.close()

proc runUserConfig(model: var Nide) =
  let path = nideConfigPath()
  when NideRunPermissiveUserConfig:
    discard model.uiRuntime.evaluator.exec(parse(readFile(path), path))
  else:
    model.runNideSource(readFile(path), path)

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
  model.evaluator.env.bindText(VarStatus, model.status)

proc syncCommandBindings(model: var Nide) =
  model.commandStatus = model.evaluator.env.readText(VarStatus)

proc processCommandBindings(model: var Nide) =
  if model.commandStatus.len > 0:
    model.status = model.commandStatus

proc processBridgeRequests(model: var Nide)

proc runNideSource(model: var Nide, source, path: string) =
  model.resetCommandBindings()
  try:
    discard model.evaluator.exec(parse(source, path))
    model.syncCommandBindings()
    model.processBridgeRequests()
    model.processCommandBindings()
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

proc publishBridgeData(model: var Nide) =
  model.bridge.putData("project-manager", model.projectManager.snapshot())
  model.bridge.putData("projects", model.projectManager.projectsValue())
  model.bridge.putData("active-project", text(model.projectManager.activeProjectName()))
  model.bridge.putData("auto-track-opened-projects",
      boolean(NideAutoTrackOpenedProjects))

proc registerRequest(model: var Nide, name: string, handler: NideRequestHandler) =
  model.requestHandlers[name] = handler

proc requestText(request: NideBridgeRequest, index: int): string =
  if index >= 0 and index < request.arguments.len and
      request.arguments[index].kind == Text:
    request.arguments[index].text
  else:
    ""

proc openProjectRequest(model: var Nide, request: NideBridgeRequest) =
  try:
    let target = request.requestText(0)
    if model.projectManager.setActiveProject(target):
      model.status = "Opened project " & target
      model.saveProjectManager()
    else:
      model.status = "Project not found: " & target
  except CatchableError as error:
    model.status = "Project action failed: " & error.msg

proc addProjectRequest(model: var Nide, request: NideBridgeRequest) =
  try:
    let name = request.requestText(0)
    let path = request.requestText(1)
    if model.projectManager.addProject(name, path):
      model.status = "Added project " & name
    else:
      model.status = "Project already tracked: " & name
  except CatchableError as error:
    model.status = "Project action failed: " & error.msg

proc pickProjectDirectoryRequest(model: var Nide, request: NideBridgeRequest) =
  discard model
  discard request
  dialogs.browseFolder(proc(path: string) =
    pickedProjectPath = path
  )

proc setStatusRequest(model: var Nide, request: NideBridgeRequest) =
  model.status = request.requestText(0)

proc unloadProjectRequest(model: var Nide, request: NideBridgeRequest) =
  discard request
  try:
    model.projectManager.unloadActiveProject()
    model.saveProjectManager()
    model.status = "Project unloaded"
  except CatchableError as error:
    model.status = "Project action failed: " & error.msg

proc reloadProjectsRequest(model: var Nide, request: NideBridgeRequest) =
  discard request
  try:
    model.loadProjectManager()
    model.status = "Projects reloaded"
  except CatchableError as error:
    model.status = "Project action failed: " & error.msg

proc saveProjectsRequest(model: var Nide, request: NideBridgeRequest) =
  discard request
  try:
    model.saveProjectManager()
    model.status = "Projects saved"
  except CatchableError as error:
    model.status = "Project action failed: " & error.msg

proc toggleProjectsPanelRequest(model: var Nide, request: NideBridgeRequest) =
  discard request
  model.showProjectsPanel = not model.showProjectsPanel
  model.status =
    if model.showProjectsPanel: "Projects panel opened" else: "Projects panel closed"

proc processBridgeRequests(model: var Nide) =
  for request in model.bridge.drainRequests():
    let handler = model.requestHandlers.getOrDefault(request.name)
    if handler.isNil:
      model.status = "Unknown action: " & request.name
    else:
      handler(model, request)

proc configureBridge(model: var Nide) =
  model.registerRequest(ActionNewFile, proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.newFile()
  )
  model.registerRequest(ActionOpenFileDialog, proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.requestOpenFile()
  )
  model.registerRequest(ActionSaveFileAsDialog, proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.requestSaveFile()
  )
  model.registerRequest(ActionMarkBufferSaved, proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.markActiveBufferSaved()
  )
  model.registerRequest("pane.split-column", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.splitColumn()
  )
  model.registerRequest("pane.split-row", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.splitRow()
  )
  model.registerRequest("pane.unsplit", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.unsplitPane()
  )
  model.registerRequest(ActionToggleProjectsPanel, toggleProjectsPanelRequest)
  model.registerRequest("project.open", openProjectRequest)
  model.registerRequest("project.add", addProjectRequest)
  model.registerRequest("project.pick-directory", pickProjectDirectoryRequest)
  model.registerRequest("project.unload", unloadProjectRequest)
  model.registerRequest("projects.reload", reloadProjectsRequest)
  model.registerRequest("projects.save", saveProjectsRequest)
  model.registerRequest("status.set", setStatusRequest)
  model.publishBridgeData()

proc processPendingFileAction(model: var Nide) =
  if pickedProjectPath.len > 0:
    try:
      discard model.evaluator.env.call(
        model.evaluator.env.get("project-open-path").command,
        @[stringLiteral(pickedProjectPath)],
      )
      model.syncCommandBindings()
      model.processBridgeRequests()
      model.processCommandBindings()
    except OwlError as error:
      model.status = "Project open failed: " & error.msg
    pickedProjectPath = ""

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
  model.uiRuntime.evaluator.env.bindText(VarStatus, model.status)
  model.publishBridgeData()
  model.processBridgeRequests()

  ui.column(ui.id("root"), cfg(width = fill(), height = fill(), gap = 0)):
    for event in ui.toolbarDock(model.toolbars, TopDock):
      model.handleToolbarEvent(event)

    ui.row(ui.id("workspaceDockRow"), cfg(width = fill(), height = fill(),
        gap = 0, alignSelf = AlignStretch)):
      for event in ui.toolbarDock(model.toolbars, LeftDock):
        model.handleToolbarEvent(event)

      if model.showProjectsPanel:
        model.uiRuntime.renderWidget(ui, currentSourcePath().parentDir /
            "projects-panel.owl", "projects-panel")
        model.processBridgeRequests()

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

    ui.statusbar(model.uiRuntime)

when isMainModule:
  let config = AppConfig.init(width = 900, height = 640, title = "Nide")
  var nide = Nide.init()
  nide.configureBridge()
  nide.evaluator.registerInternalCommands(nide.bridge)
  nide.uiRuntime.evaluator.registerInternalCommands(nide.bridge)
  nide.uiRuntime.evaluator.registerToolbarBuilderCommands()

  try:
    nide.ensureNideUserFiles()
    nide.loadProjectManager()
    nide.runNideSource(NideCommandsSource, currentSourcePath().parentDir /
        "commands.owl")
    nide.uiRuntime.evaluator.env.bindText(VarStatus, nide.status)
    discard nide.uiRuntime.evaluator.exec(parse(NideLoadSource,
        currentSourcePath().parentDir / "load.owl"))
    nide.runUserConfig()
    nide.toolbars = nide.uiRuntime.evaluator.env.readToolbars("nide-toolbars")
  except OwlError as error:
    stderr.write report(error, useColor = true)
    quit 1
  except CatchableError as error:
    stderr.writeLine error.msg
    quit 1

  runApp(config, nide, nideApplication)
