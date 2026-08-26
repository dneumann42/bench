import std/[algorithm, math, os, osproc, posix, sets, streams, strutils, tables]

import nest, owl
import nest/dialogs
import nest/errorDialogs
import nest/owldsl
import nest/resources
import nest/screen
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
  NideKeybindingsFileName = "keybindings.owl"

type
  PendingFileAction = enum
    NoFileAction
    OpenFileAction
    SaveFileAction

  SaveDialogRequest = ref object
    callback: proc(path: string)

  NideRequestHandler = proc(model: var Nide, request: NideBridgeRequest)

  ProcessJobStatus = enum
    ProcessRunning
    ProcessSucceeded
    ProcessFailed
    ProcessKilled

  ProcessJob = object
    id: string
    kind: ProjectProfileCommandKind
    projectName: string
    profileName: string
    directoryPath: string
    command: string
    process: osproc.Process
    output: EditorState
    status: ProcessJobStatus
    exitCode: int
    cardDismissed: bool
    outputNonBlocking: bool
    spinnerFrame: int

  ProcessSpinner = ref object of Component
    running: bool
    ok: bool
    frame: int

  ActiveEditorSnapshot = object
    bufferID: string
    bufferPath: string
    bufferText: string
    textLength: int
    cursor: int
    line: int
    column: int
    selectionStart: int
    selectionStop: int
    hasSelection: bool
    selectedText: string
    inputDriver: string
    cursorStyle: string

  NideViewerBuffer = object
    id: BufferID
    path: string
    name: string
    mode: string
    editor: EditorState

  NideViewerContext = ref object
    buffers: Table[BufferID, NideViewerBuffer]
    currentBufferID: BufferID
    pendingEditorFocus: BufferID

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
    floatingActivationGeneration: int
    floatingWidth: float64
    floatingHeight: float64
    bufferPreviewID: BufferID
    processJobs: seq[ProcessJob]
    nextProcessJob: int
    activeProcessJobID: string
    openBuildLaunchTab: bool
    openRunLaunchTab: bool
    openCheckLaunchTab: bool
    needsRedraw: bool
    pendingFileAction: PendingFileAction
    pendingPath: string
    pendingEditorFocus: BufferID
    viewerContext: NideViewerContext
    status: string

const SpinnerSize = 18

proc new(T: typedesc[ProcessSpinner], running, ok: bool, frame = 0): T =
  T(running: running, ok: ok, frame: frame)

method measure*(self: ProcessSpinner, resources: Resources): IntrinsicSize =
  discard self
  discard resources
  intrinsicSize(SpinnerSize.float64, SpinnerSize.float64)

method draw*(self: ProcessSpinner, widget: Widget, ctx: var DrawContext) =
  let
    f = widget.frame
    x = f.x.toInt
    y = f.y.toInt
    w = max(f.width.toInt, 1)
    h = max(f.height.toInt, 1)
    cx = x + w div 2
    cy = y + h div 2
    radius = min(w, h) div 2 - 2
  if radius <= 0:
    return

  if self.running:
    const Steps = 12
    let active = self.frame mod Steps
    for step in 0 ..< Steps:
      let
        alpha = uint8((80 + ((step + Steps - active) mod Steps) * 15).clamp(0, 240))
        angle = (step.float64 / Steps.float64) * 2.0 * PI
        px = cx + (cos(angle) * radius.float64).round.int
        py = cy + (sin(angle) * radius.float64).round.int
        dotSize = if step == active: 4 else: 3
      fillRect(rect(px - dotSize div 2, py - dotSize div 2, dotSize, dotSize),
          color(156, 226, 198, alpha))
    ctx.requestRedrawAfter(16)
  elif self.ok:
    drawLine(cx - 6, cy, cx - 2, cy + 5, color(125, 206, 176))
    drawLine(cx - 2, cy + 5, cx + 7, cy - 6, color(125, 206, 176))
    drawLine(cx - 6, cy + 1, cx - 2, cy + 6, color(125, 206, 176))
    drawLine(cx - 2, cy + 6, cx + 7, cy - 5, color(125, 206, 176))
  else:
    drawLine(cx - 6, cy - 6, cx + 6, cy + 6, color(230, 108, 108))
    drawLine(cx + 6, cy - 6, cx - 6, cy + 6, color(230, 108, 108))
    drawLine(cx - 6, cy - 5, cx + 6, cy + 7, color(230, 108, 108))
    drawLine(cx + 6, cy - 5, cx - 6, cy + 7, color(230, 108, 108))

proc processSpinner(ui: var UI, id: WidgetID, running, ok: bool, frame = 0) =
  if running:
    ui.markRealtime(id)
  discard ui.component(id, Component(ProcessSpinner.new(running, ok, frame)),
      fixed(SpinnerSize.float64), fixed(SpinnerSize.float64),
      renderKeyOverride = "process-spinner:" & $running & ":" & $ok & ":" &
        $frame)

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
      processJobs: @[],
      nextProcessJob: 1,
      viewerContext: NideViewerContext(
        buffers: initTable[BufferID, NideViewerBuffer](),
        currentBufferID: InvalidBufferID,
        pendingEditorFocus: InvalidBufferID,
      ),
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

proc nideKeybindingsPath(): string =
  nideConfigDir() / NideKeybindingsFileName

proc ensureNideUserFiles(model: var Nide) =
  let dir = nideConfigDir()
  createDir(dir)
  createDir(nideModesDir())
  createDir(nideViewersDir())

  let projectsPath = nideProjectsPath()
  if not fileExists(projectsPath):
    var stream = openFileStream(projectsPath, fmWrite)
    if stream.isNil:
      raise newException(IOError, "could not create " & projectsPath)
    stream.write(model.projectManager)
    stream.close()

  let configPath = nideConfigPath()
  if not fileExists(configPath):
    writeFile(configPath, """; Nide user config.
; Per-frame keyboard config belongs in keybindings.owl.

; Build, run, and check show the small process card by default.
; Set any of these to true to also open its launch tab automatically.
set-build-launch-tab false
set-run-launch-tab false
set-check-launch-tab false

; Override dialog list navigation by redefining dialog-list-keybindings.
; The default binds Up/Ctrl-P to previous and Down/Ctrl-N to next:
; fun dialog-list-keybindings previousCommand nextCommand:
;   keymap:
;     key "up" previousCommand
;     ctrl "p" previousCommand
;     key "down" nextCommand
;     ctrl "n" nextCommand
""")

  let keybindingsPath = nideKeybindingsPath()
  if not fileExists(keybindingsPath):
    writeFile(keybindingsPath, "import \"" & (NideSourceDir / "editor-input.owl") & "\"\n" & """

; Choose "emacs", "vscode", or "vi".
set editorInputDriver "emacs"

widget nide-user-keybindings:
  events:
    nothing
""")

proc processLaunchTabSetting(model: Nide,
    kind: ProjectProfileCommandKind): bool =
  case kind
  of Build:
    model.openBuildLaunchTab
  of Run:
    model.openRunLaunchTab
  of Check:
    model.openCheckLaunchTab
  of Format:
    false

proc setProcessLaunchTabSetting(model: var Nide,
    kind: ProjectProfileCommandKind, open: bool) =
  case kind
  of Build:
    model.openBuildLaunchTab = open
  of Run:
    model.openRunLaunchTab = open
  of Check:
    model.openCheckLaunchTab = open
  of Format:
    discard

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

proc activeEditorSnapshot(model: Nide, includeText = false): ActiveEditorSnapshot =
  result.line = 1
  result.column = 1
  let id = model.activeBufferID()
  if not model.buffers.hasBuffer(id):
    return

  let buffer = model.buffers.buffers[id]
  result.bufferID = string(id)
  result.bufferPath = buffer.path
  result.textLength = buffer.editor.text.len
  if includeText:
    result.bufferText = buffer.editor.text
  result.cursor = buffer.editor.cursor
  let lineColumn = buffer.editor.lineColumn()
  result.line = lineColumn.line
  result.column = lineColumn.column
  let selection = buffer.editor.selectionRange()
  result.selectionStart = selection.first
  result.selectionStop = selection.last
  result.hasSelection = buffer.editor.hasSelection()
  result.selectedText = buffer.editor.selectedText()
  result.inputDriver = buffer.editor.inputDriver
  result.cursorStyle =
    case buffer.editor.cursorStyle
    of EditorBlockCursor: "block"
    of EditorLineCursor: "line"

proc requestFrame(model: var Nide) =
  model.needsRedraw = true

proc processJobKey(id: string): string =
  "process:" & id

proc processJobTitle(job: ProcessJob): string =
  job.kind.commandKindName() & " " & job.profileName

proc processJobStatusText(job: ProcessJob): string =
  case job.status
  of ProcessRunning:
    "Running"
  of ProcessSucceeded:
    "Succeeded"
  of ProcessFailed:
    "Failed (" & $job.exitCode & ")"
  of ProcessKilled:
    "Killed"

proc appendOutput(job: var ProcessJob, chunk: string) =
  if chunk.len == 0:
    return
  job.output.text.add chunk
  job.output.cursor = job.output.text.len
  job.output.selectionAnchor = -1
  job.output.ensureCursorVisible = true
  job.output.touchText()

proc setProcessOutputNonBlocking(job: var ProcessJob) =
  if job.process.isNil or job.outputNonBlocking:
    return
  try:
    let handle = cint(job.process.outputHandle())
    let flags = posix.fcntl(handle, F_GETFL)
    if flags >= 0:
      discard posix.fcntl(handle, F_SETFL, flags or O_NONBLOCK)
      job.outputNonBlocking = true
  except CatchableError:
    discard

proc drainProcessOutput(job: var ProcessJob): bool =
  if job.process.isNil:
    return false
  job.setProcessOutputNonBlocking()
  var buffer: array[8192, char]
  for _ in 0 ..< 16:
    let count = posix.read(cint(job.process.outputHandle()), addr buffer[0],
        buffer.len)
    if count <= 0:
      break
    var chunk = newStringOfCap(count)
    for index in 0 ..< count:
      chunk.add buffer[index]
    job.appendOutput(chunk)
    result = true

proc finishProcessJob(job: var ProcessJob, exitCode: int) =
  job.exitCode = exitCode
  if job.status == ProcessRunning:
    job.status =
      if exitCode == 0: ProcessSucceeded else: ProcessFailed
  if not job.process.isNil:
    try:
      job.process.close()
    except CatchableError:
      discard
    job.process = nil

proc pollProcessJobs(model: var Nide) =
  var changed = false
  for job in model.processJobs.mitems:
    if job.status != ProcessRunning:
      continue
    inc job.spinnerFrame
    changed = true
    if job.drainProcessOutput():
      changed = true
    if not job.process.isNil:
      let exitCode =
        try:
          job.process.peekExitCode()
        except CatchableError:
          -1
      if exitCode >= 0:
        discard job.drainProcessOutput()
        job.finishProcessJob(exitCode)
        changed = true
  if changed:
    model.requestFrame()

proc processJobIndex(model: Nide, id: string): int =
  for index, job in model.processJobs:
    if job.id == id:
      return index
  -1

proc reusableProcessJobIndex(model: Nide, kind: ProjectProfileCommandKind): int =
  if kind notin {Build, Run}:
    return -1
  for index, job in model.processJobs:
    if job.kind == kind:
      return index
  -1

proc hasRunningProcessJob(model: Nide): bool =
  for job in model.processJobs:
    if job.status == ProcessRunning:
      return true

proc openProcessJob(model: var Nide, id: string) =
  let index = model.processJobIndex(id)
  if index < 0:
    return
  model.activeProcessJobID = id
  model.floatingOpen = true
  model.floatingTabKey = processJobKey(id)
  inc model.floatingActivationGeneration
  model.requestFrame()

proc killProcessJob(job: var ProcessJob) =
  if job.status != ProcessRunning:
    return
  job.status = ProcessKilled
  job.exitCode = 143
  if not job.process.isNil:
    try:
      let pid = job.process.processID()
      if pid > 0:
        discard posix.kill(Pid(-pid), SIGTERM)
    except CatchableError:
      discard
    try:
      job.process.terminate()
    except CatchableError:
      discard
    try:
      discard job.process.waitForExit(0)
    except CatchableError:
      discard
    discard job.drainProcessOutput()
    try:
      job.process.close()
    except CatchableError:
      discard
    job.process = nil
  job.appendOutput("\n[process killed]\n")

proc launchProcessJob(job: var ProcessJob): string =
  job.process = nil
  job.output = EditorState.new("")
  job.status = ProcessRunning
  job.exitCode = -1
  job.cardDismissed = false
  job.outputNonBlocking = false
  job.spinnerFrame = 0
  job.appendOutput("$ " & job.command & "\n\n")
  try:
    try:
      job.process = osproc.startProcess("setsid", args = @["sh", "-lc",
          job.command], workingDir = job.directoryPath, options = {poUsePath,
          poStdErrToStdOut})
    except CatchableError:
      job.process = osproc.startProcess("sh", args = @["-lc", job.command],
          workingDir = job.directoryPath, options = {poUsePath, poStdErrToStdOut})
    job.setProcessOutputNonBlocking()
  except CatchableError as error:
    job.status = ProcessFailed
    job.exitCode = 127
    job.appendOutput("Failed to start: " & error.msg & "\n")
    return error.msg

proc startProcessJob(
    model: var Nide,
    kind: ProjectProfileCommandKind,
    projectName, profileName, directoryPath, command: string,
) =
  var index = model.reusableProcessJobIndex(kind)
  var id: string
  if index >= 0:
    id = model.processJobs[index].id
  else:
    id = $model.nextProcessJob
    inc model.nextProcessJob
  var job = ProcessJob(
    id: id,
    kind: kind,
    projectName: projectName,
    profileName: profileName,
    directoryPath: directoryPath,
    command: command,
  )
  if index >= 0 and model.processJobs[index].status == ProcessRunning:
    model.processJobs[index].killProcessJob()
  let startError = job.launchProcessJob()
  if startError.len == 0:
    model.status = kind.commandKindName() & " started: " & command
  else:
    model.status = kind.commandKindName() & " failed to start: " & command
  if index >= 0:
    model.processJobs[index] = job
  else:
    model.processJobs.add job
  if model.processLaunchTabSetting(kind):
    model.openProcessJob(id)
  else:
    model.requestFrame()

proc restartProcessJob(model: var Nide, index: int) =
  if index < 0 or index >= model.processJobs.len:
    return
  let previous = model.processJobs[index]
  if model.processJobs[index].status == ProcessRunning:
    model.processJobs[index].killProcessJob()
  var job = ProcessJob(
    id: previous.id,
    kind: previous.kind,
    projectName: previous.projectName,
    profileName: previous.profileName,
    directoryPath: previous.directoryPath,
    command: previous.command,
  )
  let startError = job.launchProcessJob()
  model.processJobs[index] = job
  if startError.len == 0:
    model.status = previous.kind.commandKindName() & " restarted: " &
        previous.command
  else:
    model.status = previous.kind.commandKindName() & " failed to restart: " &
        previous.command
  model.requestFrame()

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
  var targetPane = model.activeEditorPane()
  if targetPane == InvalidPaneID or targetPane notin model.panes.panes:
    targetPane = model.panes.firstLeaf(model.panes.rootPane)
  if targetPane == InvalidPaneID:
    model.status = "Open failed: no focused editor pane"
    return
  model.panes.focus(targetPane)
  model.lastFocusedEditorPane = targetPane
  try:
    let existingID = model.buffers.findByPath(path)
    if existingID != InvalidBufferID:
      model.panes.setActiveBuffer(existingID)
      model.pendingEditorFocus = existingID
      model.status = "Opened " & path
      model.requestFrame()
      return
    let newID = model.buffers.openBuffer(path)
    model.panes.setActiveBuffer(newID)
    model.applyFileMode(newID)
    model.pendingEditorFocus = newID
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
  model.panes.setActiveBuffer(bufferID)
  model.status = "Split column"
  model.requestFrame()

proc splitRow(model: var Nide) =
  let bufferID = model.buffers.newScratchBuffer()
  discard model.panes.addRow(bufferID)
  model.panes.setActiveBuffer(bufferID)
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
  let editor = model.activeEditorSnapshot(includeText = true)
  model.evaluator.env.bindValue(VarState, stateSnapshot(
    model.bufferIDs(),
    editor.bufferPath,
    editor.bufferText,
    editor.bufferID,
    editor.cursor,
    editor.line,
    editor.column,
    editor.selectionStart,
    editor.selectionStop,
    editor.hasSelection,
    editor.selectedText,
    editor.inputDriver,
    editor.cursorStyle,
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
  model.buffers.buffers[id].viewer = mode.viewerForMode()
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
        inc model.floatingActivationGeneration
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
      inc model.floatingActivationGeneration
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
      inc model.floatingActivationGeneration
      model.status = panel.title & " undocked"
      model.requestFrame()
      return true

proc floatPane(model: var Nide, paneID: PaneID): bool =
  if paneID notin model.panes.panes or not model.panes.panes[paneID].isLeaf:
    return false
  model.panes.setFloating(paneID, true)
  model.floatingOpen = true
  model.floatingTabKey = "pane:" & paneID
  inc model.floatingActivationGeneration
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
  model.pendingEditorFocus = bufferID
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
    entries["viewer"] = text(buffer.viewer)
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

proc bufferViewer(model: Nide, id: BufferID): string =
  if model.buffers.hasBuffer(id):
    model.buffers.buffers[id].viewer
  else:
    "text"

proc refreshViewerContext(model: var Nide, bufferID: BufferID) =
  model.viewerContext.buffers.clear()
  model.viewerContext.currentBufferID = bufferID
  model.viewerContext.pendingEditorFocus = model.pendingEditorFocus
  for id, buffer in model.buffers.buffers.pairs:
    model.viewerContext.buffers[id] = NideViewerBuffer(
      id: id,
      path: buffer.path,
      name: buffer.name,
      mode: string(buffer.fileMode),
      editor: buffer.editor,
    )

proc evalOptionalText(env: owl.Environment, arguments: seq[SyntaxNode],
    index: int, fallback: string): string {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    return fallback
  let value = env.eval(arguments[index])
  case value.kind
  of Text:
    value.text
  of Number:
    if value.number == value.number.int.float:
      $value.number.int
    else:
      $value.number
  of Boolean:
    if value.boolean: "true" else: "false"
  else:
    fallback

proc evalOptionalBufferID(context: NideViewerContext, env: owl.Environment,
    arguments: seq[SyntaxNode], index: int): BufferID {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    let id = context.currentBufferID
    if context.buffers.hasKey(id):
      return id
    raise newException(EvaluatorError, "no viewer buffer is currently rendering")
  let candidate = env.evalOptionalText(arguments, index, "")
  if context.buffers.hasKey(candidate):
    return candidate
  raise newException(EvaluatorError, "unknown viewer buffer id: " & candidate)

proc evalOptionalBool(env: owl.Environment, arguments: seq[SyntaxNode],
    index: int, fallback: bool): bool {.raises: [EvaluatorError].} =
  if index >= arguments.len:
    return fallback
  let value = env.eval(arguments[index])
  case value.kind
  of Boolean:
    value.boolean
  of Number:
    value.number != 0
  of Text:
    value.text.len > 0 and value.text != "false"
  else:
    fallback

proc registerViewerCommands(context: NideViewerContext, runtime: NestOwlRuntime) =
  var module = nativeModule"nide/viewers"

  module.defineNative("active-buffer-path", proc(
      env: owl.Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len > 1:
      raise newException(EvaluatorError,
          "active-buffer-path expects optional buffer id")
    let id = context.evalOptionalBufferID(env, arguments, 0)
    text(context.buffers.getOrDefault(id).path)
  )

  module.defineNative("active-buffer-name", proc(
      env: owl.Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len > 1:
      raise newException(EvaluatorError,
          "active-buffer-name expects optional buffer id")
    let id = context.evalOptionalBufferID(env, arguments, 0)
    text(context.buffers.getOrDefault(id).name)
  )

  module.defineNative("active-buffer-text", proc(
      env: owl.Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len > 1:
      raise newException(EvaluatorError,
          "active-buffer-text expects optional buffer id")
    let id = context.evalOptionalBufferID(env, arguments, 0)
    text(context.buffers.getOrDefault(id).editor.text)
  )

  module.defineNative("active-buffer-mode", proc(
      env: owl.Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard env
    discard layout
    discard bodyNodes
    if arguments.len > 1:
      raise newException(EvaluatorError,
          "active-buffer-mode expects optional buffer id")
    let id = context.evalOptionalBufferID(env, arguments, 0)
    text(context.buffers.getOrDefault(id).mode)
  )

  module.defineNative("active-buffer-editor", proc(
      env: owl.Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len > 3:
      raise newException(EvaluatorError,
          "active-buffer-editor expects optional buffer id, id, and readOnly")
    let
      explicitBuffer = arguments.len == 3
      id =
        if explicitBuffer:
          context.evalOptionalBufferID(env, arguments, 0)
        else:
          context.currentBufferID
    if not context.buffers.hasKey(id):
      return nothing()
    try:
      let
        key = env.evalOptionalText(arguments, if explicitBuffer: 1 else: 0, id)
        readOnly = env.evalOptionalBool(arguments, if explicitBuffer: 2 else: 1,
            false)
        buffer = context.buffers.getOrDefault(id)
        editorID = runtime.requireCurrentUi().id("viewer-editor", id, key)
        syntaxName = buffer.editor.syntax.name
      runtime.requireCurrentUi().textEditor(editorID,
          buffer.editor, width = fill(min = MinPaneWidth),
          height = fill(min = MinPaneHeight), fontName = "editor",
          lineNumbers = true, scrollbars = true, readOnly = readOnly,
          syntax = syntaxName)
      if context.pendingEditorFocus == id:
        runtime.requireCurrentUi().focus(editorID)
        context.pendingEditorFocus = InvalidBufferID
    except KeyError:
      discard
    except Exception as error:
      raise newException(EvaluatorError, error.msg)
    nothing()
  )

  runtime.evaluator.registerModule(module)

proc publishActiveEditorData(model: Nide, bridge: NideOwlBridge) =
  let editor = model.activeEditorSnapshot()
  bridge.putData("active-buffer-id", text(editor.bufferID))
  bridge.putData("active-buffer-path", text(editor.bufferPath))
  bridge.putData("active-editor-text-length", number(editor.textLength.float64))
  bridge.putData("active-editor-cursor", number(editor.cursor.float64))
  bridge.putData("active-editor-line", number(editor.line.float64))
  bridge.putData("active-editor-column", number(editor.column.float64))
  bridge.putData("active-editor-selection-start", number(editor.selectionStart.float64))
  bridge.putData("active-editor-selection-stop", number(editor.selectionStop.float64))
  bridge.putData("active-editor-has-selection", boolean(editor.hasSelection))
  bridge.putData("active-editor-selected-text", text(editor.selectedText))
  bridge.putData("active-editor-input-driver", text(editor.inputDriver))
  bridge.putData("active-editor-cursor-style", text(editor.cursorStyle))

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
  model.bridge.putData("floating-activation-generation",
      number(model.floatingActivationGeneration.float64))
  model.bridge.putData("buffers", model.buffersValue())
  model.bridge.putData("buffer-preview-text", text(model.bufferPreviewText()))
  model.bridge.putData("active-buffer-mode", text(model.activeBufferMode()))
  model.bridge.putData("auto-track-opened-projects",
      boolean(NideAutoTrackOpenedProjects))
  model.bridge.putData("open-build-launch-tab",
      boolean(model.openBuildLaunchTab))
  model.bridge.putData("open-run-launch-tab", boolean(model.openRunLaunchTab))
  model.bridge.putData("open-check-launch-tab",
      boolean(model.openCheckLaunchTab))
  model.publishActiveEditorData(model.bridge)

proc registerRequest(model: var Nide, name: string,
    handler: NideRequestHandler) =
  model.requestHandlers[name] = handler

proc requestText(request: NideBridgeRequest, index: int): string =
  if index >= 0 and index < request.arguments.len and
      request.arguments[index].kind == Text:
    request.arguments[index].text
  else:
    ""

proc requestNumber(request: NideBridgeRequest, index: int): int =
  if index < 0 or index >= request.arguments.len:
    return 0
  if request.arguments[index].kind == Number:
    request.arguments[index].number.int
  else:
    0

proc requestBool(request: NideBridgeRequest, index: int): bool =
  if index < 0 or index >= request.arguments.len:
    return false
  if request.arguments[index].kind == Boolean:
    request.arguments[index].boolean
  else:
    false

proc requestCursorStyle(request: NideBridgeRequest, index: int): EditorCursorStyle =
  case request.requestText(index).normalize
  of "block", "box":
    EditorBlockCursor
  else:
    EditorLineCursor

proc editorWordChar(ch: char): bool =
  ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}

proc editorWordForwardCursor(text: string, cursor: int): int =
  result = cursor.clamp(0, text.len)
  while result < text.len and text[result].editorWordChar:
    inc result
  while result < text.len and not text[result].editorWordChar:
    inc result

proc editorWordBackwardCursor(text: string, cursor: int): int =
  result = cursor.clamp(0, text.len)
  while result > 0 and not text[result - 1].editorWordChar:
    dec result
  while result > 0 and text[result - 1].editorWordChar:
    dec result

proc deleteEditorRange(editor: EditorState, first, last: int) =
  let
    startIndex = first.clamp(0, editor.text.len)
    stopIndex = last.clamp(startIndex, editor.text.len)
  if stopIndex <= startIndex:
    return
  editor.selectionAnchor = startIndex
  editor.cursor = stopIndex
  discard editor.deleteSelection()

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
    elif kind in {Build, Run, Check}:
      model.startProcessJob(kind, projectName, profileName, directoryPath, command)
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

proc setProcessLaunchTabRequest(model: var Nide,
    request: NideBridgeRequest) =
  let kindName = request.requestText(0).normalize
  let open = request.requestBool(1)
  case kindName
  of "build":
    model.setProcessLaunchTabSetting(Build, open)
  of "run":
    model.setProcessLaunchTabSetting(Run, open)
  of "check":
    model.setProcessLaunchTabSetting(Check, open)
  else:
    model.status = "Unknown process launch tab kind: " & request.requestText(0)
    return
  model.publishBridgeData()

proc activeEditorCommandRequest(model: var Nide, request: NideBridgeRequest) =
  let id = model.activeBufferID()
  if not model.buffers.hasBuffer(id):
    return

  let command = request.requestText(0).normalize
  let editor = model.buffers.buffers[id].editor
  case command
  of "settext", "replace-text", "replacetext":
    editor.replaceText(request.requestText(1))
  of "clear":
    editor.replaceText("")
  of "insert", "insert-text", "inserttext":
    editor.insertText(request.requestText(1), request.requestBool(2))
  of "setcursor", "set-cursor":
    editor.setCursor(request.requestNumber(1), request.requestBool(2))
  of "setlinecolumn", "set-line-column":
    editor.setCursor(
      editor.cursorForLineColumn(request.requestNumber(1), request.requestNumber(2))
    )
  of "wordforward", "word-forward":
    editor.setCursor(editorWordForwardCursor(editor.text, editor.cursor))
  of "wordbackward", "word-backward":
    editor.setCursor(editorWordBackwardCursor(editor.text, editor.cursor))
  of "deletewordforward", "delete-word-forward":
    editor.deleteEditorRange(
      editor.cursor,
      editorWordForwardCursor(editor.text, editor.cursor),
    )
  of "deletewordbackward", "delete-word-backward":
    editor.deleteEditorRange(
      editorWordBackwardCursor(editor.text, editor.cursor),
      editor.cursor,
    )
  of "setselection", "set-selection":
    let
      startIndex = request.requestNumber(1).clamp(0, editor.text.len)
      stopIndex = request.requestNumber(2).clamp(0, editor.text.len)
    editor.selectionAnchor = startIndex
    editor.cursor = stopIndex
  of "clearselection", "clear-selection":
    editor.clearSelection()
  of "selectall", "select-all":
    editor.selectAll()
  of "deleteselection", "delete-selection":
    discard editor.deleteSelection()
  of "deletebackward", "delete-backward":
    editor.deleteBackward()
  of "deleteforward", "delete-forward":
    editor.deleteForward()
  of "killlinestart", "kill-line-start":
    editor.killToStart()
  of "killlineend", "kill-line-end":
    editor.killToEnd()
  of "copyselection", "copy-selection":
    discard editor.copySelection()
  of "cutselection", "cut-selection":
    discard editor.cutSelection()
  of "pasteclipboard", "paste-clipboard":
    editor.pasteClipboard(request.requestBool(1))
  of "undo":
    editor.undo()
  of "redo":
    editor.redo()
  of "setinputdriver", "set-input-driver":
    let driver = request.requestText(1).normalize
    if editor.inputDriver == driver:
      return
    editor.inputDriver = driver
  of "setcursorstyle", "set-cursor-style":
    let style = request.requestCursorStyle(1)
    if editor.cursorStyle == style:
      return
    editor.cursorStyle = style
  else:
    model.status = "Unknown editor command: " & request.requestText(0)
    return
  editor.ensureCursorVisible = true
  model.requestFrame()

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
  model.registerRequest("active-editor.command", activeEditorCommandRequest)
  model.registerRequest("file-explorer.open", fileExplorerOpenRequest)
  for action in ["select", "toggle", "refresh", "search", "sort", "filter", "hidden"]:
    model.registerRequest("file-explorer." & action, fileExplorerEventRequest)
  model.registerRequest("process.launch-tab.set", setProcessLaunchTabRequest)
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

proc renderFallbackTextEditor(ui: var UI, model: var Nide, paneID: PaneID,
    bufferID: BufferID) =
  let editorID = ui.id("editor", bufferID)
  ui.textEditor(editorID, model.buffers.buffers[bufferID].editor,
      width = fill(min = MinPaneWidth), height = fill(min = MinPaneHeight),
      fontName = "editor", lineNumbers = true, scrollbars = true,
      syntax = model.buffers.buffers[bufferID].editor.syntax.name)
  if model.pendingEditorFocus == bufferID and paneID == model.panes.activePane:
    ui.focus(editorID)
    model.pendingEditorFocus = InvalidBufferID

proc renderBufferViewer(ui: var UI, model: var Nide, paneID: PaneID,
    bufferID: BufferID) =
  if not model.buffers.hasBuffer(bufferID):
    return
  let
    viewer = model.bufferViewer(bufferID)
    script = viewer.viewerSource()
  if viewer == "text":
    ui.renderFallbackTextEditor(model, paneID, bufferID)
    return
  if script.source.len == 0 or script.path.len == 0:
    ui.renderFallbackTextEditor(model, paneID, bufferID)
    return
  model.refreshViewerContext(bufferID)
  registerViewerCommands(model.viewerContext, model.uiRuntime)
  model.uiRuntime.loadedModules.excl script.path.normalizedPath
  var renderFailed = false
  model.uiRuntime.evaluator.env.bindText("nide-viewer-buffer-id", bufferID)
  try:
    model.uiRuntime.renderWidget(ui, script.path, script.widget, [bufferID])
  except CatchableError as error:
    renderFailed = true
    model.status = "Viewer " & viewer & " failed; see Owl error dialog"
    model.owlErrorApp.launchOwlErrorDialog(ErrorDetails(
      message: "Viewer " & viewer & " failed: " & error.msg,
      primary: ErrorLocation(path: script.path),
    ))
  finally:
    model.pendingEditorFocus = model.viewerContext.pendingEditorFocus
  if renderFailed:
    model.uiRuntime.evaluator.env.bindText(VarStatus, model.status)
    return
  if model.consumeRuntimeError("Viewer " & viewer):
    model.uiRuntime.evaluator.env.bindText(VarStatus, model.status)
    return
  model.processBridgeRequests()
  ui.flushModelRedraw(model)

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
        height = fill(min = MinPaneHeight), padding = 2, gap = 1,
        alignSelf = AlignStretch).withBackground(background)):
      ui.row(ui.id("paneHeader", paneID), cfg(width = fill(), height = fixed(24),
          gap = 4, alignItems = AlignCenter)):
        ui.label(ui.id("paneTitle", paneID),
            bufferTitle(model.buffers.buffers[pane.bufferID]), width = fill())
        if floatingContent:
          if ui.button(ui.id("paneDock", paneID), "", width = fixed(24),
              height = fixed(24), buttonVariant = ButtonIcon, fontName = "icon"):
            discard model.dockPane(paneID)
          ui.tooltip(ui.id("paneDock", paneID), "Dock pane")
        else:
          if ui.button(ui.id("paneFloat", paneID), "", width = fixed(24),
              height = fixed(24), buttonVariant = ButtonIcon, fontName = "icon"):
            discard model.floatPane(paneID)
          ui.tooltip(ui.id("paneFloat", paneID), "Undock pane")
        if ui.button(ui.id("paneClose", paneID), "", width = fixed(24),
            height = fixed(24), buttonVariant = ButtonIcon, fontName = "icon"):
          discard model.closePane(paneID)
        ui.tooltip(ui.id("paneClose", paneID), "Close pane")
      ui.renderBufferViewer(model, paneID, pane.bufferID)

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
          if ui.button(ui.id("panelDockFloat", panel.id), "", width = fixed(30),
              height = fit(), buttonVariant = ButtonIcon, fontName = "icon"):
            discard model.floatPanel(panel.id)
          ui.tooltip(ui.id("panelDockFloat", panel.id), "Undock panel")
        model.uiRuntime.renderWidget(ui, NideSourceDir /
            panel.source, panel.widget)
        if model.consumeRuntimeError(panel.title & " panel"):
          model.uiRuntime.evaluator.env.bindText(VarStatus, model.status)
        model.processBridgeRequests()
        ui.flushModelRedraw(model)

proc renderProcessJobTab(ui: var UI, model: var Nide, index: int) =
  if index < 0 or index >= model.processJobs.len:
    return
  let job = model.processJobs[index]
  ui.column(ui.id("processJob", job.id), cfg(width = fill(), height = fill(),
      padding = 0, gap = 8, alignItems = AlignStretch)):
    ui.row(ui.id("processJobHeader", job.id), cfg(width = fill(), height = fit(),
        padding = 8, gap = 10, alignItems = AlignCenter).withBackground(
        color(30, 34, 38))):
      ui.processSpinner(ui.id("processJobIcon", job.id),
          job.status == ProcessRunning, job.status == ProcessSucceeded,
          job.spinnerFrame)
      ui.label(ui.id("processJobTitle", job.id), job.processJobTitle(),
          width = fit(), height = fit())
      ui.label(ui.id("processJobStatus", job.id), job.processJobStatusText(),
          width = fit(), height = fit())
      ui.label(ui.id("processJobCommand", job.id), job.command, width = fill(),
          height = fit(), textScroll = true)

    ui.textEditor(ui.id("processJobOutput", job.id),
        model.processJobs[index].output, width = fill(), height = fill(),
        fontName = "editor", lineNumbers = false, scrollbars = true,
        readOnly = true)

    ui.row(ui.id("processJobTools", job.id), cfg(width = fill(), height = fit(),
        padding = 8, gap = 8, alignItems = AlignCenter).withBackground(
        color(24, 28, 32))):
      if model.processJobs[index].status == ProcessRunning:
        if ui.button(ui.id("processJobKill", job.id), "Kill", width = fixed(74),
            height = fit(), buttonPadding = 8):
          model.processJobs[index].killProcessJob()
          model.status = job.kind.commandKindName() & " killed"
          model.requestFrame()
      else:
        ui.label(ui.id("processJobKillPlaceholder", job.id), "", width = fixed(74),
            height = fit())
      if ui.button(ui.id("processJobRestart", job.id), "Restart", width = fixed(92),
          height = fit(), buttonPadding = 8):
        model.restartProcessJob(index)
      ui.label(ui.id("processJobDirectory", job.id), job.directoryPath, width = fill(),
          height = fit(), textScroll = true)

proc renderProcessCards(ui: var UI, model: var Nide) =
  var visible: seq[int]
  for index, job in model.processJobs:
    if not job.cardDismissed and job.kind in {Build, Run, Check}:
      visible.add index
  if visible.len == 0:
    return

  ui.column(ui.id("processCards"), cfg(width = fixed(360), height = fit(
      max = 260), gap = 8, padding = 0, alignSelf = AlignEnd,
      alignItems = AlignStretch)):
    for index in visible:
      let job = model.processJobs[index]
      let cardID = ui.id("processCard", job.id)
      let dismissID = ui.id("processCardDismiss", job.id)
      ui.card(cardID, cfg(width = fill(), height = fixed(64), padding = 8,
          gap = 0,
          alignSelf = AlignEnd, alignItems = AlignStretch).withBackground(
          color(34, 39, 44, 248)).withRadii(12, 0, 0, 12).withShadow()):
        ui.row(ui.id("processCardRow", job.id), cfg(width = fill(),
            height = fixed(48), padding = 0, gap = 8,
            alignItems = AlignCenter)):
          ui.processSpinner(ui.id("processCardIcon", job.id),
              job.status == ProcessRunning, job.status == ProcessSucceeded,
              job.spinnerFrame)
          ui.column(ui.id("processCardText", job.id), cfg(width = fixed(282),
              height = fixed(42), gap = 2, padding = 0,
              alignItems = AlignStretch)):
            ui.label(ui.id("processCardTitle", job.id),
                job.kind.commandKindName() & " · " & job.processJobStatusText(),
                width = fixed(282), height = fixed(19), textScroll = true)
            ui.label(ui.id("processCardCommand", job.id), job.command,
                width = fixed(282), height = fixed(19), textScroll = true)
          if ui.button(dismissID, "", width = fixed(28),
              height = fixed(28), buttonVariant = ButtonIcon, fontName = "icon"):
            model.processJobs[index].cardDismissed = true
            model.requestFrame()
      if ui.clickedIn(cardID) and not ui.clickedIn(dismissID):
        model.openProcessJob(job.id)

proc renderFloatingDock(ui: var UI, model: var Nide) =
  var
    labels: seq[string]
    keys: seq[string]
    panelIDs: seq[string]
    paneIDs: seq[PaneID]
    processJobIDs: seq[string]
  for panel in model.panels:
    if panel.dock == PanelFloating and panel.open:
      labels.add panel.title
      keys.add "panel:" & panel.id
      panelIDs.add panel.id
      paneIDs.add InvalidPaneID
      processJobIDs.add ""
  for paneID in model.panes.floatingPaneIDs():
    if paneID in model.panes.panes:
      let bufferID = model.panes.panes[paneID].bufferID
      if model.buffers.hasBuffer(bufferID):
        labels.add bufferTitle(model.buffers.buffers[bufferID])
        keys.add "pane:" & paneID
        panelIDs.add ""
        paneIDs.add paneID
        processJobIDs.add ""
  for job in model.processJobs:
    labels.add job.processJobTitle()
    keys.add processJobKey(job.id)
    panelIDs.add ""
    paneIDs.add InvalidPaneID
    processJobIDs.add job.id

  if labels.len == 0:
    model.floatingOpen = false
    return

  if model.floatingTabKey.len > 0:
    for index, key in keys:
      if key == model.floatingTabKey:
        model.floatingTab = index
        break
  model.floatingTab = model.floatingTab.clamp(0, labels.high)
  let previousFloatingTabKey = model.floatingTabKey
  model.floatingTabKey = keys[model.floatingTab]
  if model.floatingTabKey != previousFloatingTabKey:
    inc model.floatingActivationGeneration

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
      let previousFloatingTabKey = model.floatingTabKey
      model.floatingTabKey = keys[model.floatingTab]
      if model.floatingTabKey != previousFloatingTabKey:
        inc model.floatingActivationGeneration
        model.publishBridgeData()
      let selectedPanel = panelIDs[model.floatingTab]
      let selectedPane = paneIDs[model.floatingTab]
      if selectedPanel.len > 0:
        if ui.button(ui.id("floatingPanelDock", selectedPanel), "",
            width = fixed(32), height = fit(), buttonVariant = ButtonIcon,
            fontName = "icon"):
          discard model.dockPanel(selectedPanel)
        ui.tooltip(ui.id("floatingPanelDock", selectedPanel), "Dock panel")
      elif selectedPane != InvalidPaneID:
        if ui.button(ui.id("floatingPaneDock", selectedPane), "",
            width = fixed(32), height = fit(), buttonVariant = ButtonIcon,
            fontName = "icon"):
            discard model.dockPane(selectedPane)
        ui.tooltip(ui.id("floatingPaneDock", selectedPane), "Dock pane")
      if ui.button(ui.id("floatingDockHide"), "", width = fixed(32),
          height = fit(), buttonVariant = ButtonIcon, fontName = "icon"):
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
    elif processJobIDs[model.floatingTab].len > 0:
      ui.renderProcessJobTab(model,
          model.processJobIndex(processJobIDs[model.floatingTab]))

widget nideApplication(model: var Nide):
  model.owlErrorApp.pollOwlErrorDialog()
  model.processPendingFileAction()
  if ui.inEventPhase():
    model.pollProcessJobs()
    if model.hasRunningProcessJob():
      ui.requestFullRedrawAfter(16)
  ui.flushModelRedraw(model)
  model.uiRuntime.evaluator.env.bindText(VarStatus, model.status)
  model.publishBridgeData()
  if ui.keyPressed("escape"):
    model.closeFloating()
    ui.flushModelRedraw(model)

  ui.overlay(ui.id("rootOverlay"), cfg(width = fill(), height = fill(), gap = 0)):
    ui.column(ui.id("root"), cfg(width = fill(), height = fill(), gap = 0)):
      if ui.keyboardInputPending():
        if fileExists(nideKeybindingsPath()):
          model.uiRuntime.renderWidget(ui, nideKeybindingsPath(),
              "nide-user-keybindings")
          discard model.consumeRuntimeError("User keybindings")
          model.processBridgeRequests()
          model.publishBridgeData()
          ui.flushModelRedraw(model)

        model.uiRuntime.renderWidget(ui, NideSourceDir / "keybindings.owl",
            "nide-keybindings")
        discard model.consumeRuntimeError("Keybindings")
        model.processBridgeRequests()
        ui.flushModelRedraw(model)

      for event in ui.toolbarDock(model.toolbars, model.uiRuntime, TopDock,
          NideSourceDir):
        model.handleToolbarEvent(ui, event)
      discard model.consumeRuntimeError("Top toolbar")
      model.processBridgeRequests()
      ui.flushModelRedraw(model)

      ui.renderPanelDock(model, PanelTop)

      ui.row(ui.id("workspaceDockRow"), cfg(width = fill(), height = fill(),
          gap = 0, alignSelf = AlignStretch)):
        for event in ui.toolbarDock(model.toolbars, model.uiRuntime, LeftDock,
            NideSourceDir):
          model.handleToolbarEvent(ui, event)
        discard model.consumeRuntimeError("Left toolbar")
        model.processBridgeRequests()
        ui.flushModelRedraw(model)

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
        model.processBridgeRequests()
        ui.flushModelRedraw(model)

      ui.renderPanelDock(model, PanelBottom)

      for event in ui.toolbarDock(model.toolbars, model.uiRuntime, BottomDock,
          NideSourceDir):
        model.handleToolbarEvent(ui, event)
      discard model.consumeRuntimeError("Bottom toolbar")
      model.processBridgeRequests()
      ui.flushModelRedraw(model)

      ui.statusbar(model.uiRuntime)
      model.processBridgeRequests()
      ui.flushModelRedraw(model)

    ui.overlay(ui.id("processCardsOverlay"), cfg(width = fill(), height = fill(),
        padding = 14, paddingBottom = 50, gap = 0, alignItems = AlignEnd,
        justifyContent = JustifyEnd)):
      ui.renderProcessCards(model)

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
    discard nide.uiRuntime.evaluator.exec(parse(NideCommandsSource,
        currentSourcePath().parentDir / "commands.owl"))
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

when isMainModule and not defined(nideNoMain):
  let args = commandLineParams()
  if args.len >= 2 and args[0] == "error-dialog-json":
    runOwlErrorDialog(errorDetailsFromJson(args[1]))
  elif args.len >= 2 and args[0] == "error-dialog":
    runOwlErrorDialog(args[1])
  else:
    start()
