import std/[options, os, dirs]

 # derive vcs from directory
type
  Project* = object
    path*: string
    name*, version*, author*: string
    description*, license*: string

  ProjectManager* = object
    projects: seq[Project]

proc createProject*(self: var ProjectManager, project: Project) =
  discard

proc init*(T: typedesc[ProjectManager]): T {.raises: [].} =
  let benchPath = getHomeDir() / ".local" / "bench"
  try:
    if not dirExists(benchPath):
      createDir(benchPath)
  except OSError, IOError:
    echo getCurrentExceptionMsg() 
  result = T()
