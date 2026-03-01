import std/[options, os, dirs, strformat]

import toml_serialization

 # derive vcs from directory
type
  Project* = object
    path*: string
    name*, version*, author*: string
    description*, license*: string

  ProjectManager* = object
    openProject: Option[string]
    projects: seq[string]

proc benchDirPath*(): string =
  getHomeDir() / ".local" / "bench"

proc hasNoProjects*(pm: ProjectManager): bool =
  pm.projects.len() == 0

proc projectsFileExists(): bool =
  result = fileExists(benchDirPath() / "projects.toml")

proc write*(self: ProjectManager)

proc load*(self: var ProjectManager) =
  if not projectsFileExists():
    let pm = ProjectManager()
    pm.write()
  try:
    self = Toml.loadFile(benchDirPath() / "projects.toml", ProjectManager)
  except CatchableError as e:
    echo "Failed to load projects: ", e.msg

proc write*(self: ProjectManager) =
  try:
    Toml.saveFile(benchDirPath() / "projects.toml", self)
  except CatchableError as e:
    echo "Failed to save projects: ", e.msg

proc createProject*(self: var ProjectManager, project: Project, noWrite = false) =
  let projectDir = project.path / project.name
  self.projects.add(projectDir)

  try:
    createDir(projectDir / "src")

    let nimbleContents = fmt"""
# Package
version     = "{project.version}"
author      = "{project.author}"
description = "{project.description}"
license     = "{project.license}"
srcDir      = "src"

# Dependencies
requires "nim >= 2.0.0"
"""

    writeFile(projectDir / project.name & ".nimble", nimbleContents)
    writeFile(projectDir / "src" / project.name & ".nim", "")
  except OSError as e:
    echo "Failed to create project files: ", e.msg
  except IOError as e:
    echo "Failed to create project files: ", e.msg

  if not noWrite:
    self.write()

proc init*(T: typedesc[ProjectManager]): T {.raises: [].} =
  let benchPath = benchDirPath()
  try:
    if not dirExists(benchPath):
      createDir(benchPath)
  except OSError, IOError:
    echo getCurrentExceptionMsg() 
  result = T()
