import owl

import std/[os, streams, strutils, tables]

type
  ProjectProfileCommandKind* = enum
    Build
    Run
    Check
    Format

  ProjectProfileCommand* = object
    shellCommand*: string

  ProjectProfile* = object
    name*: string
    profileCommands*: Table[ProjectProfileCommandKind, ProjectProfileCommand]

  Project* = object
    name*: string
    directoryPath*: string
    profiles*: seq[ProjectProfile]

  ProjectManager* = object
    projects: seq[Project]
    activeProject: string

const InvalidProjectName* = ""

const ProjectCommandKinds* = [Build, Run, Check, Format]

proc normalizeProjectPath*(path: string): string

proc commandKindName*(kind: ProjectProfileCommandKind): string =
  case kind
  of Build: "Build"
  of Run: "Run"
  of Check: "Check"
  of Format: "Format"

proc parseCommandKind*(name: string): ProjectProfileCommandKind =
  case name
  of "Build", "build":
    Build
  of "Run", "run":
    Run
  of "Check", "check":
    Check
  of "Format", "format":
    Format
  else:
    raise newException(ValueError, "unknown project command kind: " & name)

proc profileCommand*(command: string): ProjectProfileCommand =
  ProjectProfileCommand(shellCommand: command)

proc projectProfile*(name: string,
    commands: openArray[(ProjectProfileCommandKind, string)]): ProjectProfile =
  result = ProjectProfile(name: name,
      profileCommands: initTable[ProjectProfileCommandKind, ProjectProfileCommand]())
  for (kind, command) in commands:
    if command.len > 0:
      result.profileCommands[kind] = profileCommand(command)

proc command*(profile: ProjectProfile,
    kind: ProjectProfileCommandKind): string =
  if kind in profile.profileCommands:
    profile.profileCommands[kind].shellCommand
  else:
    ""

proc hasCommand*(profile: ProjectProfile,
    kind: ProjectProfileCommandKind): bool =
  profile.command(kind).len > 0

proc inferPlainNimTarget(directoryPath: string, projectName = ""): string =
  let srcName =
    if projectName.len > 0:
      "src" / projectName & ".nim"
    else:
      ""
  if srcName.len > 0 and fileExists(directoryPath / srcName):
    return srcName
  for candidate in ["main.nim", projectName & ".nim", "src" / "main.nim"]:
    if candidate.len > 4 and fileExists(directoryPath / candidate):
      return candidate
  try:
    for kind, path in walkDir(directoryPath, relative = true):
      if kind == pcFile and path.endsWith(".nim"):
        return path
  except CatchableError:
    discard
  if projectName.len > 0:
    "src" / projectName & ".nim"
  else:
    "main.nim"

proc defaultProfilesForProject*(name, directoryPath: string): seq[ProjectProfile] =
  let normalized = normalizeProjectPath(directoryPath)
  if fileExists(normalized / "project.owl") or fileExists(normalized / "main.owl"):
    result.add projectProfile("Owl", [
      (Run, "nest run ."),
    ])
  var hasNimble = false
  try:
    for kind, path in walkDir(normalized, relative = true):
      if kind == pcFile and path.endsWith(".nimble"):
        hasNimble = true
        break
  except CatchableError:
    discard
  if hasNimble:
    result.add projectProfile("Nimble", [
      (Build, "nimble build"),
      (Run, "nimble run"),
      (Check, "nimble check"),
    ])
  let target = inferPlainNimTarget(normalized, name)
  if fileExists(normalized / target) or result.len == 0:
    result.add projectProfile("Nim", [
      (Build, "nim c " & target),
      (Run, "nim r " & target),
      (Check, "nim check " & target),
      (Format, "nimpretty " & target),
    ])

proc projectProfileTemplates*(): seq[ProjectProfile] =
  @[
    projectProfile("Owl", [
      (Run, "nest run ."),
    ]),
    projectProfile("Nimble", [
      (Build, "nimble build"),
      (Run, "nimble run"),
      (Check, "nimble check"),
    ]),
    projectProfile("Nim", [
      (Build, "nim c main.nim"),
      (Run, "nim r main.nim"),
      (Check, "nim check main.nim"),
      (Format, "nimpretty main.nim"),
    ]),
  ]

proc profileCommandValue(command: string): Value =
  var entries = initTable[string, Value]()
  entries["shellCommand"] = text(command)
  dictionary(entries)

proc projectProfileValue*(profile: ProjectProfile): Value =
  var
    entries = initTable[string, Value]()
    commands = initTable[string, Value]()
  entries["name"] = text(profile.name)
  for kind in ProjectCommandKinds:
    commands[kind.commandKindName()] = profileCommandValue(profile.command(kind))
  entries["profileCommands"] = dictionary(commands)
  dictionary(entries)

proc projectProfileTemplatesValue*(): Value =
  var values: seq[Value]
  for profile in projectProfileTemplates():
    values.add profile.projectProfileValue()
  list(values)

proc projectValue*(project: Project): Value =
  var
    entries = initTable[string, Value]()
    profiles: seq[Value]
  entries["name"] = text(project.name)
  entries["directoryPath"] = text(project.directoryPath)
  for profile in project.profiles:
    profiles.add profile.projectProfileValue()
  entries["profiles"] = list(profiles)
  dictionary(entries)

proc init*(T: typedesc[ProjectManager]): T =
  ProjectManager(projects: @[], activeProject: InvalidProjectName)

proc activeProjectName*(pm: ProjectManager): string =
  pm.activeProject

proc activeProjectPath*(pm: ProjectManager): string =
  for project in pm.projects:
    if project.name == pm.activeProject:
      return project.directoryPath
  ""

proc projects*(pm: ProjectManager): seq[Project] =
  pm.projects

proc normalizeProjectPath*(path: string): string =
  path.expandTilde().absolutePath().normalizedPath()

proc projectExists*(pm: ProjectManager, name: string): bool =
  result = false
  for p in pm.projects:
    if p.name == name:
      return true

proc projectPathExists*(pm: ProjectManager, path: string): bool =
  let normalized = normalizeProjectPath(path)
  for p in pm.projects:
    if normalizeProjectPath(p.directoryPath) == normalized:
      return true

proc projectNameForPath*(pm: ProjectManager, path: string): string =
  let normalized = normalizeProjectPath(path)
  for p in pm.projects:
    if normalizeProjectPath(p.directoryPath) == normalized:
      return p.name
  InvalidProjectName

proc addProject*(pm: var ProjectManager, name, directoryPath: string): bool =
  if name.len == 0 or directoryPath.len == 0:
    return false
  let normalized = normalizeProjectPath(directoryPath)
  if pm.projectExists(name) or pm.projectPathExists(normalized):
    return false
  pm.projects.add Project(name: name, directoryPath: normalized,
      profiles: defaultProfilesForProject(name, normalized))
  true

proc projectIndex(pm: ProjectManager, name: string): int =
  for index, p in pm.projects:
    if p.name == name:
      return index
  -1

proc profileIndex(project: Project, name: string): int =
  for index, profile in project.profiles:
    if profile.name == name:
      return index
  -1

proc upsertProfile*(pm: var ProjectManager, projectName, originalName: string,
    profile: ProjectProfile): bool =
  if projectName.len == 0 or profile.name.len == 0:
    return false
  let projectPos = pm.projectIndex(projectName)
  if projectPos < 0:
    return false
  let existingByName = pm.projects[projectPos].profileIndex(profile.name)
  if existingByName >= 0 and profile.name != originalName:
    return false
  let originalPos = pm.projects[projectPos].profileIndex(originalName)
  if originalPos >= 0:
    pm.projects[projectPos].profiles[originalPos] = profile
  else:
    pm.projects[projectPos].profiles.add profile
  true

proc profileCommand*(pm: ProjectManager, projectName, profileName: string,
    kind: ProjectProfileCommandKind): string =
  let projectPos = pm.projectIndex(projectName)
  if projectPos < 0:
    return ""
  let profilePos = pm.projects[projectPos].profileIndex(profileName)
  if profilePos < 0:
    return ""
  pm.projects[projectPos].profiles[profilePos].command(kind)

proc setActiveProject*(pm: var ProjectManager, name: string): bool =
  if pm.projectExists(name):
    pm.activeProject = name
    true
  else:
    false

proc unloadActiveProject*(pm: var ProjectManager) =
  pm.activeProject = InvalidProjectName

proc heal*(pm: var ProjectManager) =
  if not pm.projectExists(pm.activeProject):
    pm.activeProject = InvalidProjectName
  for project in pm.projects.mitems:
    if project.profiles.len == 0:
      project.profiles = defaultProfilesForProject(project.name,
          project.directoryPath)

proc projectsValue*(pm: ProjectManager): Value =
  var projectValues: seq[Value]
  for project in pm.projects:
    if project.name == pm.activeProject:
      projectValues.add project.projectValue()
  for project in pm.projects:
    if project.name != pm.activeProject:
      projectValues.add project.projectValue()
  list(projectValues)

proc snapshot*(pm: ProjectManager): Value =
  var entries = initTable[string, Value]()
  entries["activeProject"] = text(pm.activeProject)
  entries["projects"] = pm.projectsValue()
  dictionary(entries)

proc write*(stream: Stream, pm: ProjectManager) =
  var owlCode = pm.toOwl()
  stream.write(owlCode)
  stream.writeLine()

proc read*(stream: Stream, T: typedesc[ProjectManager]): T =
  let loaded = loadOwlSource(stream.readAll(), mode = restrictedOwlData)
  if loaded.kind == List and loaded.listLen > 0:
    result = fromOwl(loaded.at(0), T)
  else:
    fromOwl(loaded, result)
  result.heal()
