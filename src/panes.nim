import buffers
import std/[tables, oids, hashes]

type
  PaneOrientation* = enum
    Row
    Column
  PaneID* = string
  Pane* = object
    orientation*: PaneOrientation
    bufferID*: BufferID
    parent*: PaneID
    children*: seq[PaneID]

  PaneManagerSettings* = object
    focusNewPane*: bool
  PaneManager* = object
    settings*: PaneManagerSettings
    panes*: Table[PaneID, Pane]
    rootPane*: PaneID
    activePane*: PaneID

const InvalidPaneID* = PaneID""

proc genPaneID*(): PaneID =
  PaneID($hash(genOid()))

proc isRow*(pane: Pane): bool = pane.orientation == Row
proc isColumn*(pane: Pane): bool = pane.orientation == Column
proc isLeaf*(pane: Pane): bool = pane.children.len == 0

proc isRow*(paneManager: PaneManager, pane: PaneID): bool =
  paneManager.panes[pane].isRow()

proc isColumn*(paneManager: PaneManager, pane: PaneID): bool =
  paneManager.panes[pane].isColumn()

proc parentOf*(paneManager: PaneManager, child: PaneID): PaneID =
  if child == InvalidPaneID or child notin paneManager.panes:
    return InvalidPaneID
  paneManager.panes[child].parent

proc changeParent*(paneManager: var PaneManager, child: PaneID, newParent: PaneID) =
  paneManager.panes[child].parent = newParent

proc replaceChild(paneManager: var PaneManager, parent, oldChild, newChild: PaneID) =
  if parent == InvalidPaneID:
    paneManager.rootPane = newChild
    return
  for child in paneManager.panes[parent].children.mitems:
    if child == oldChild:
      child = newChild
      return

proc insertChildAfter(paneManager: var PaneManager, parent, afterChild,
    newChild: PaneID) =
  for index, child in paneManager.panes[parent].children:
    if child == afterChild:
      paneManager.panes[parent].children.insert(newChild, index + 1)
      return
  paneManager.panes[parent].children.add newChild

proc removeChild(paneManager: var PaneManager, parent, child: PaneID) =
  if parent == InvalidPaneID or parent notin paneManager.panes:
    return
  let index = paneManager.panes[parent].children.find(child)
  if index >= 0:
    paneManager.panes[parent].children.delete(index)

proc firstLeaf*(paneManager: PaneManager, paneID: PaneID): PaneID =
  if paneID == InvalidPaneID or paneID notin paneManager.panes:
    return InvalidPaneID
  let pane = paneManager.panes[paneID]
  if pane.isLeaf:
    return paneID
  for child in pane.children:
    result = paneManager.firstLeaf(child)
    if result != InvalidPaneID:
      return
  result = InvalidPaneID

proc collapseSingleChildContainer(paneManager: var PaneManager, paneID: PaneID) =
  if paneID == InvalidPaneID or paneID notin paneManager.panes:
    return
  if paneManager.panes[paneID].isLeaf:
    return
  if paneManager.panes[paneID].children.len != 1:
    return

  let
    onlyChild = paneManager.panes[paneID].children[0]
    parent = paneManager.panes[paneID].parent
  paneManager.replaceChild(parent, paneID, onlyChild)
  paneManager.changeParent(onlyChild, parent)
  paneManager.panes.del(paneID)

proc init*(T: typedesc[Pane], bufferID = InvalidBufferID): T =
  T(orientation: Row, bufferID: bufferID, parent: InvalidPaneID, children: @[])

proc init*(T: typedesc[PaneManager], rootBufferID: BufferID): T =
  let rootPane = genPaneID()
  result = T(
    settings: PaneManagerSettings(focusNewPane: true),
    panes: initTable[PaneID, Pane](),
    rootPane: rootPane,
    activePane: rootPane,
  )
  result.panes[rootPane] = Pane.init(rootBufferID)

proc activeBufferID*(paneManager: PaneManager): BufferID =
  if paneManager.activePane == InvalidPaneID or
      paneManager.activePane notin paneManager.panes:
    return InvalidBufferID
  paneManager.panes[paneManager.activePane].bufferID

proc focus*(paneManager: var PaneManager, paneID: PaneID) =
  if paneID in paneManager.panes and paneManager.panes[paneID].isLeaf:
    paneManager.activePane = paneID

proc addContainer*(paneManager: var PaneManager, orientation: PaneOrientation,
    bufferID: BufferID): PaneID =
  if paneManager.activePane == InvalidPaneID:
    result = genPaneID()
    paneManager.rootPane = result
    paneManager.activePane = result
    paneManager.panes[result] = Pane.init(bufferID)
    return

  let active = paneManager.activePane
  let parent = paneManager.parentOf(active)
  result = genPaneID()
  let newChild = Pane(
    orientation: Row,
    bufferID: bufferID,
    parent: InvalidPaneID,
    children: @[],
  )
  paneManager.panes[result] = newChild

  if parent != InvalidPaneID and paneManager.panes[parent].orientation == orientation:
    paneManager.changeParent(result, parent)
    paneManager.insertChildAfter(parent, active, result)
  else:
    let containerID = genPaneID()
    paneManager.panes[containerID] = Pane(
      orientation: orientation,
      bufferID: InvalidBufferID,
      parent: parent,
      children: @[active, result],
    )
    paneManager.replaceChild(parent, active, containerID)
    paneManager.changeParent(active, containerID)
    paneManager.changeParent(result, containerID)

  if paneManager.settings.focusNewPane:
    paneManager.activePane = result

proc addColumn*(paneManager: var PaneManager, bufferID: BufferID): PaneID =
  paneManager.addContainer(Column, bufferID)

proc addRow*(paneManager: var PaneManager, bufferID: BufferID): PaneID =
  paneManager.addContainer(Row, bufferID)

proc unsplitActive*(paneManager: var PaneManager): BufferID =
  if paneManager.activePane == InvalidPaneID or
      paneManager.activePane notin paneManager.panes:
    return InvalidBufferID
  if paneManager.activePane == paneManager.rootPane:
    return InvalidBufferID

  let
    active = paneManager.activePane
    parent = paneManager.parentOf(active)
  if parent == InvalidPaneID or parent notin paneManager.panes:
    return InvalidBufferID

  let activeIndex = paneManager.panes[parent].children.find(active)
  if activeIndex < 0:
    return InvalidBufferID

  result = paneManager.panes[active].bufferID
  paneManager.removeChild(parent, active)
  paneManager.panes.del(active)

  let children = paneManager.panes[parent].children
  if children.len == 0:
    paneManager.activePane = InvalidPaneID
    return

  let nextIndex = min(activeIndex, children.high)
  paneManager.activePane = paneManager.firstLeaf(children[nextIndex])
  paneManager.collapseSingleChildContainer(parent)
  if paneManager.activePane == InvalidPaneID:
    paneManager.activePane = paneManager.firstLeaf(paneManager.rootPane)
