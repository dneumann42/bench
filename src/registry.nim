## Nide's command registry.
##
## A command is Nide's controller layer: a documented, addressable bridge
## function. Keybindings, toolbar items, the palette and Owl scripts all reach
## the editor the same way -- by invoking a command id -- so a script can drive
## anything a person can.
##
## Nothing maintains a list of commands. A Nim command carries the
## `nideCommand`/`nideAction` pragma and registers itself when its module
## initialises; an Owl command uses `defcommand` and registers when its script
## loads. Both land in the registry below, which the query commands and the
## palette read.
##
## "Command" here means an editor command, in the Emacs sense: a named, listed,
## bindable unit of editor behaviour. Owl's own `command` is an unrelated
## TCL-style callable, and is merely how a Nide command happens to be
## implemented.
##
## A command's doc comment becomes its description, and the palette shows it
## verbatim. Write it as a description of what the command does -- imperative,
## one line -- not as commentary about the implementation.

import std/[algorithm, macros, strutils, tables]
import owl

type
  CommandOrigin* = enum
    NimOrigin = "nim"
    OwlOrigin = "owl"

  NideCommand* = object
    id*: string
    description*: string
    interactive*: bool ## offered to a person in the command palette
    tags*: seq[string] ## free-form labels a caller can filter on
    origin*: CommandOrigin
    value*: Value ## the Owl callable this id resolves to

var registry: OrderedTable[string, NideCommand]
var generation: int

proc commandGeneration*(): int {.raises: [].} =
  ## Bumped whenever the set of commands changes, so callers that cache a view
  ## of the registry can tell when to rebuild it.
  generation

proc registerCommand*(id, description: string, value: Value,
    interactive: bool, origin: CommandOrigin,
    tags: sink seq[string] = @[]) {.raises: [].} =
  ## Add or replace a command. Replacing matters for Owl: reloading a script
  ## re-runs its `defcommand`s, and the newest definition should win.
  registry[id] = NideCommand(id: id, description: description,
      interactive: interactive, tags: tags, origin: origin, value: value)
  inc generation

proc registerNativeCommand*(id, description: string, native: NativeCommand,
    interactive = false, tags: sink seq[string] = @[]) {.raises: [].} =
  registerCommand(id, description, nativeCommand(native), interactive,
      NimOrigin, tags)

proc hasCommand*(id: string): bool {.raises: [].} =
  id in registry

proc commandCount*(): int {.raises: [].} =
  registry.len

proc commandIds*(): seq[string] {.raises: [].} =
  for id in registry.keys:
    result.add id
  result.sort()

proc commandDescription*(id: string): string {.raises: [].} =
  registry.getOrDefault(id).description

proc commandTags*(id: string): seq[string] {.raises: [].} =
  registry.getOrDefault(id).tags

proc hasTag*(command: NideCommand, tag: string): bool {.raises: [].} =
  tag in command.tags

iterator commandsTagged*(tag: string): NideCommand =
  ## Every command carrying `tag`, ordered by id.
  for id in commandIds():
    let command = registry.getOrDefault(id)
    if command.hasTag(tag):
      yield command

proc commandValue*(id: string): Value {.raises: [EvaluatorError].} =
  if id notin registry:
    raise newException(EvaluatorError, "unknown command: " & id)
  registry.getOrDefault(id).value

iterator commands*(): NideCommand =
  for id in commandIds():
    yield registry.getOrDefault(id)

proc defineRegisteredCommands*(module: var NativeModule) {.raises: [].} =
  ## Bind every registered command into the module under its own id, so Owl can
  ## call it directly as well as through `run-command`.
  for command in commands():
    module.define(command.id, command.value)

# ---------------------------------------------------------------------------
# Invocation
# ---------------------------------------------------------------------------

proc invoke*(env: Environment, id: string,
    arguments: openArray[Value] = []): Value {.raises: [EvaluatorError].} =
  ## Run a command by id with already-evaluated arguments.
  ##
  ## Only the registry is consulted. An Owl `fun` or `command` is a private
  ## callable, not a Nide command, and is deliberately not reachable here --
  ## anything meant to be invoked by name declares itself with `defcommand`.
  ##
  ## Owl commands take unevaluated syntax, so each argument is bound to a
  ## private symbol in a scratch child scope and passed as a reference to it --
  ## the callee evaluates the symbol and gets the value back.
  let command = commandValue(id)
  if command.kind != Command:
    raise newException(EvaluatorError, "not a command: " & id)
  let scope = env.child()
  var nodes: seq[SyntaxNode]
  for index, argument in arguments:
    let name = "__nide-argument-" & $index
    scope.define(name, argument)
    nodes.add symbol(name)
  scope.call(command.command, nodes)

# ---------------------------------------------------------------------------
# Registering Nim commands
# ---------------------------------------------------------------------------

proc commandDoc(node: NimNode, id: string): string {.compileTime.} =
  let body = node.body
  if body.kind == nnkStmtList and body.len > 0 and body[0].kind == nnkCommentStmt:
    result = body[0].strVal.strip()
  if result.len == 0:
    error("command '" & id & "' has no doc comment; every command must " &
        "document itself", node)

proc registrationFor(id: string, node: NimNode,
    interactive: bool): NimNode {.compileTime.} =
  node.expectKind nnkProcDef
  let
    description = newLit(commandDoc(node, id))
    idLiteral = newLit(id)
    procName = node[0]
    interactiveLiteral = newLit(interactive)
  newStmtList(
    node,
    quote do:
      registerNativeCommand(`idLiteral`, `description`, `procName`,
          interactive = `interactiveLiteral`),
  )

macro nideCommand*(id: static[string], node: untyped): untyped =
  ## Register a native proc as a command scripts can call by id. Use for the
  ## machinery a person would never pick out of a list -- accessors, and the
  ## primitives Owl builds on.
  registrationFor(id, node, interactive = false)

macro nideAction*(id: static[string], node: untyped): untyped =
  ## Register a native proc as a command, and offer it in the command palette.
  ## Use for anything a person would reach for by name.
  registrationFor(id, node, interactive = true)

# ---------------------------------------------------------------------------
# The commands that define and query commands
# ---------------------------------------------------------------------------

proc requireSymbol(node: SyntaxNode,
    role: string): string {.raises: [EvaluatorError].} =
  case node.kind
  of Symbol:
    node.symbol
  of Command:
    if node.callee.kind == Symbol and node.arguments.len == 0 and
        node.layout == NoLayout and node.body.len == 0:
      node.callee.symbol
    else:
      raise newException(EvaluatorError, "expected " & role & " to be a symbol")
  else:
    raise newException(EvaluatorError, "expected " & role & " to be a symbol")

proc requireText(env: Environment, node: SyntaxNode,
    role: string): string {.raises: [EvaluatorError].} =
  let value = env.eval(node)
  if value.kind != Text:
    raise newException(EvaluatorError, "expected " & role & " to be text")
  value.text

proc commandEntry(command: NideCommand): Value {.raises: [].} =
  var entries = initTable[string, Value]()
  entries["id"] = text(command.id)
  entries["description"] = text(command.description)
  entries["interactive"] = boolean(command.interactive)
  entries["origin"] = text($command.origin)
  var tags: seq[Value]
  for tag in command.tags:
    tags.add text(tag)
  entries["tags"] = list(tags)
  dictionary(entries)

proc defcommandCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    body: seq[SyntaxNode],
): Value {.nideCommand: "defcommand", raises: [EvaluatorError].} =
  ## Define a command in Owl, from a name, optional parameters, and a body
  ## whose first statement is the description string. A command that takes no
  ## parameters is offered in the command palette.
  discard layout
  if arguments.len == 0:
    raise newException(EvaluatorError, "defcommand expects a command name")
  let id = requireSymbol(arguments[0], "command name")
  var parameters: seq[string]
  for argument in arguments[1 .. ^1]:
    parameters.add requireSymbol(argument, "parameter")
  if body.len == 0 or body[0].kind != String or body[0].stringValue.len == 0:
    raise newException(EvaluatorError, "command '" & id &
        "' has no description; every command must document itself")
  # After the description a command may declare tags, which are metadata
  # rather than something to run: `tags "mode" "nim"`.
  var
    bodyStart = 1
    tags: seq[string]
  if body.len > bodyStart and body[bodyStart].kind == Command and
      body[bodyStart].callee.kind == Symbol and
      body[bodyStart].callee.symbol == "tags" and
      body[bodyStart].layout == NoLayout:
    for argument in body[bodyStart].arguments:
      if argument.kind != String:
        raise newException(EvaluatorError, "command '" & id &
            "': tags must be string literals")
      tags.add argument.stringValue
    inc bodyStart
  let command = closureCommand(parameters, body[bodyStart .. ^1], env,
      evaluatesArguments = true, acceptsBlock = false)
  env.define(id, command)
  # The palette invokes with no arguments, so only a command that needs none
  # can be offered there.
  registerCommand(id, body[0].stringValue, command,
      interactive = parameters.len == 0, OwlOrigin, tags)
  command

proc runCommandCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    body: seq[SyntaxNode],
): Value {.nideCommand: "run-command", raises: [EvaluatorError].} =
  ## Invoke a command by id, passing along any remaining arguments.
  discard layout
  discard body
  if arguments.len == 0:
    raise newException(EvaluatorError, "run-command expects a command id")
  let id = env.requireText(arguments[0], "command id")
  var values: seq[Value]
  for argument in arguments[1 .. ^1]:
    values.add env.eval(argument)
  env.invoke(id, values)

proc commandExistsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    body: seq[SyntaxNode],
): Value {.nideCommand: "command-exists?", raises: [EvaluatorError].} =
  ## Report whether a command is registered under an id.
  discard layout
  discard body
  if arguments.len != 1:
    raise newException(EvaluatorError, "command-exists? expects one command id")
  boolean(hasCommand(env.requireText(arguments[0], "command id")))

proc describeCommandCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    body: seq[SyntaxNode],
): Value {.nideCommand: "describe-command", raises: [EvaluatorError].} =
  ## Return a command's description, or "" if no command has that id.
  discard layout
  discard body
  if arguments.len != 1:
    raise newException(EvaluatorError, "describe-command expects one command id")
  text(commandDescription(env.requireText(arguments[0], "command id")))

proc commandTagsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    body: seq[SyntaxNode],
): Value {.nideCommand: "command-tags", raises: [EvaluatorError].} =
  ## The tags a command was declared with, or an empty list.
  discard layout
  discard body
  if arguments.len != 1:
    raise newException(EvaluatorError, "command-tags expects one command id")
  var tags: seq[Value]
  for tag in commandTags(env.requireText(arguments[0], "command id")):
    tags.add text(tag)
  list(tags)

proc commandsTaggedCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    body: seq[SyntaxNode],
): Value {.nideCommand: "commands-tagged", raises: [EvaluatorError].} =
  ## Every command carrying a tag, as records of id, description, interactive,
  ## origin and tags.
  discard layout
  discard body
  if arguments.len != 1:
    raise newException(EvaluatorError, "commands-tagged expects one tag")
  var entries: seq[Value]
  for command in commandsTagged(env.requireText(arguments[0], "tag")):
    entries.add commandEntry(command)
  list(entries)

proc commandsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    body: seq[SyntaxNode],
): Value {.nideCommand: "commands", raises: [EvaluatorError].} =
  ## List every registered command as a record of id, description, interactive
  ## and origin, ordered by id.
  discard env
  discard layout
  discard body
  if arguments.len != 0:
    raise newException(EvaluatorError, "commands expects no arguments")
  var entries: seq[Value]
  for command in commands():
    entries.add commandEntry(command)
  list(entries)

proc interactiveCommandsCommand(
    env: Environment, arguments: seq[SyntaxNode], layout: LayoutKind,
    body: seq[SyntaxNode],
): Value {.nideCommand: "interactive-commands", raises: [EvaluatorError].} =
  ## List the commands offered in the command palette.
  discard env
  discard layout
  discard body
  if arguments.len != 0:
    raise newException(EvaluatorError, "interactive-commands expects no arguments")
  var entries: seq[Value]
  for command in commands():
    if command.interactive:
      entries.add commandEntry(command)
  list(entries)
