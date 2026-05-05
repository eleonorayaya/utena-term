# Native UI Integration: utena-term → utena daemon

## Context

The utena app currently surfaces session management via two tmux-backed TUI components: a sidebar pane (`utena status`, a Bubbletea `StatusView`) and a session picker popup (`utena`, launched via `tmux display-popup`). Both live outside utena-term and require tmux as a UI host.

The goal is to replace both with native AppKit UI built directly into utena-term, fed by the existing utena Go daemon's HTTP API. The ambient surface is a **bottom statusline dock** (always visible, no occlusion); the on-demand surface is a **Switcher overlay** (⌃b s). When complete, the tmux plugin sidebar + Bubbletea TUI can be retired.

The design reference is:
`eqt-utena-planning/docs/design/session-ui/terminal-session-manager.html`

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  utena-term (Swift/AppKit)           │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │         TmuxWindowController                │   │
│  │  (manages windows, splits, panes today)     │   │
│  └───────────┬─────────────────────────────────┘   │
│              │ owns                  │ sends cmds   │
│  ┌───────────▼───────────┐  ┌───────▼────────────┐ │
│  │   SessionChrome (NEW) │  │  TmuxControlSession │ │
│  │  • StatuslineDock     │  │  (existing)         │ │
│  │  • SwitcherOverlay    │  │  switch-client,     │ │
│  └───────────┬───────────┘  │  new-session, etc.  │ │
│              │ reads        └────────────────────┘ │
│  ┌───────────▼─────────────────────────────────┐   │
│  │           UtenaDaemonClient (NEW)           │   │
│  │  HTTP polling → localhost:PORT              │   │
│  │  GET /sessions (status, badges, windows)    │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
                       │
                       ▼
           utena daemon (Go, existing)
           source of truth: session metadata,
           Claude status, attention badges
```

**Two data flows, kept separate:**
- **Read path:** `UtenaDaemonClient` polls the utena daemon (fixed default port) for session metadata — names, cwd, branch, status, window list, Claude/attention badges.
- **Write path:** All tmux commands (switch session, create session, kill session, select window) go through the existing `TmuxControlSession` control-mode pipe. utena-term owns keyboard navigation and translates user actions into tmux control-mode commands directly — no round-trip through the daemon for switching.

**Resolved decisions:**
- All windows treated as regular (no pinned/typed distinction)
- Attention state uses existing daemon badge fields as-is
- Daemon at fixed default `localhost:3333` (see `api/config.go`)
- `TmuxControlSession` already has a generic `send()` method — add `switchClient(session:)` and `newSession(name:)` convenience wrappers; no architectural changes needed
- New session flow: `POST /sessions` to daemon → poll until session appears in daemon response → `switch-client -t <session>` via control mode
- Switcher keybinding: ⌃b p (intercepted in utena-term key handler, not forwarded to tmux)

---

## High-Level Phases

### Phase 1 — Data pipe: UtenaDaemonClient

Stand up a Swift HTTP client that polls (or subscribes via SSE) the utena daemon.

- Fetches `GET /sessions` → models `Session` (name, cwd, branch, status, attention, windows, Claude badges)
- Publishes updates via Combine/async-stream into the rest of the UI
- No UI yet — just verifiable data flow (log to console)

**End state:** utena-term can read live session data from the daemon.

---

### Phase 2 — Ambient surface: StatuslineDock

Two thin rows pinned to the bottom of the window, reserving their own space (never occluding panes):

- **Window tab row** (22px): numbered tabs for the windows of the focused session. Keyboard-jumpable (prefix → 1–9).
- **Statusline row** (26px): session badge (left), breadcrumb (surface › pane), inline attention chips, branch + clock + switcher hint (right).

Implemented as an `NSView` composited below the existing `NSSplitView` / pane area inside `TmuxWindowController`.

**End state:** bottom dock visible with live data; replaces the need to glance at the tmux sidebar.

---

### Phase 3 — On-demand surface: SwitcherOverlay

A floating `NSPanel` (or layer-backed `NSView`) triggered by **⌃b p**, intercepted in utena-term's key handler (not forwarded to tmux):

- **Left column:** sectioned session list (needs you / active / idle), each row with status dot, name, window count, attention badge.
- **Right column:** focused session detail — metadata, window strip, pane schematic.
- **Header:** search field filtering the session list.
- **Footer:** keybind reference (j/k navigate, ↵ attach, c new, x kill, esc close).

On **attach**: sends `switch-client -t <session>` via `TmuxControlSession.send()`.  
On **new session**: `POST /sessions` to daemon → poll `UtenaDaemonClient` until session appears → `switch-client` to it.  
utena-term owns all keyboard handling — no tmux keybinding pass-through needed.

**End state:** full Switcher replaces `utena` popup and `utena status` sidebar.

---

### Phase 4 — Retirement

- Remove tmux plugin sidebar invocation (`status-pane.sh`, `utena status` command)
- Remove or archive the `utena status` / `StatusView` Bubbletea code
- Update docs / README

**End state:** tmux plugin is optional plumbing only; all session UI lives in utena-term.

