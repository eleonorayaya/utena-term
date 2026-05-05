# Session UI Design: Native Integration in utena-term

**Date:** 2026-05-04  
**Status:** Design / pre-implementation  
**Design reference:** `eqt-utena-planning/docs/design/session-ui/terminal-session-manager.html`

---

## Problem

Session management in utena today requires tmux as a UI host. The sidebar (`utena status`) is a Bubbletea TUI pane split from the left side of the tmux window; the session picker (`utena`) is launched via `tmux display-popup`. Both live outside utena-term and require the user to stay in the tmux mental model.

Goal: replace both with native AppKit UI inside utena-term, fed by the utena Go daemon's HTTP API and sending commands through the existing tmux control mode pipe.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    utena-term (Swift/AppKit)                 │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              TmuxWindowController                   │   │
│  │  (owns tabs/splits/panes — unchanged)               │   │
│  └───────┬─────────────────────────────────────────────┘   │
│          │ composes                        │ sends cmds     │
│  ┌───────▼──────────────┐    ┌────────────▼─────────────┐  │
│  │  SessionChrome (NEW) │    │   TmuxControlSession     │  │
│  │                      │    │   (existing)             │  │
│  │  • StatuslineDock    │    │   + switchSession()      │  │
│  │  • SwitcherOverlay   │    │   + newSession()  (new   │  │
│  └───────┬──────────────┘    │     convenience methods) │  │
│          │ reads             └──────────────────────────┘  │
│  ┌───────▼──────────────────────────────────────────────┐  │
│  │              UtenaDaemonClient (NEW)                 │  │
│  │  Polls localhost:3333 every ~500ms                   │  │
│  │  GET /sessions → [Session] published via AsyncStream │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
                  utena Go daemon (existing)
                  localhost:3333
                  Source of truth: session list, status,
                  Claude badges, attention state
```

### Two data flows, kept separate

**Read path:** `UtenaDaemonClient` polls `GET /sessions` from the utena daemon. Sessions carry: name, cwd, branch, status (`focused`/`running`/`attention`/`idle`), attention badge (kind + label + count), window list (name + pane count), Claude status badge. This is purely observational — no business logic in Swift.

**Write path:** All tmux mutations go through the existing `TmuxControlSession` control-mode pipe via two new convenience methods wrapping the existing `send()`:
- `switchSession(name:)` → `switch-client -t <name>`
- `createSession(name:cwd:)` → `POST /sessions` to daemon, poll until session appears in daemon response, then `switch-client`

---

## Metal vs AppKit Decision

The renderer already draws a clear line:

| Surface | Technology | Reason |
|---------|-----------|--------|
| Terminal pane text, cursor, Kitty images | **Metal** (`MetalTerminalView` + `TerminalRenderer`) | High-frequency, GPU-bound: millions of glyph quads per frame, triple-buffered, real-time |
| Split dividers | **AppKit** (`NSSplitView`) | Structural layout, infrequent changes |
| Window tabs (tmux windows) | **AppKit** (`NSTabView`) | Reactive to tmux layout events, not frame-rate bound |
| Window chrome | **AppKit** (`NSWindow`) | Native macOS |
| **StatuslineDock** (new) | **AppKit** | Thin, layout-driven, changes at most a few times per second — `NSView` + `CATextLayer` or direct `drawRect`. Metal buys nothing here. |
| **SwitcherOverlay** (new) | **AppKit** | Full-panel overlay with blur — `NSPanel` + `NSVisualEffectView` gives frosted glass from the design for free. Sparklines via `CAShapeLayer`. |

**Rule of thumb:** Metal owns the terminal canvas. AppKit owns everything that frames it.

---

## Component Designs

### UtenaDaemonClient

```swift
actor UtenaDaemonClient {
    let baseURL = URL(string: "http://localhost:3333")!
    private var task: Task<Void, Never>?

    // Callers observe this; updates pushed every ~500ms or on change.
    let sessions: AsyncStream<[Session]>
    private let continuation: AsyncStream<[Session]>.Continuation

    func start()   // begins polling loop
    func stop()    // cancels

    // Returns only after the new session appears in a subsequent poll.
    func createSession(name: String, cwd: String) async throws -> Session
}

struct Session: Codable, Identifiable {
    var id: UInt
    var name: String
    var cwd: String
    var branch: String?
    var status: SessionStatus       // focused | running | attention | idle
    var attention: AttentionBadge?  // kind (err/warn/info) + label + count
    var windows: [Window]
    var claudeStatus: ClaudeStatus? // existing badge from daemon
    var lastActive: Date
}
```

No SSE for now — polling is simpler and the daemon already has the data. Can switch to SSE in a future pass if latency becomes noticeable.

---

### SessionChrome

`SessionChrome` is an `NSView` that wraps the existing split/pane content and adds the statusline at the bottom. It is inserted between `TmuxWindowController`'s content view and the window.

```
┌────────────────────────────────────────────────┐
│  NSStackView (vertical, spacing: 0)            │
│  ┌──────────────────────────────────────────┐  │
│  │  contentView (NSSplitView / pane area)   │  │  flex: 1
│  └──────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────┐  │
│  │  WindowTabRow (22px)                     │  │  flex: none
│  └──────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────┐  │
│  │  Statusline (26px)                       │  │  flex: none
│  └──────────────────────────────────────────┘  │
└────────────────────────────────────────────────┘
```

`SessionChrome` subscribes to `UtenaDaemonClient.sessions` and passes relevant slices to each sub-view.

---

### StatuslineDock

Two fixed-height `NSView` subclasses drawn via `drawRect(_:)` using `NSAttributedString` for text and `NSBezierPath` for dots/indicators. CoreText for measurement. No Auto Layout inside the rows — manual frame-based layout for performance at the draw level.

**WindowTabRow (22px):** Numbered tabs for windows of the focused tmux session. Derived from `TmuxWindowController`'s current window list (not from the daemon — this is structural, not metadata). Keyboard-accessible via the existing prefix key handler.

**Statusline (26px):**
- Left: session name badge (accent-colored pill)
- Center: current surface breadcrumb (`window name › pane index`), then inline attention chips for sessions needing input (each numbered for future ⌥-jump)
- Right: git branch (from daemon), clock, hint `⌃b p switcher`

Color palette matches the HTML design: `oklch(0.20 … 310)` maps to approximately `NSColor(hue: 0.83, saturation: 0.08, brightness: 0.20)`. Exact values tuned at implementation.

---

### SwitcherOverlay

An `NSPanel` (non-activating, floating above the window) containing an `NSVisualEffectView` for the backdrop blur. Triggered by the ⌃b p keybinding intercepted in `TerminalWindow.keyDown(with:)` before forwarding to the terminal.

**Layout:** Two-column grid at 1080×720 (or proportional to window size).

```
┌─ header: search field ────────────────────────────────────┐
│ ❯ _                              prefix ⌃b · 2 need attn │
├────────────────────────────┬──────────────────────────────┤
│  ♥ needs you               │  session  utena              │
│  [orpheus] 4 tests failing │  ~/code/utena · main         │
│  [edge]    1 prompt waiting│  uptime 4h · pid 48211       │
│                            │                              │
│  ✦ active                  │  windows                     │
│  ▶ [utena]  focused        │  1 run ·2p  2 logs  3 db ...│
│  [sshmole]  build running  │                              │
│                            │  [pane schematic]            │
│  ◌ idle                    │                              │
│  [dotfiles]                │                              │
│  [scratch]                 │                              │
├────────────────────────────┴──────────────────────────────┤
│ move: j k  session: ↵ attach  c new  x kill  esc close   │
└───────────────────────────────────────────────────────────┘
```

**Session rows** (left column): status dot, session name, window count, attention badge. No sparklines in v1 — add in a follow-up pass once the data pipe is stable.

**Focused session detail** (right column): name, cwd, branch, unified window strip (numbered pills, no pinned/typed distinction), pane schematic (proportional layout diagram drawn with `NSBezierPath`).

**Search:** filters session list by name prefix, live as user types. `NSTextField` with custom delegate; no extra framework.

**Keyboard handling:** All navigation handled natively in the panel's `keyDown`. j/k = move focus, ↵ = attach, c = new session form, x = kill (confirm), esc = dismiss. No tmux key forwarding.

**Actions:**
- Attach: `TmuxControlSession.switchSession(name:)`
- New: sheet/inline form for session name + cwd → `UtenaDaemonClient.createSession()` → switch when ready
- Kill: `DELETE /sessions/{id}` to daemon

---

## Session Creation Flow

```
User presses 'c' in Switcher
  → show inline name+cwd input form
  → on confirm: POST /sessions {name, cwd} to daemon
  → daemon creates tmux session, returns {id, name}
  → UtenaDaemonClient polls until session appears
  → TmuxControlSession.switchSession(name:)
  → Switcher dismisses
```

The daemon owns session lifecycle. utena-term never calls `new-session` directly via control mode for user-initiated creates — it tells the daemon and follows its lead.

---

## Keybindings

All handled in `TerminalWindow.keyDown(with:)` via the existing prefix-key state machine. The prefix is ⌃b (already tracked).

| Binding | Action |
|---------|--------|
| ⌃b p | Open/close SwitcherOverlay |
| ⌃b 1–9 | Jump to window N in focused session (via WindowTabRow) |
| j / k (in Switcher) | Navigate session list |
| ↵ (in Switcher) | Attach to focused session |
| c (in Switcher) | New session |
| x (in Switcher) | Kill session |
| esc (in Switcher) | Dismiss |

---

## Phased Implementation

### Phase 1 — UtenaDaemonClient
- `Session`, `Window`, `AttentionBadge`, `ClaudeStatus` models (Codable)
- `UtenaDaemonClient` actor with 500ms polling loop
- `GET /sessions` response parsing
- Log sessions to console — no UI

**Verify:** Run daemon, launch utena-term, confirm session list appears in logs.

### Phase 2 — StatuslineDock
- `SessionChrome` `NSView` wrapping existing content + two bottom rows
- `WindowTabRow`: derives window list from `TmuxWindowController`, not daemon
- `Statusline`: session name, attention chips, branch, clock, switcher hint
- Wire to `UtenaDaemonClient` stream

**Verify:** Statusline visible at bottom of tmux window; switches session name when `switch-client` fires in tmux; attention chips appear when daemon reports attention sessions.

### Phase 3 — SwitcherOverlay
- `NSPanel` + `NSVisualEffectView` + two-column layout
- Session row view, section labels, search field
- Focused session detail + pane schematic
- ⌃b p keybinding to open/close
- j/k/↵/esc keyboard navigation
- Attach via `TmuxControlSession.switchSession(name:)`
- New session flow via daemon

**Verify:** ⌃b p opens overlay; j/k navigates; ↵ switches tmux session; 'c' creates new session and switches to it; esc dismisses cleanly.

### Phase 4 — Retirement
- Remove `status-pane.sh` from tmux plugin
- Remove `utena status` command / `StatusView` Bubbletea code
- Update tmux plugin to remove popup binding (was `prefix p`)
- Update README

---

## Files to Create / Modify

| File | Action |
|------|--------|
| `Sources/UtenaTerm/UtenaDaemonClient.swift` | Create |
| `Sources/UtenaTerm/Session.swift` | Create (models) |
| `Sources/UtenaTerm/SessionChrome.swift` | Create |
| `Sources/UtenaTerm/StatuslineDock.swift` | Create |
| `Sources/UtenaTerm/SwitcherOverlay.swift` | Create |
| `Sources/UtenaTerm/TmuxControlSession.swift` | Add `switchSession(name:)`, `newSession(name:cwd:)` |
| `Sources/UtenaTerm/TerminalWindow.swift` | Intercept ⌃b p prefix sequence |
| `Sources/UtenaTerm/TmuxWindowController.swift` | Compose with `SessionChrome` |
| `utena/main/internal/tui/statusview/` | Delete (Phase 4) |
| `utena/main/plugins/utena-tmux/scripts/status-pane.sh` | Delete (Phase 4) |
