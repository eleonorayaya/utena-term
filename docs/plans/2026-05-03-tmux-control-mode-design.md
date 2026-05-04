# tmux Control Mode — Design

**Date:** 2026-05-03
**Branch:** eqt/controle-mode-impl

## Goal

Make UtenaTerm a native macOS tmux frontend. A dedicated window type connects to tmux via control mode (`tmux -CC`), renders each pane through libghostty-vt, and maps tmux windows to native tabs. Layout changes are bidirectional: tmux events update the UI, and UtenaTerm split/close actions send commands to tmux.

Plain (non-tmux) windows are unaffected.

---

## Window Types

| Shortcut | Window type | Backend |
|---|---|---|
| ⌘N | `TerminalWindow` | PTY → `$SHELL` (existing) |
| ⌘⇧N | `TmuxWindow` | PTY → `tmux -CC` |

`TmuxWindow` is a new `NSWindowController` subclass. No auto-detection, no mid-session mode switching — the two paths are fully separate.

---

## New Components

### `TmuxControlSession`

Owns the single PTY to `tmux -CC new-session` (falls back to `attach-session -d` if a server already exists). Runs a background read thread (same pattern as `PtyManager.readLoop`).

Responsibilities:
- Parse the control protocol stream line-by-line via `ControlLineParser`
- Pair `%begin`/`%end` blocks with pending commands via a serial command queue
- Dispatch typed events to a delegate (`TmuxControlSessionDelegate`)
- Expose `send(_:)` for raw command strings and convenience methods:
  - `splitPane(target:vertical:)` → `split-window [-v] -t %N`
  - `killPane(target:)` → `kill-pane -t %N`
  - `selectPane(target:)` → `select-pane -t %N`
  - `sendKeys(pane:data:)` → `send-keys -t %N -l <text>`
  - `switchSession(name:)` → `switch-client -t $name`
  - `listSessions()` → `list-sessions -F ...`

### `ControlLineParser`

Stateless struct. Takes a line of text, returns a `ControlEvent`:

```swift
enum ControlEvent {
    case beginBlock(guard: String)
    case endBlock(guard: String, time: Int)
    case errorBlock(guard: String, time: Int)
    case output(paneID: String, data: Data)          // %output %N <b64>
    case layoutChange(windowID: String, layout: String) // %layout-change %W <str>
    case windowAdd(windowID: String)
    case windowClose(windowID: String)
    case sessionChanged(sessionID: String, windowID: String)
    case paneExited(paneID: String)
    case pasteBufferChanged
    case unknown(String)
}
```

`%output` data is base64-decoded here before being wrapped in the event.

### `TmuxLayoutParser`

Parses tmux's compact layout string (e.g. `a4f5,220x50,0,0{110x50,0,0,1,110x50,111,0,2}`) into a `TmuxLayoutNode` tree:

```swift
indirect enum TmuxLayoutNode {
    case leaf(id: String, cols: Int, rows: Int)
    case hsplit([TmuxLayoutNode])   // {} in tmux = vertical divider = horizontal split
    case vsplit([TmuxLayoutNode])   // [] in tmux = horizontal divider = vertical split
}
```

### `TmuxPane`

Replaces `TerminalPane` for tmux-backed panes. No `PtyManager`.

```swift
final class TmuxPane {
    let paneID: String
    let bridge: GhosttyBridge
    let view: TerminalView
    weak var controlSession: TmuxControlSession?

    func receive(_ data: Data)          // called on %output events
    func sendInput(_ data: Data)        // routes via controlSession.sendKeys
    func resize(cols: UInt16, rows: UInt16)
}
```

`GhosttyBridge` and `TerminalView` are reused unchanged.

### `TmuxWindowController`

Conforms to `TmuxControlSessionDelegate`. Owns:
- `TmuxControlSession`
- `[String: TmuxPane]` keyed by pane ID
- `NSTabView` with one tab per tmux window
- One `SplitManager` per tab

On `%layout-change`:
1. Parse layout string → `TmuxLayoutNode` tree
2. Diff against current pane ID set → create/destroy `TmuxPane` instances
3. Rebuild the `SplitManager` tree and NSView hierarchy for the affected tab

On `%window-add` / `%window-close`: add/remove `NSTabViewItem`.

On `%session-changed`: tear down all tabs and panes, query new session layout, rebuild from scratch.

---

## Data Flow

### Startup

```
TmuxWindowController.init
  → TmuxControlSession.start()
      → spawn: tmux -CC new-session (or attach-session -d)
      → read: %begin ... %end  (initial state)
      → events: %window-add, %layout-change for each window
  → delegate callbacks → build tabs + panes
```

### Pane output

```
tmux PTY read → ControlLineParser → .output(paneID, data)
  → TmuxWindowController.session(_:didReceiveOutput:forPane:)
      → TmuxPane.receive(data)
          → bridge.write(data)
          → view.needsDisplay = true
```

### User keypress

```
TerminalView.keyDown → TmuxPane.sendInput(data)
  → TmuxControlSession.sendKeys(pane: paneID, data: data)
      → write "send-keys -t %N -l <text>\n" to PTY
```

### User split (⌘D)

```
TmuxWindowController.splitFocusedPane()
  → TmuxControlSession.splitPane(target: focusedPaneID, vertical: false)
      → write "split-window -t %N\n" to PTY
      → await %end response
  → %layout-change fires → diff/rebuild
```

### User close pane (⌘W)

```
TmuxWindowController.closeFocusedPane()
  → TmuxControlSession.killPane(target: focusedPaneID)
  → %layout-change or %pane-exited fires → diff/rebuild
```

### Session switch

```
TmuxWindowController.switchSession(name:)
  → TmuxControlSession.switchSession(name: name)
  → %session-changed fires
      → destroy all current tabs/panes
      → query new session windows + layouts
      → rebuild
```

---

## Layout Diff Algorithm

On each `%layout-change` for a window:

1. Collect current pane IDs for that window from `SplitManager` leaves
2. Parse new layout → collect new pane IDs
3. **Removed** = current − new: call `TmuxPane.deinit`, remove from dict
4. **Added** = new − current: create `TmuxPane(paneID:cols:rows:)`, add to dict
5. Reconstruct `SplitNode` tree from `TmuxLayoutNode`, substituting `TmuxPane` instances by ID
6. Replace the `SplitManager` root and rebuild NSView hierarchy

Resize each `TmuxPane` to the dimensions in the layout node.

---

## Command Response Pairing

tmux guarantees `%begin`/`%end` blocks arrive in the order commands were sent. `TmuxControlSession` maintains a FIFO of `CheckedContinuation` values. Each `send(_:)` call that expects a response appends a continuation; the `%end` handler dequeues and resumes the front continuation. Fire-and-forget commands (e.g. `send-keys`) skip the queue.

---

## Error Handling

- `%error` block on a command: resume the continuation with a thrown `TmuxCommandError`
- PTY read EOF: post `ptyDidClose` notification → `TmuxWindowController` shows an error state and closes the window
- `tmux` not found on `$PATH`: `TmuxControlSession.start()` throws, `TmuxWindow` shows an alert

---

## Files to Create

| File | Purpose |
|---|---|
| `Sources/UtenaTerm/TmuxControlSession.swift` | PTY ownership, command send/receive |
| `Sources/UtenaTerm/ControlLineParser.swift` | Protocol line → `ControlEvent` |
| `Sources/UtenaTerm/TmuxLayoutParser.swift` | Layout string → `TmuxLayoutNode` |
| `Sources/UtenaTerm/TmuxPane.swift` | Pane backed by GhosttyBridge, no PTY |
| `Sources/UtenaTerm/TmuxWindowController.swift` | Delegate, tab/split orchestration |

## Files to Modify

| File | Change |
|---|---|
| `AppDelegate.swift` | Add ⌘⇧N action → open `TmuxWindow` |
| `TerminalWindow.swift` | Extract shared window setup if needed |
| `KeyMap.swift` | Add tmux window shortcut |

## Files Unchanged

`GhosttyBridge`, `TerminalView`, `TerminalPane`, `PtyManager`, `SplitManager`, `SplitTree` — plain window path is untouched.
