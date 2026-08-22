import std/[os, tables, oids, hashes]

import nest

type
  BufferID* = string
  Buffer* = object
    id*: BufferID
    path*: string
    name*: string
    editor*: EditorState
    savedText*: string

  BufferManager* = object
    buffers*: Table[BufferID, Buffer]
    nextScratch*: int

const InvalidBufferID* = BufferID""

proc genBufferID*(): BufferID =
  BufferID($hash(genOid()))

proc init*(T: typedesc[Buffer], id: BufferID, name = "Untitled 1",
    content = "", path = ""): T =
  T(id: id, path: path, name: name, editor: EditorState.new(content),
    savedText: content)

proc init*(T: typedesc[BufferManager]): T =
  T(buffers: initTable[BufferID, Buffer](), nextScratch: 1)

proc hasBuffer*(manager: BufferManager, id: BufferID): bool =
  id != InvalidBufferID and manager.buffers.hasKey(id)

proc scratchName(manager: BufferManager): string =
  "Untitled " & $manager.nextScratch

proc newScratchBuffer*(manager: var BufferManager): BufferID =
  result = genBufferID()
  manager.buffers[result] = Buffer.init(result, manager.scratchName)
  inc manager.nextScratch

proc openBuffer*(manager: var BufferManager, path: string): BufferID =
  let content = readFile(path)
  result = genBufferID()
  manager.buffers[result] = Buffer.init(result, extractFilename(path), content, path)

proc replaceWithScratch*(manager: var BufferManager, id: BufferID) =
  if not manager.hasBuffer(id):
    return
  let name = manager.scratchName
  manager.buffers[id].path = ""
  manager.buffers[id].name = name
  manager.buffers[id].editor = EditorState.new("")
  manager.buffers[id].savedText = ""
  inc manager.nextScratch

proc replaceWithFile*(manager: var BufferManager, id: BufferID, path: string) =
  if not manager.hasBuffer(id):
    return
  let content = readFile(path)
  manager.buffers[id].path = path
  manager.buffers[id].name = extractFilename(path)
  manager.buffers[id].editor = EditorState.new(content)
  manager.buffers[id].savedText = content

proc saveBufferAs*(manager: var BufferManager, id: BufferID, path: string) =
  if not manager.hasBuffer(id):
    return
  let content = manager.buffers[id].editor.text
  writeFile(path, content)
  manager.buffers[id].path = path
  manager.buffers[id].name = extractFilename(path)
  manager.buffers[id].savedText = content

proc saveBuffer*(manager: var BufferManager, id: BufferID): bool =
  if not manager.hasBuffer(id) or manager.buffers[id].path.len == 0:
    return false
  manager.saveBufferAs(id, manager.buffers[id].path)
  true

proc dirty*(buffer: Buffer): bool =
  buffer.editor.text != buffer.savedText
