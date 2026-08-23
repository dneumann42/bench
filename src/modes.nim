import std/[algorithm, os, strutils, tables]

import owl

type
  ModeRegistry* = object
    extensionModes*: Table[string, string]
    filenameModes*: Table[string, string]
    shebangModes*: seq[tuple[needle, mode: string]]
    mimeModes*: Table[string, string]

const
  BuiltinRulesSource* = staticRead"modes/builtin.rules.owl"
  BuiltinNimModeSource* = staticRead"modes/nim.owl"
  BuiltinOwlModeSource* = staticRead"modes/owl.owl"
  ModesDirName* = "modes"

proc init*(T: typedesc[ModeRegistry]): T =
  T(
    extensionModes: initTable[string, string](),
    filenameModes: initTable[string, string](),
    shebangModes: @[],
    mimeModes: initTable[string, string](),
  )

proc nideModesDir*(): string =
  getConfigDir() / "nide" / ModesDirName

proc normalizeExt(ext: string): string =
  result = ext.strip.toLowerAscii()
  if result.startsWith("."):
    result = result[1 .. ^1]

proc normalizeMode(mode: string): string =
  mode.strip.toLowerAscii()

proc defineRuleCommand(
    module: var NativeModule,
    name: string,
    callback: proc(registry: var ModeRegistry, mode, value: string) {.raises: [].},
    registry: ptr ModeRegistry,
) =
  module.defineNative(name, proc(
      env: Environment,
      arguments: seq[SyntaxNode],
      layout: LayoutKind,
      bodyNodes: seq[SyntaxNode],
  ): Value {.raises: [EvaluatorError].} =
    discard layout
    discard bodyNodes
    if arguments.len != 2:
      raise newException(EvaluatorError, name & " expects mode and value")
    let modeValue = env.eval(arguments[0])
    let itemValue = env.eval(arguments[1])
    if modeValue.kind != Text or itemValue.kind != Text:
      raise newException(EvaluatorError, name & " expects text")
    callback(registry[], modeValue.text, itemValue.text)
    boolean(true)
  )

proc registerModeRuleCommands(evaluator: var Evaluator, registry: ptr ModeRegistry) =
  var module = nativeModule"nide/modes"
  module.defineRuleCommand("extension", proc(registry: var ModeRegistry,
      mode, value: string) =
    let normalized = value.normalizeExt()
    if normalized.len > 0:
      registry.extensionModes[normalized] = mode.normalizeMode()
  , registry)
  module.defineRuleCommand("filename", proc(registry: var ModeRegistry,
      mode, value: string) =
    if value.len > 0:
      registry.filenameModes[value.toLowerAscii()] = mode.normalizeMode()
  , registry)
  module.defineRuleCommand("shebang", proc(registry: var ModeRegistry,
      mode, value: string) =
    if value.len > 0:
      registry.shebangModes.add((value.toLowerAscii(), mode.normalizeMode()))
  , registry)
  module.defineRuleCommand("mimetype", proc(registry: var ModeRegistry,
      mode, value: string) =
    if value.len > 0:
      registry.mimeModes[value.toLowerAscii()] = mode.normalizeMode()
  , registry)
  evaluator.registerModule(module)

proc loadRulesSource(registry: var ModeRegistry, source, path: string) =
  var evaluator = Evaluator.init()
  evaluator.registerModeRuleCommands(addr registry)
  discard evaluator.exec(parse(source, path))

proc loadModeRegistry*(): ModeRegistry =
  result = ModeRegistry.init()
  result.loadRulesSource(BuiltinRulesSource, "builtin.rules.owl")
  let dir = nideModesDir()
  if dirExists(dir):
    var paths: seq[string]
    for kind, path in walkDir(dir, relative = false):
      if kind == pcFile and path.endsWith(".rules.owl"):
        paths.add path
    paths.sort()
    for path in paths:
      result.loadRulesSource(readFile(path), path)

proc firstLine(text: string): string =
  let stop = text.find('\n')
  if stop < 0:
    text
  else:
    text[0 ..< stop]

proc guessMimeType(path: string): string =
  let ext = path.splitFile.ext.normalizeExt()
  if ext.len == 0:
    return ""
  for candidate in ["/etc/mime.types", "/usr/local/etc/mime.types"]:
    if not fileExists(candidate):
      continue
    try:
      for line in lines(candidate):
        let stripped = line.strip()
        if stripped.len == 0 or stripped.startsWith("#"):
          continue
        let fields = stripped.splitWhitespace()
        if fields.len < 2:
          continue
        for index in 1 ..< fields.len:
          if fields[index].normalizeExt() == ext:
            return fields[0].toLowerAscii()
    except CatchableError:
      discard
  ""

proc detectMode*(registry: ModeRegistry, path, content: string): string =
  let fileName = path.extractFilename.toLowerAscii()
  if fileName in registry.filenameModes:
    return registry.filenameModes[fileName]

  let ext = path.splitFile.ext.normalizeExt()
  if ext in registry.extensionModes:
    return registry.extensionModes[ext]

  let mimeType = path.guessMimeType()
  if mimeType in registry.mimeModes:
    return registry.mimeModes[mimeType]

  let line = content.firstLine().toLowerAscii()
  if line.startsWith("#!"):
    for rule in registry.shebangModes:
      if line.contains(rule.needle):
        return rule.mode
  ""

proc builtinModeSource*(mode: string): string =
  case mode.normalizeMode()
  of "nim":
    BuiltinNimModeSource
  of "owl":
    BuiltinOwlModeSource
  else:
    ""

proc modeScriptPath*(mode: string): string =
  nideModesDir() / (mode.normalizeMode() & ".owl")

proc modeSource*(mode: string): tuple[source, path: string] =
  let userPath = mode.modeScriptPath()
  if fileExists(userPath):
    return (readFile(userPath), userPath)
  let source = mode.builtinModeSource()
  if source.len > 0:
    return (source, "<builtin mode:" & mode.normalizeMode() & ">")
  ("", "")
