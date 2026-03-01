import std/[os]
import seaqt/[qplaintextedit]
import bench/highlight

type
  Buffer* = ref object
    name, path: string
    editor: QPlainTextEdit
    highlighter: NimHighlighter

  BufferManager* = object
    buffers: seq[Buffer]

const ScratchBufferName* = "scratch"

var scratchCount {.global.} = 0

proc init*(T: typedesc[BufferManager]): T =
  T(buffers: @[])

proc new*(T: typedesc[Buffer], path = ""): T =
  let n =
    if path.len > 0: path
    else:
      inc scratchCount
      "scratch-" & $scratchCount
  var editor = QPlainTextEdit.create()
  editor.owned = false  # Qt manages lifetime when added to a pane
  let hl = NimHighlighter()
  hl.attach(editor.document())
  T(name: n, path: path, editor: editor, highlighter: hl)

proc name*(b: Buffer): string = b.name
proc path*(b: Buffer): string = b.path
proc `path=`*(b: Buffer, p: string) = b.path = p
proc editor*(b: Buffer): lent QPlainTextEdit = b.editor

proc add*(bm: var BufferManager, buf: Buffer) =
  bm.buffers.add(buf)

iterator items*(bm: BufferManager): Buffer =
  for b in bm.buffers:
    yield b

proc len*(bm: BufferManager): int = bm.buffers.len

proc openFile*(bm: var BufferManager, path: string): Buffer =
  for buf in bm.buffers:
    if buf.path == path:
      return buf
  result = Buffer.new(path)
  try:
    result.editor.setPlainText(readFile(path))
  except:
    discard
  bm.add(result)

proc close*(bm: var BufferManager, name: string) =
  for i in 0..<bm.buffers.len:
    if bm.buffers[i].name == name:
      bm.buffers.delete(i)
      return
