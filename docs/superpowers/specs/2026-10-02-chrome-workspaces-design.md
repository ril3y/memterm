# Workspace chrome: dragging, stacking, parking, and one window

**Status:** draft for founder review. One decision outstanding (§6).

Five features from six founder messages on 2026-10-02, in one spec because
they touch the same three views and two of them would be built twice if
taken separately.

## What the founder asked for

1. Drag a tab onto a workspace chip and have the tab move to that workspace.
   Reported as "it doesn't work".
2. Drag a tab onto the empty stretch of the workspace bar and get the
   new-workspace prompt, then have the tab move into the workspace that
   prompt creates.
3. The quake drop-down must not be a second window. "There should ONLY be one
   memterm window ever visible, so if you select quake style it should be
   that window with all the current tabs and workspaces; if you unselect it
   it should be the opposite."
4. An Appearance option for vertically stacked workspaces. The tab strip
   stays horizontal along the top; only the workspaces move.
5. A parked workspace should leave the workspace bar, appear in a Parked
   section of the Shell menu, and clicking it there should ask whether to
   restore or close it.

## What already exists (and why this is smaller than it looks)

Found by reading, before any design:

- **`moveTab(_:toWorkspace:)`** (`Sources/memterm/Workspaces.swift`) already
  moves a tab between workspaces and is already wired to the chip context
  menu. It handles the two hard cases: a parked target is unparked first, and
  a target with journal rows but no live windows is restored through the
  standard pipeline first, because the scoped save that follows rewrites that
  workspace's rows from live windows and would otherwise erase its stored
  tabs. **Dragging must call this, not reimplement it.**
- **`newWorkspaceAction`** already shows the name prompt through
  `promptForText` and then calls `createWorkspace(named:)` and
  `switchToWorkspace`.
- **`probeChipFrames()`** on `WorkspaceBar` already reports each chip's id
  and frame, which is exactly the input a drop needs.
- **`TerminalWindowController.tabId`** is a stable UUID string, so a drag can
  carry a tab's identity on the pasteboard and the drop can resolve it.
- **FR-59** already forbids a visible window outside the active workspace,
  enforced in the smoke run. So "one visible window" is nearly true already;
  the exception is the deliberate second window from Move Tab to New Window.

What does **not** exist: any drag-and-drop at all. No registered drag types,
no dragging destination, no drag session anywhere in the app. The tab strip's
existing "drag" is a bespoke gesture that moves the tab view's own frame and
calls `reorderTab`, confined to the strip, with no probe coverage. That is
the whole reason (1) does nothing: there is no drop target to hit.

## 1-2. Dragging a tab to a workspace

**Done already:** `MemtermCore/WorkspaceBarDrop.swift` resolves a point
against the bar and returns `outside`, `workspace(id:)`, or `newWorkspace`.
Pure and axis-agnostic, 9 unit tests, committed as `e1cfa0f`. Rules: a chip
under the cursor wins; a gap between chips resolves to the nearest chip,
because a few points of gap is a near miss and offering a new workspace there
would be a surprise; bare bar beyond the chips, at either end, is the
new-workspace gesture.

**Still to build:**

- **Promote the strip gesture to a real drag when it leaves the strip.**
  `TabStripView.itemDragged` keeps its in-strip reorder. When the cursor
  leaves the strip's vertical bounds, end the frame-move, snap the tab view
  back to its slot, and begin an `NSDraggingSession` carrying a custom
  pasteboard type with the tab's `tabId`.
- **Make the workspace bar a dragging destination.** Register the custom
  type. `draggingUpdated` calls `WorkspaceBarDrop.target(at:)` and highlights
  the chip, or the bare bar for the new-workspace case, and returns `.move`
  or `[]` so the cursor tells the truth before the drop.
- **`performDragOperation`** resolves `tabId` to its controller and then:
  `workspace(id:)` calls `moveTab`; `newWorkspace` runs the existing name
  prompt and, on confirm, creates the workspace and calls `moveTab` into it.
  Cancelling the prompt must leave the tab where it was.
- **Ruling:** after a drop into a brand-new workspace, follow the tab and
  switch to it, matching what the plus button already does. After a drop onto
  an existing chip, stay put, because that gesture is organizing, not
  navigating.

**Testing.** The resolution rules are unit-tested already. The wiring needs a
probe leg that drives the real `performDragOperation` with a synthetic
dragging info, plus an assertion that the tab's `workspaceId` changed and the
journal agrees. The existing strip reorder should get its first probe
coverage at the same time, since this change touches it.

## 3. Vertical workspaces (Appearance)

A new config key under appearance, defaulting to the current horizontal bar.
When vertical, the workspace chips lay out in a sidebar; the tab strip is
untouched and stays horizontal along the top.

This is why the drop logic was written against an axis: the sidebar passes
`.vertical` and inherits dragging with no new rules. Six of the nine existing
unit tests already cover the vertical case, including AppKit's bottom-up
coordinates and a stack that grows downward.

Open sub-question, not blocking: which side the sidebar sits on, and whether
it is resizable. Recommend left, fixed width, matching the chip height
already used.

## 4. Park leaves the bar

Today a parked workspace stays in the bar as a dimmed chip with a Reopen item
in its context menu.

Changes:

- A parked workspace is not rendered in the bar at all, in either
  orientation.
- The Shell menu gains a **Parked** section listing every parked workspace by
  name.
- Choosing one asks what to do: **Restore** (unpark and switch to it, which
  is today's Reopen path) or **Close** (the existing delete-and-forget path,
  which already requires confirmation), plus Cancel.

**This also retires an older bug rather than fixing it.** The founder
previously reported that clicking a parked chip in the bar un-parks it, and
asked for un-park to move to a right-click. With parked workspaces off the
bar entirely there is no chip to mis-click, so that defect becomes
unreachable instead of needing a guard. The deferred follow-up can be closed
when this ships.

Care needed: `switchToWorkspace` already un-parks a parked target on its way
in, and `moveTab` un-parks a parked destination. Both stay correct and both
must keep working, since Restore and a drag onto a parked workspace rely on
them. Only the bar's rendering and the menu change.

## 5. One window, and the quake mode

**The decision.** The drop-down stops being its own window and becomes a
presentation mode of the single visible window. Enabling quake style, or
pressing the hotkey, takes the active workspace's existing host and restyles
it: panel geometry from `DropdownLayout`, floating level, not movable, slide
animation. Toggling off restores its previous frame and level. No second
host, no new shell. The tabs and the workspace bar are already inside it,
because it is the same window.

`WindowHost.Role` stops carrying `.dropdown` as a separate kind of host and
the panel becomes a boolean presentation state on the active host.
`Dropdown.makePanel()` is deleted.

**Two consequences that need the founder's word (§6).**

- `StateStore` persists `role` at schema v7, where `"dropdown"` marks a panel
  window with its own tabs. Existing users who have used quake have journaled
  panel windows. On first launch after this change those tabs must merge into
  the normal window for that workspace rather than resurrect a second window.
  That is a migration, and it is one-way.
- **Move Tab to New Window** is a shipped Shell-menu command with probe
  coverage that deliberately opens a second visible window, which contradicts
  "only one window ever visible" taken literally.

## 6. The one open decision

**Does "only one memterm window ever visible" mean Move Tab to New Window
should go?**

This spec assumes **no**: that the founder's sentence is about the quake and
normal duality, and that deleting a working, probe-covered command on an
inference would be the wrong call. Under that reading, quake becomes a mode
of whichever window is active, and a person who deliberately opens a second
window still gets one.

If the answer is yes, that is a larger change: window creation paths, the
menu command, its probe leg, and the smoke expectation that tolerates two
hosts with one visible all change with it.

## Suggested order

1. **Park off the bar, Parked menu** (§4). Self-contained, no dependency on
   anything else here, and it retires an older defect.
2. **Finish the drag** (§1-2). The rules are already landed and tested.
3. **Vertical workspaces** (§3). Inherits dragging for free once (2) is in.
4. **Quake single-window** (§5). Last, because it is the only one needing a
   migration and the only one with an open question.

Taking (3) before (2) would mean building drop support twice. Taking (4)
first would collide with the bar work in the same views.
