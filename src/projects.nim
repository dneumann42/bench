import owl

import std/[os, streams, tables]

type
  ProjectProfileCommandKind* = enum
    Build
    Run
    Check
    Format

  ProjectProfileCommand* = object
    shellCommand: string

  ProjectProfile* = object
    name: string
    profileCommands: Table[ProjectProfileCommandKind, ProjectProfileCommand]

  Project* = object
    name*: string
    directoryPath*: string
    profiles*: seq[ProjectProfile]

  ProjectManager* = object
    projects: seq[Project]
    activeProject: string

const InvalidProjectName* = ""

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
  pm.projects.add Project(name: name, directoryPath: normalized, profiles: @[])
  true

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

proc projectsValue*(pm: ProjectManager): Value =
  var projectValues: seq[Value]
  for project in pm.projects:
    if project.name == pm.activeProject:
      projectValues.add project.toOwl()
  for project in pm.projects:
    if project.name != pm.activeProject:
      projectValues.add project.toOwl()
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
  if loaded.kind == List and loaded.items.len > 0:
    result = fromOwl(loaded.items[0], T)
  else:
    fromOwl(loaded, result)
  result.heal()
