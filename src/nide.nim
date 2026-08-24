import std/[algorithm, os, osproc, sets, streams, strutils, tables]

import nest, owl
import nest/dialogs
import nest/errorDialogs
import nest/owldsl
import sdl3

import buffers, commands, modes, panes, projects
import widgets/[panels, toolbar]

const NideCommandsSource = staticRead"commands.owl"
const NideLoadSource = staticRead"load.owl"
const NideSourceDir = currentSourcePath().parentDir
const NideRunPermissiveUserConfig* {.booldefine.} = true
const NideAutoTrackOpenedProjects* {.booldefine.} = true
const
  MinPaneWidth = 180.0
  MinPaneHeight = 140.0
  MinWorkspaceWidth = 640.0
  MinWorkspaceHeight = 420.0
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
    owlErrorApp: NestOwlApp
    bridge: NideOwlBridge
    requestHandlers: Table[string, NideRequestHandler]
    toolbars: Toolbars
    projectManager: ProjectManager
    modeRegistry: ModeRegistry
    loadedModes: HashSet[string]
    modeHooks: Table[string, Table[string, string]]
    loadingMode: string
    buffers: BufferManager
    panes: PaneManager
    lastFocusedEditorPane: PaneID
    commandStatus: string
    panels: seq[NidePanel]
    floatingOpen: bool
    floatingTab: int
    floatingTabKey: string
    floatingWidth: float64
    floatingHeight: float64
    bufferPreviewID: BufferID
    needsRedraw: bool
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
  let uiRuntime = NestOwlRuntime.init()
  result = Nide(evaluator: Evaluator.init(), uiRuntime: NestOwlRuntime.init(),
      bridge: NideOwlBridge.init(),
      requestHandlers: initTable[string, NideRequestHandler](),
      toolbars: Toolbars.init(),
      projectManager: ProjectManager.init(),
      modeRegistry: ModeRegistry.init(),
      loadedModes: initHashSet[string](),
      modeHooks: initTable[string, Table[string, string]](),
      buffers: BufferManager.init(),
      floatingOpen: false,
      floatingTab: 0,
      floatingWidth: 1040.0,
      floatingHeight: 680.0,
      status: "Ready")
  result.uiRuntime = uiRuntime
  result.owlErrorApp = NestOwlApp(rootPath: NideSourceDir / "load.owl",
      runtime: result.uiRuntime)
  let rootBuffer = result.buffers.newScratchBuffer()
  result.panes = PaneManager.init(rootBuffer)
  result.lastFocusedEditorPane = result.panes.activePane
  result.panels = @[
    NidePanel(id: "projects", title: "Projects", dock: PanelLeft,
      source: "projects-panel.owl", widget: "projects-panel", open: false,
      size: 280),
    NidePanel(id: "files", title: "Files", dock: PanelLeft,
      source: "file-explorer-panel.owl", widget: "file-explorer-panel",
      open: false, size: 320),
    NidePanel(id: "find-file", title: "Find File", dock: PanelFloating,
      source: "find-file-panel.owl", widget: "find-file-panel",
      open: false, size: 720),
    NidePanel(id: "find-buffer", title: "Find Buffer", dock: PanelFloating,
      source: "find-buffer-panel.owl", widget: "find-buffer-panel",
      open: false, size: 720),
  ]

proc nideConfigDir(): string =
  getConfigDir() / NideConfigDirName

proc nideProjectsPath(): string =
  nideConfigDir() / NideProjectsFileName

proc nideConfigPath(): string =
  nideConfigDir() / NideConfigFileName

proc ensureNideUserFiles(model: var Nide) =
  let dir = nideConfigDir()
  createDir(dir)
  createDir(nideModesDir())

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

proc activeEditorPane(model: Nide): PaneID =
  if model.lastFocusedEditorPane != InvalidPaneID and
      model.lastFocusedEditorPane in model.panes.panes and
      model.panes.panes[model.lastFocusedEditorPane].isLeaf:
    return model.lastFocusedEditorPane
  model.panes.activePane

proc activeBufferID(model: Nide): BufferID =
  let paneID = model.activeEditorPane()
  if paneID == InvalidPaneID or paneID notin model.panes.panes:
    return InvalidBufferID
  model.panes.panes[paneID].bufferID

proc requestFrame(model: var Nide) =
  model.needsRedraw = true

proc queueOpenFile(model: var Nide, path: string) =
  if path.len == 0:
    return
  model.pendingFileAction = OpenFileAction
  model.pendingPath = path
  model.requestFrame()

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

proc runBufferHook(model: var Nide, id: BufferID, hook: string)
proc applyFileMode(model: var Nide, id: BufferID)

proc dropBufferIfUnreferenced(model: var Nide, id: BufferID) =
  if model.buffers.hasBuffer(id) and model.panes.bufferReferenceCount(id) == 0:
    model.buffers.buffers.del(id)

proc newFile(model: var Nide) =
  let id = model.activeBufferID()
  if model.panes.bufferReferenceCount(id) > 1:
    let newID = model.buffers.newScratchBuffer()
    model.panes.setActiveBuffer(newID)
  else:
    model.runBufferHook(id, "onunload")
    model.buffers.replaceWithScratch(id)
  model.status = "New file"
  model.requestFrame()

proc openFile(model: var Nide, path: string) =
  let id = model.activeBufferID()
  if id == InvalidBufferID:
    model.status = "Open failed: no focused editor pane"
    return
  try:
    let existingID = model.buffers.findByPath(path)
    if existingID != InvalidBufferID:
      model.panes.setActiveBuffer(existingID)
      model.status = "Opened " & path
      model.requestFrame()
      return
    let newID = model.buffers.openBuffer(path)
    model.panes.setActiveBuffer(newID)
    model.applyFileMode(newID)
    model.status = "Opened " & path
    model.requestFrame()
  except CatchableError as error:
    model.status = "Open failed: " & error.msg
    model.requestFrame()

proc saveFileAs(model: var Nide, path: string) =
  let id = model.activeBufferID()
  try:
    let existingID = model.buffers.findByPath(path)
    if existingID != InvalidBufferID and existingID != id and
        model.buffers.hasBuffer(id):
      let content = model.buffers.buffers[id].editor.text
      writeFile(path, content)
      if model.panes.bufferReferenceCount(id) <= 1:
        model.runBufferHook(id, "onunload")
      model.buffers.buffers[existingID].editor.replaceText(content)
      model.buffers.buffers[existingID].savedText = content
      model.panes.setActiveBuffer(existingID)
      model.dropBufferIfUnreferenced(id)
      model.status = "Saved " & path
      return
    model.runBufferHook(id, "onunload")
    model.buffers.saveBufferAs(id, path)
    model.applyFileMode(id)
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
  model.requestFrame()

proc splitRow(model: var Nide) =
  let bufferID = model.buffers.newScratchBuffer()
  discard model.panes.addRow(bufferID)
  model.status = "Split row"
  model.requestFrame()

proc unsplitPane(model: var Nide) =
  let bufferID = model.panes.unsplitActive()
  if bufferID == InvalidBufferID:
    model.status = "Cannot unsplit the last pane"
    model.requestFrame()
    return
  model.status = "Unsplit pane"
  model.requestFrame()

proc closePane(model: var Nide, paneID: PaneID): bool =
  let bufferID = model.panes.closePane(paneID)
  if bufferID == InvalidBufferID:
    model.status = "Cannot close the last pane"
    model.requestFrame()
    return false
  if model.lastFocusedEditorPane == paneID:
    model.lastFocusedEditorPane = model.panes.activePane
  model.status = "Closed pane"
  model.requestFrame()
  true

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

proc runBufferHook(model: var Nide, id: BufferID, hook: string) =
  if not model.buffers.hasBuffer(id):
    return
  let mode = string(model.buffers.buffers[id].fileMode)
  var commandID = ""
  if mode in model.modeHooks:
    commandID = model.modeHooks[mode].getOrDefault(hook)
  if commandID.len == 0:
    commandID = model.buffers.buffers[id].modeHooks.getOrDefault(hook)
  if commandID.len > 0:
    model.runCommand(commandID)

proc applyFileMode(model: var Nide, id: BufferID) =
  if not model.buffers.hasBuffer(id):
    return
  let buffer = model.buffers.buffers[id]
  let mode = model.modeRegistry.detectMode(buffer.path, buffer.editor.text)
  model.buffers.buffers[id].fileMode = buffers.FileMode(mode)
  if mode.len == 0:
    return
  let script = mode.modeSource()
  try:
    if script.source.len > 0 and mode notin model.loadedModes:
      model.loadingMode = mode
      model.runNideSource(script.source, script.path)
      model.loadingMode = ""
      model.loadedModes.incl mode
    model.runBufferHook(id, "onload")
  except OwlError as error:
    model.loadingMode = ""
    model.status = "Mode " & mode & " failed: " & error.msg

proc togglePanel(model: var Nide, target: string): bool =
  for panel in model.panels.mitems:
    if panel.id == target:
      panel.open = not panel.open
      if panel.dock == PanelFloating and panel.open:
        model.floatingOpen = true
        model.floatingTabKey = "panel:" & panel.id
      model.status =
        if panel.open: panel.title & " panel opened" else: panel.title & " panel closed"
      model.requestFrame()
      return true

proc openFloatingPanel(model: var Nide, target: string): bool =
  for panel in model.panels.mitems:
    if panel.id == target:
      panel.dock = PanelFloating
      panel.open = true
      model.floatingOpen = true
      model.floatingTabKey = "panel:" & panel.id
      model.status = panel.title & " opened"
      model.requestFrame()
      return true

proc dockPanel(model: var Nide, target: string): bool =
  for panel in model.panels.mitems:
    if panel.id == target:
      if panel.dock == PanelFloating:
        panel.dock = PanelLeft
      panel.open = true
      model.status = panel.title & " docked"
      model.requestFrame()
      return true

proc floatPanel(model: var Nide, target: string): bool =
  for panel in model.panels.mitems:
    if panel.id == target:
      panel.dock = PanelFloating
      panel.open = true
      model.floatingOpen = true
      model.floatingTabKey = "panel:" & panel.id
      model.status = panel.title & " undocked"
      model.requestFrame()
      return true

proc floatPane(model: var Nide, paneID: PaneID): bool =
  if paneID notin model.panes.panes or not model.panes.panes[paneID].isLeaf:
    return false
  model.panes.setFloating(paneID, true)
  model.floatingOpen = true
  model.floatingTabKey = "pane:" & paneID
  model.status = "Pane undocked"
  model.requestFrame()
  true

proc dockPane(model: var Nide, paneID: PaneID): bool =
  if paneID notin model.panes.panes or not model.panes.panes[paneID].isLeaf:
    return false
  model.panes.setFloating(paneID, false)
  model.floatingTabKey = ""
  model.status = "Pane docked"
  model.requestFrame()
  true

proc switchBuffer(model: var Nide, bufferID: BufferID): bool =
  if not model.buffers.hasBuffer(bufferID):
    return false
  var targetPane = model.activeEditorPane()
  if targetPane == InvalidPaneID or targetPane notin model.panes.panes:
    targetPane = model.panes.firstLeaf(model.panes.rootPane)
  if targetPane == InvalidPaneID:
    return false
  model.panes.focus(targetPane)
  model.panes.setActiveBuffer(bufferID)
  model.lastFocusedEditorPane = targetPane
  model.status = "Switched to " & model.buffers.buffers[bufferID].name
  model.requestFrame()
  true

proc killBuffer(model: var Nide, bufferID: BufferID): bool =
  if not model.buffers.hasBuffer(bufferID):
    return false
  model.runBufferHook(bufferID, "onunload")
  let replacement =
    if model.panes.bufferReferenceCount(bufferID) > 0:
      model.buffers.newScratchBuffer()
    else:
      InvalidBufferID
  if replacement != InvalidBufferID:
    for pane in model.panes.panes.mvalues:
      if pane.isLeaf and pane.bufferID == bufferID:
        pane.bufferID = replacement
  model.buffers.buffers.del(bufferID)
  if model.bufferPreviewID == bufferID:
    model.bufferPreviewID = replacement
  model.status = "Killed buffer"
  model.requestFrame()
  true

proc closeFloating(model: var Nide) =
  model.floatingOpen = false
  model.requestFrame()

proc toggleFloating(model: var Nide) =
  var hasFloating = false
  for panel in model.panels:
    if panel.dock == PanelFloating and panel.open:
      hasFloating = true
      break
  if not hasFloating:
    hasFloating = model.panes.floatingPaneIDs().len > 0
  if hasFloating:
    model.floatingOpen = not model.floatingOpen
    model.requestFrame()

proc previewBuffer(model: var Nide, bufferID: BufferID) =
  if model.buffers.hasBuffer(bufferID):
    model.bufferPreviewID = bufferID
    model.requestFrame()

proc handleToolbarEvent(model: var Nide, ui: var UI, event: ToolbarEvent) =
  case event.kind
  of MenuClicked:
    discard
  of ToolClicked:
    case event.toolID
    of "toggleProjectsPanel":
      discard model.togglePanel("projects")
    of "toggleFileExplorerPanel":
      discard model.togglePanel("files")
    else:
      case event.commandID
      of "toggle-projects-panel":
        discard model.togglePanel("projects")
      of "toggle-file-explorer-panel":
        discard model.togglePanel("files")
      else:
        model.runCommand(event.commandID)
    ui.markAllDirty()
    ui.requestRedrawAfter(0)
  of MenuItemClicked:
    case event.commandID
    of "toggle-projects-panel":
      discard model.togglePanel("projects")
    of "toggle-file-explorer-panel":
      discard model.togglePanel("files")
    else:
      model.runCommand(event.commandID)
    ui.markAllDirty()
    ui.requestRedrawAfter(0)

proc panelsValue(model: Nide): Value =
  var values: seq[Value]
  for panel in model.panels:
    var entries = initTable[string, Value]()
    entries["id"] = text(panel.id)
    entries["title"] = text(panel.title)
    entries["dock"] = text(panel.dock.name())
    entries["source"] = text(panel.source)
    entries["widget"] = text(panel.widget)
    entries["open"] = boolean(panel.open)
    entries["size"] = number(panel.size)
    values.add dictionary(entries)
  list(values)

proc previewText(text: string): string =
  const MaxPreviewChars = 200_000
  if text.len <= MaxPreviewChars:
    text
  else:
    text[0 ..< MaxPreviewChars]

proc buffersValue(model: Nide): Value =
  var values: seq[Value]
  for id in model.bufferIDs():
    if id notin model.buffers.buffers:
      continue
    let buffer = model.buffers.buffers[id]
    let title =
      if buffer.dirty: "*" & buffer.name else: buffer.name
    var entries = initTable[string, Value]()
    entries["id"] = text(id)
    entries["name"] = text(buffer.name)
    entries["title"] = text(title)
    entries["path"] = text(buffer.path)
    entries["mode"] = text(string(buffer.fileMode))
    entries["dirty"] = boolean(buffer.dirty())
    values.add dictionary(entries)
  list(values)

proc bufferPreviewText(model: Nide): string =
  let id =
    if model.buffers.hasBuffer(model.bufferPreviewID):
      model.bufferPreviewID
    else:
      model.activeBufferID()
  if model.buffers.hasBuffer(id):
    model.buffers.buffers[id].editor.text.previewText()
  else:
    ""

proc activeBufferMode(model: Nide): string =
  let id = model.activeBufferID()
  if model.buffers.hasBuffer(id):
    string(model.buffers.buffers[id].fileMode)
  else:
    ""

proc publishBridgeData(model: var Nide) =
  model.bridge.putData("project-manager", model.projectManager.snapshot())
  model.bridge.putData("projects", model.projectManager.projectsValue())
  model.bridge.putData("project-profile-templates",
      projectProfileTemplatesValue())
  model.bridge.putData("active-project", text(
      model.projectManager.activeProjectName()))
  model.bridge.putData("active-project-path", text(
      model.projectManager.activeProjectPath()))
  model.bridge.putData("home-directory", text(getHomeDir()))
  model.bridge.putData("panels", model.panelsValue())
  model.bridge.putData("buffers", model.buffersValue())
  model.bridge.putData("buffer-preview-text", text(model.bufferPreviewText()))
  model.bridge.putData("active-buffer-mode", text(model.activeBufferMode()))
  model.bridge.putData("auto-track-opened-projects",
      boolean(NideAutoTrackOpenedProjects))

proc registerRequest(model: var Nide, name: string,
    handler: NideRequestHandler) =
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

proc profileFromRequest(request: NideBridgeRequest): ProjectProfile =
  result = projectProfile(request.requestText(2), [])
  for index, kind in ProjectCommandKinds:
    let command = request.requestText(index + 3).strip()
    if command.len > 0:
      result.profileCommands[kind] = profileCommand(command)

proc saveProjectProfileRequest(model: var Nide, request: NideBridgeRequest) =
  try:
    let
      projectName = request.requestText(0)
      originalName = request.requestText(1)
      profile = request.profileFromRequest()
    if model.projectManager.upsertProfile(projectName, originalName, profile):
      model.saveProjectManager()
      model.status = "Saved profile " & profile.name
    else:
      model.status = "Could not save project profile"
  except CatchableError as error:
    model.status = "Project profile save failed: " & error.msg

proc projectPathByName(model: Nide, projectName: string): string =
  for project in model.projectManager.projects:
    if project.name == projectName:
      return project.directoryPath
  ""

proc runShellCommandAsync(directoryPath, command: string): bool =
  var process: osproc.Process
  try:
    process = osproc.startProcess("sh", args = @["-lc", command],
        workingDir = directoryPath, options = {poUsePath, poDaemon,
        poParentStreams})
    process.close()
    true
  except CatchableError:
    if process != nil:
      try:
        process.close()
      except CatchableError:
        discard
    false

proc runProjectProfileRequest(model: var Nide, request: NideBridgeRequest) =
  try:
    let
      projectName = request.requestText(0)
      profileName = request.requestText(1)
      kindName = request.requestText(2)
      kind = parseCommandKind(kindName)
      directoryPath = model.projectPathByName(projectName)
      command = model.projectManager.profileCommand(projectName, profileName,
          kind)
    if directoryPath.len == 0:
      model.status = "Project not found: " & projectName
    elif command.len == 0:
      model.status = kindName & " is not defined for " & profileName
    elif runShellCommandAsync(directoryPath, command):
      model.status = kindName & " started: " & command
    else:
      model.status = kindName & " failed to start: " & command
  except CatchableError as error:
    model.status = "Project command failed: " & error.msg

proc toggleProjectsPanelRequest(model: var Nide, request: NideBridgeRequest) =
  discard request
  discard model.togglePanel("projects")

proc togglePanelRequest(model: var Nide, request: NideBridgeRequest) =
  let target = request.requestText(0)
  if not model.togglePanel(target):
    model.status = "Unknown panel: " & target

proc toggleFileExplorerPanelRequest(model: var Nide,
    request: NideBridgeRequest) =
  discard request
  discard model.togglePanel("files")

proc fileExplorerOpenRequest(model: var Nide, request: NideBridgeRequest) =
  let path = request.requestText(0)
  if path.len == 0:
    return
  if fileExists(path):
    model.queueOpenFile(path)
  elif dirExists(path):
    model.status = "Selected directory " & path
  else:
    model.status = "File not found: " & path

proc fileExplorerEventRequest(model: var Nide, request: NideBridgeRequest) =
  let path = request.requestText(0)
  let action = request.name.replace("file-explorer.", "")
  if path.len > 0:
    model.status = "File explorer " & action & ": " & path
  else:
    model.status = "File explorer " & action

proc valueText(value: Value, key: string): string =
  if value.kind == Dictionary and key in value.entries and
      value.entries[key].kind == Text:
    value.entries[key].text
  else:
    ""

proc valueNumber(value: Value, key: string, fallback: float64): float64 =
  if value.kind == Dictionary and key in value.entries and
      value.entries[key].kind == Number:
    value.entries[key].number
  else:
    fallback

proc clampByte(value: float64): uint8 =
  uint8(value.int.clamp(0, 255))

proc syntaxColor(value: Value): nest.Color =
  if value.kind == Dictionary:
    nest.color(
      value.valueNumber("r", 241).clampByte(),
      value.valueNumber("g", 246).clampByte(),
      value.valueNumber("b", 247).clampByte(),
      value.valueNumber("a", 255).clampByte(),
    )
  else:
    nest.color(241, 246, 247)

proc syntaxRule(value: Value): SyntaxRule =
  if value.kind != Dictionary:
    return
  let kind = value.valueText("kind")
  result.kind =
    case kind
    of "regex":
      SyntaxRegex
    of "word":
      SyntaxWord
    of "starts-with":
      SyntaxStartsWith
    of "contains":
      SyntaxContains
    of "span":
      SyntaxSpan
    else:
      SyntaxRegex
  result.pattern = value.valueText("pattern")
  result.stopPattern = value.valueText("stop")
  if "color" in value.entries:
    result.color = value.entries["color"].syntaxColor()
  else:
    result.color = nest.color(241, 246, 247)

proc syntaxDefinition(value: Value): SyntaxDefinition =
  if value.kind != Dictionary:
    return
  result.name = value.valueText("name")
  if "rules" in value.entries and value.entries["rules"].kind == List:
    for item in value.entries["rules"].items:
      let rule = item.syntaxRule()
      if rule.pattern.len > 0:
        result.rules.add rule

proc setEditorSyntaxRequest(model: var Nide, request: NideBridgeRequest) =
  let id = model.activeBufferID()
  if not model.buffers.hasBuffer(id) or request.arguments.len != 1:
    return
  model.buffers.buffers[id].editor.setSyntax(
    request.arguments[0].syntaxDefinition())

proc clearEditorSyntaxRequest(model: var Nide, request: NideBridgeRequest) =
  discard request
  let id = model.activeBufferID()
  if model.buffers.hasBuffer(id):
    model.buffers.buffers[id].editor.clearSyntax()

proc setModeHookRequest(model: var Nide, request: NideBridgeRequest) =
  let hook = request.requestText(0).strip.toLowerAscii()
  let commandID = request.requestText(1).strip
  if hook.len == 0 or commandID.len == 0:
    return
  if model.loadingMode.len > 0:
    if model.loadingMode notin model.modeHooks:
      model.modeHooks[model.loadingMode] = initTable[string, string]()
    model.modeHooks[model.loadingMode][hook] = commandID
  else:
    let id = model.activeBufferID()
    if model.buffers.hasBuffer(id):
      model.buffers.buffers[id].modeHooks[hook] = commandID

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
  model.registerRequest(ActionToggleFileExplorerPanel, toggleFileExplorerPanelRequest)
  model.registerRequest("panel.toggle", togglePanelRequest)
  model.registerRequest("panel.open-floating", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard model.openFloatingPanel(request.requestText(0))
  )
  model.registerRequest("panel.float", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard model.floatPanel(request.requestText(0))
  )
  model.registerRequest("panel.dock", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard model.dockPanel(request.requestText(0))
  )
  model.registerRequest("pane.float-active", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    discard model.floatPane(model.activeEditorPane())
  )
  model.registerRequest("pane.dock", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard model.dockPane(request.requestText(0))
  )
  model.registerRequest("floating.close", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.closeFloating()
  )
  model.registerRequest("floating.toggle", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard request
    model.toggleFloating()
  )
  model.registerRequest("file.open-path", proc(model: var Nide,
      request: NideBridgeRequest) =
    model.queueOpenFile(request.requestText(0))
  )
  model.registerRequest("buffer.switch", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard model.switchBuffer(request.requestText(0))
  )
  model.registerRequest("buffer.kill", proc(model: var Nide,
      request: NideBridgeRequest) =
    discard model.killBuffer(request.requestText(0))
  )
  model.registerRequest("buffer.preview", proc(model: var Nide,
      request: NideBridgeRequest) =
    model.previewBuffer(request.requestText(0))
  )
  model.registerRequest("file-explorer.open", fileExplorerOpenRequest)
  for action in ["select", "toggle", "refresh", "search", "sort", "filter", "hidden"]:
    model.registerRequest("file-explorer." & action, fileExplorerEventRequest)
  model.registerRequest("project.open", openProjectRequest)
  model.registerRequest("project.add", addProjectRequest)
  model.registerRequest("project.profile.save", saveProjectProfileRequest)
  model.registerRequest("project.profile.run", runProjectProfileRequest)
  model.registerRequest("project.pick-directory", pickProjectDirectoryRequest)
  model.registerRequest("project.unload", unloadProjectRequest)
  model.registerRequest("projects.reload", reloadProjectsRequest)
  model.registerRequest("projects.save", saveProjectsRequest)
  model.registerRequest("status.set", setStatusRequest)
  model.registerRequest("buffer.set-syntax", setEditorSyntaxRequest)
  model.registerRequest("buffer.clear-syntax", clearEditorSyntaxRequest)
  model.registerRequest("buffer.set-mode-hook", setModeHookRequest)
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
      model.requestFrame()
    except OwlError as error:
      model.status = "Project open failed: " & error.msg
    pickedProjectPath = ""

  if pickedFileAction != NoFileAction:
    model.pendingFileAction = pickedFileAction
    model.pendingPath = pickedPath
    model.requestFrame()
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

proc flushModelRedraw(ui: var UI, model: var Nide) =
  if model.needsRedraw:
    ui.markAllDirty()
    ui.requestRedrawAfter(0)
    model.needsRedraw = false

proc bufferTitle(buffer: Buffer): string =
  result = buffer.name
  if buffer.dirty:
    result = "*" & result

proc runtimeErrorSummary(runtime: NestOwlRuntime): string =
  let details = runtime.lastErrorDetails
  if details.primary.path.len > 0:
    result = details.primary.path & ":" & $details.primary.line & ":" &
        $details.primary.column & ": " & details.message
  elif runtime.lastError.len > 0:
    result = runtime.lastError
  else:
    result = "unknown Owl error"

proc clearRuntimeError(runtime: NestOwlRuntime) =
  runtime.hasError = false
  runtime.lastError = ""
  runtime.lastErrorDetails = ErrorDetails()

proc consumeRuntimeError(model: var Nide, context: string): bool =
  if model.uiRuntime.hasError:
    var details = model.uiRuntime.lastErrorDetails
    if details.message.len == 0:
      details.message = model.uiRuntime.runtimeErrorSummary()
    details.message = context & " failed: " & details.message
    model.owlErrorApp.launchOwlErrorDialog(details)
    model.status = context & " failed; see Owl error dialog"
    model.uiRuntime.clearRuntimeError()
    return true
  false

proc layoutPane(ui: var UI, model: var Nide, paneID: PaneID,
    floatingContent = false) =
  if paneID == InvalidPaneID or paneID notin model.panes.panes:
    return

  let pane = model.panes.panes[paneID]
  if pane.isLeaf:
    if pane.floating and not floatingContent:
      return
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
        if floatingContent:
          if ui.button(ui.id("paneDock", paneID), "⇲", width = fixed(30),
              height = fit()):
            discard model.dockPane(paneID)
          ui.tooltip(ui.id("paneDock", paneID), "Dock pane")
        else:
          if ui.button(ui.id("paneFloat", paneID), "⇱", width = fixed(30),
              height = fit()):
            discard model.floatPane(paneID)
          ui.tooltip(ui.id("paneFloat", paneID), "Undock pane")
        if ui.button(ui.id("paneClose", paneID), "×", width = fixed(30),
            height = fit()):
          discard model.closePane(paneID)
        ui.tooltip(ui.id("paneClose", paneID), "Close pane")
      ui.textEditor(editorID, model.buffers.buffers[pane.bufferID].editor,
          width = fill(min = MinPaneWidth), height = fill(min = MinPaneHeight),
          fontName = "editor", lineNumbers = true, scrollbars = true,
          syntax = model.buffers.buffers[pane.bufferID].editor.syntax.name)

    if ui.clicked(panelID) or ui.focused(editorID):
      model.panes.focus(paneID)
      model.lastFocusedEditorPane = paneID
  elif pane.orientation == Row:
    ui.row(ui.id("row", paneID), cfg(width = fill(min = MinPaneWidth),
        height = fill(min = MinPaneHeight), gap = 4,
        alignSelf = AlignStretch)):
      for child in pane.children:
        if floatingContent or model.panes.hasDockedLeaf(child):
          ui.layoutPane(model, child, floatingContent)
  else:
    ui.column(ui.id("column", paneID), cfg(width = fill(min = MinPaneWidth),
        height = fill(min = MinPaneHeight), gap = 4,
        alignSelf = AlignStretch)):
      for child in pane.children:
        if floatingContent or model.panes.hasDockedLeaf(child):
          ui.layoutPane(model, child, floatingContent)

proc renderPanelDock(ui: var UI, model: var Nide, dock: PanelDock) =
  var hasOpen = false
  for panel in model.panels:
    if panel.dock == dock and panel.open:
      hasOpen = true
      break
  if not hasOpen:
    return

  for panel in model.panels:
    if panel.dock == dock and panel.open:
      let panelConfig =
        case dock
        of PanelLeft, PanelRight:
          cfg(width = fixed(panel.size), height = fill(), padding = 0, gap = 0,
              alignItems = AlignStretch)
        of PanelTop, PanelBottom:
          cfg(width = fill(), height = fixed(panel.size), padding = 0, gap = 0,
              alignItems = AlignStretch)
        of PanelFloating:
          cfg(width = fixed(panel.size), height = fill(), padding = 0, gap = 0,
              alignItems = AlignStretch)
      ui.column(ui.id("panelDockShell", panel.id), panelConfig):
        ui.row(ui.id("panelDockHeader", panel.id), cfg(width = fill(),
            height = fit(), padding = 4, gap = 6, alignItems = AlignCenter,
            ).withBackground(color(30, 34, 38))):
          ui.label(ui.id("panelDockTitle", panel.id), panel.title, width = fill())
          if ui.button(ui.id("panelDockFloat", panel.id), "⇱", width = fixed(30),
              height = fit()):
            discard model.floatPanel(panel.id)
          ui.tooltip(ui.id("panelDockFloat", panel.id), "Undock panel")
        model.uiRuntime.renderWidget(ui, NideSourceDir /
            panel.source, panel.widget)
        if model.consumeRuntimeError(panel.title & " panel"):
          model.uiRuntime.evaluator.env.bindText(VarStatus, model.status)
        model.processBridgeRequests()
        ui.flushModelRedraw(model)

proc renderFloatingDock(ui: var UI, model: var Nide) =
  var
    labels: seq[string]
    keys: seq[string]
    panelIDs: seq[string]
    paneIDs: seq[PaneID]
  for panel in model.panels:
    if panel.dock == PanelFloating and panel.open:
      labels.add panel.title
      keys.add "panel:" & panel.id
      panelIDs.add panel.id
      paneIDs.add InvalidPaneID
  for paneID in model.panes.floatingPaneIDs():
    if paneID in model.panes.panes:
      let bufferID = model.panes.panes[paneID].bufferID
      if model.buffers.hasBuffer(bufferID):
        labels.add bufferTitle(model.buffers.buffers[bufferID])
        keys.add "pane:" & paneID
        panelIDs.add ""
        paneIDs.add paneID

  if labels.len == 0:
    model.floatingOpen = false
    return

  if model.floatingTabKey.len > 0:
    for index, key in keys:
      if key == model.floatingTabKey:
        model.floatingTab = index
        break
  model.floatingTab = model.floatingTab.clamp(0, labels.high)
  model.floatingTabKey = keys[model.floatingTab]

  let floatingDockID = ui.id("floatingDock")
  ui.resizableModalDialog(floatingDockID, model.floatingOpen,
      model.floatingWidth, model.floatingHeight, 720.0, 420.0, 1800.0,
      1200.0, cfg(padding = 10, gap = 8, alignItems = AlignStretch,
      ).withBackground(color(21, 24, 28))):
    ui.row(ui.id("floatingDockHeader"), cfg(width = fill(), height = fit(),
        gap = 8, alignItems = AlignCenter)):
      ui.tabs(ui.id("floatingDockTabs"), labels, model.floatingTab,
          width = fill(), height = fit())
      model.floatingTab = model.floatingTab.clamp(0, labels.high)
      model.floatingTabKey = keys[model.floatingTab]
      let selectedPanel = panelIDs[model.floatingTab]
      let selectedPane = paneIDs[model.floatingTab]
      if selectedPanel.len > 0:
        if ui.button(ui.id("floatingPanelDock", selectedPanel), "⇲",
            width = fixed(32), height = fit()):
          discard model.dockPanel(selectedPanel)
        ui.tooltip(ui.id("floatingPanelDock", selectedPanel), "Dock panel")
      elif selectedPane != InvalidPaneID:
        if ui.button(ui.id("floatingPaneDock", selectedPane), "⇲",
            width = fixed(32), height = fit()):
            discard model.dockPane(selectedPane)
        ui.tooltip(ui.id("floatingPaneDock", selectedPane), "Dock pane")
      if ui.button(ui.id("floatingDockHide"), "×", width = fixed(32),
          height = fit()):
        model.closeFloating()
      ui.tooltip(ui.id("floatingDockHide"), "Hide")
    if panelIDs[model.floatingTab].len > 0:
      for panel in model.panels:
        if panel.id == panelIDs[model.floatingTab]:
          model.uiRuntime.renderWidget(ui, NideSourceDir /
              panel.source, panel.widget)
          if model.consumeRuntimeError(panel.title & " panel"):
            model.uiRuntime.evaluator.env.bindText(VarStatus, model.status)
          model.processBridgeRequests()
          ui.flushModelRedraw(model)
          break
    elif paneIDs[model.floatingTab] != InvalidPaneID:
      ui.layoutPane(model, paneIDs[model.floatingTab], floatingContent = true)

widget nideApplication(model: var Nide):
  model.owlErrorApp.pollOwlErrorDialog()
  model.processPendingFileAction()
  ui.flushModelRedraw(model)
  model.uiRuntime.evaluator.env.bindText(VarStatus, model.status)
  model.publishBridgeData()
  if ui.keyPressed("escape"):
    model.closeFloating()
    ui.flushModelRedraw(model)

  ui.column(ui.id("root"), cfg(width = fill(), height = fill(), gap = 0)):
    model.uiRuntime.renderWidget(ui, NideSourceDir / "keybindings.owl",
        "nide-keybindings")
    discard model.consumeRuntimeError("Keybindings")
    model.processBridgeRequests()
    ui.flushModelRedraw(model)

    for event in ui.toolbarDock(model.toolbars, model.uiRuntime, TopDock,
        NideSourceDir):
      model.handleToolbarEvent(ui, event)
    discard model.consumeRuntimeError("Top toolbar")

    ui.renderPanelDock(model, PanelTop)

    ui.row(ui.id("workspaceDockRow"), cfg(width = fill(), height = fill(),
        gap = 0, alignSelf = AlignStretch)):
      for event in ui.toolbarDock(model.toolbars, model.uiRuntime, LeftDock,
          NideSourceDir):
        model.handleToolbarEvent(ui, event)
      discard model.consumeRuntimeError("Left toolbar")

      ui.renderPanelDock(model, PanelLeft)

      ui.panel(ui.id("workspace"), cfg(width = fill(), height = fill(),
          padding = 6, gap = 4)):
        ui.column(ui.id("workspaceScroll"), cfg(width = fill(), height = fill(),
            scrollX = true, scrollY = true, scrollWheel = false,
            alignItems = AlignStretch)):
          ui.row(ui.id("workspaceRoot"), cfg(width = fill(
              min = MinWorkspaceWidth), height = fill(min = MinWorkspaceHeight),
                  gap = 0,
              alignSelf = AlignStretch)):
            ui.layoutPane(model, model.panes.rootPane)
            if not model.panes.hasDockedLeaf(model.panes.rootPane):
              ui.center(ui.id("emptyWorkspace"), fill(), fill()):
                ui.label(ui.id("emptyWorkspaceLabel"), "All panes are floating",
                    width = fit(), height = fit())

      ui.renderPanelDock(model, PanelRight)

      for event in ui.toolbarDock(model.toolbars, model.uiRuntime, RightDock,
          NideSourceDir):
        model.handleToolbarEvent(ui, event)
      discard model.consumeRuntimeError("Right toolbar")

    ui.renderPanelDock(model, PanelBottom)

    for event in ui.toolbarDock(model.toolbars, model.uiRuntime, BottomDock,
        NideSourceDir):
      model.handleToolbarEvent(ui, event)
    discard model.consumeRuntimeError("Bottom toolbar")

    ui.statusbar(model.uiRuntime)

  ui.renderFloatingDock(model)
  ui.flushModelRedraw(model)

proc start =
  let config = AppConfig.init(width = 900, height = 640, title = "Nide")
  var nide = Nide.init()
  nide.configureBridge()
  nide.evaluator.registerInternalCommands(nide.bridge)
  nide.uiRuntime.evaluator.registerInternalCommands(nide.bridge)
  nide.uiRuntime.evaluator.registerToolbarBuilderCommands()
  nide.uiRuntime.evaluator.registerPanelBuilderCommands()

  try:
    nide.ensureNideUserFiles()
    nide.modeRegistry = loadModeRegistry()
    nide.loadProjectManager()
    nide.runNideSource(NideCommandsSource, currentSourcePath().parentDir /
        "commands.owl")
    nide.uiRuntime.evaluator.env.bindText(VarStatus, nide.status)
    discard nide.uiRuntime.evaluator.exec(parse(NideLoadSource,
        currentSourcePath().parentDir / "load.owl"))
    nide.runUserConfig()
    nide.toolbars = nide.uiRuntime.evaluator.env.readToolbars("nide-toolbars")
    nide.panels = nide.uiRuntime.evaluator.env.readPanels("nide-panels")
  except OwlError as error:
    stderr.write report(error, useColor = true)
    quit 1
  except CatchableError as error:
    stderr.writeLine error.msg
    quit 1

  runApp(config, nide, nideApplication)

when isMainModule:
  start()
