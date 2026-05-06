# Phase 3: StatuslineDock Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a native bottom chrome to `TmuxWindowController` — a 22 px `WindowTabRow` (numbered window tabs) and a 26 px `Statusline` (session name pill, attention chips, git branch, clock) — driven by the `UtenaDaemonClient` stream.

**Architecture:** `SessionChrome` (NSView) replaces the NSTabView as the window's `contentView`; it contains the NSTabView (now `.noTabsNoBorder`, filling the top area) and the two fixed-height rows below, laid out with Auto Layout. `TmuxWindowController` conforms to `SessionChromeDelegate` and pushes structural updates (window adds/removes/selection); `SessionChrome` subscribes to `UtenaDaemonClient.sessions` for live metadata (branch, attention). No test infrastructure exists — verification is manual build + run.

**Tech Stack:** AppKit, Auto Layout, `drawRect(_:)` + `NSAttributedString` for the custom rows, `UtenaDaemonClient.sessions` AsyncStream, `Timer` for the clock.

> **Phase 4 note (SwitcherOverlay):** `UtenaDaemonClient.sessions` is a single-consumer `AsyncStream` — values are competed for, not multicast. Only `SessionChrome` subscribes in Phase 3. Phase 4's `SwitcherOverlay` must fan-out instead of adding a second `for await` on the same stream (use a `[weak observer]` array, NotificationCenter broadcast, or refactor to a multicast channel).

---

## Context

### Current layout

`TmuxWindowController.convenience init()` creates an `NSTabView` with `.topTabsBezelBorder` and sets it as `win.contentView`. All window management goes through `tabItems: [String: NSTabViewItem]` and `currentWindowID: String?`.

### Target layout

```
win.contentView = SessionChrome (fills window via NSWindow's legacy resizing)
  ├── NSTabView (.noTabsNoBorder, fills top via Auto Layout)
  ├── WindowTabRow (22 px fixed height)
  └── Statusline (26 px fixed height)
```

**Why `.noTabsNoBorder`:** NSTabView's `contentRect` is the area inside the tab strip. With `.noTabsNoBorder`, `contentRect == bounds`, so `applyLayout` and `sendRefreshClient` (both of which read `tabView.contentRect`) see the full NSTabView frame, which is exactly what Auto Layout gives them. Switching back to any style with a built-in tab strip will silently break the cell-count math.

### Files to touch

| File | Action |
|------|--------|
| `Sources/UtenaTerm/AppDelegate.swift` | Start daemon polling on launch |
| `Sources/UtenaTerm/Tmux/TmuxWindowController.swift` | Add `orderedWindowIDs`, conform to `SessionChromeDelegate`, create + wire `SessionChrome` |
| `Sources/UtenaTerm/Chrome/SessionChrome.swift` | **Create** |
| `Sources/UtenaTerm/Chrome/WindowTabRow.swift` | **Create** |
| `Sources/UtenaTerm/Chrome/Statusline.swift` | **Create** |

---

## Task 1: Start daemon polling on app launch

### Files
- Modify: `Sources/UtenaTerm/AppDelegate.swift`

### Step 1: Add `Task { await UtenaDaemonClient.shared.start() }` to `applicationDidFinishLaunching`

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await UtenaDaemonClient.shared.start() }
    let controller = TerminalWindowController()
    controllers.append(controller)
    controller.showWindow(nil)
}
```

### Step 2: Build

```bash
swift build 2>&1 | head -20
```

Expected: clean.

### Step 3: Commit

```bash
git add Sources/UtenaTerm/AppDelegate.swift
git commit -m "feat(daemon): start polling on app launch"
```

---

## Task 2: Add `orderedWindowIDs` to `TmuxWindowController`

### Files
- Modify: `Sources/UtenaTerm/Tmux/TmuxWindowController.swift`

`tabItems` is a dict — unordered. `WindowTabRow` needs a stable ordered list of window IDs (determines the displayed number). Add `private(set) var orderedWindowIDs: [String] = []` and maintain it in the three places that mutate the window list. `private(set)` is required: the stored property getter must be at least internal to satisfy the `SessionChromeDelegate` protocol's `{ get }` requirement.

### Step 1: Add property

After `private var tabItems: [String: NSTabViewItem] = [:]`:

```swift
private(set) var orderedWindowIDs: [String] = []
```

### Step 2: Append in `session(_:didAddWindow:)`

In the `TmuxControlSessionDelegate` extension, inside `session(_:didAddWindow:)`, after `tabView.addTabViewItem(item)`:

```swift
if !orderedWindowIDs.contains(windowID) {
    orderedWindowIDs.append(windowID)
}
```

### Step 3: Remove in `session(_:didCloseWindow:)`

In `session(_:didCloseWindow:)`, after `tabView.removeTabViewItem(item)`:

```swift
orderedWindowIDs.removeAll { $0 == windowID }
```

### Step 4: Clear in `tearDownAll()`

In `tearDownAll()`, after existing cleanup:

```swift
orderedWindowIDs.removeAll()
```

### Step 5: Build

```bash
swift build 2>&1 | head -20
```

### Step 6: Commit

```bash
git add Sources/UtenaTerm/Tmux/TmuxWindowController.swift
git commit -m "feat(tmux): track ordered window IDs for tab row"
```

---

## Task 3: Create `WindowTabRow`

### Files
- Create: `Sources/UtenaTerm/Chrome/WindowTabRow.swift`

### Step 1: Create the Chrome directory

```bash
mkdir -p Sources/UtenaTerm/Chrome
```

### Step 2: Write the file

```swift
import AppKit

final class WindowTabRow: NSView {
    var windowIDs: [String] = [] { didSet { needsDisplay = true } }
    var activeID: String? { didSet { needsDisplay = true } }
    var onSelectWindow: ((String) -> Void)?

    private static let tabWidth: CGFloat = 32

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.10, alpha: 1).setFill()
        NSBezierPath(rect: bounds).fill()

        // Top separator
        NSColor(white: 0.20, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)).fill()

        for (i, id) in windowIDs.enumerated() {
            let active = id == activeID
            let tabRect = NSRect(x: CGFloat(i) * Self.tabWidth, y: 0,
                                 width: Self.tabWidth, height: bounds.height - 1)
            if active {
                NSColor(white: 0.18, alpha: 1).setFill()
                NSBezierPath(rect: tabRect).fill()
            }
            let label = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: active ? .semibold : .regular),
                .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            let sz = label.size()
            label.draw(at: NSPoint(x: tabRect.midX - sz.width / 2, y: tabRect.midY - sz.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let idx = Int(x / Self.tabWidth)
        guard idx >= 0, idx < windowIDs.count else { return }
        onSelectWindow?(windowIDs[idx])
    }
}
```

### Step 3: Build

```bash
swift build 2>&1 | head -20
```

### Step 4: Commit

```bash
git add Sources/UtenaTerm/Chrome/WindowTabRow.swift
git commit -m "feat(chrome): WindowTabRow — numbered tmux window tab strip"
```

---

## Task 4: Create `Statusline`

### Files
- Create: `Sources/UtenaTerm/Chrome/Statusline.swift`

### Step 1: Write the file

`clockFormatter` is a static so it's allocated once, not every redraw (the 1 Hz timer calls `needsDisplay = true` every second).

```swift
import AppKit

final class Statusline: NSView {
    var sessionName: String = "" { didSet { needsDisplay = true } }
    var branchName: String? { didSet { needsDisplay = true } }
    var attentionNames: [String] = [] { didSet { needsDisplay = true } }

    private var timer: Timer?

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Background matches the design's oklch(0.20 … 310) approximation
        NSColor(calibratedHue: 0.83, saturation: 0.08, brightness: 0.20, alpha: 1).setFill()
        NSBezierPath(rect: bounds).fill()

        // Top separator
        NSColor(white: 0.28, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)).fill()

        let hPad: CGFloat = 10
        var leftX = hPad
        var rightX = bounds.width - hPad

        // Right: branch · clock · hint (draw right-to-left so we can right-align)
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let rightItems: [String] = [
            branchName.map { " \($0)" },
            Self.clockFormatter.string(from: Date()),
            "⌃b p",
        ].compactMap { $0 }

        for item in rightItems.reversed() {
            let str = NSAttributedString(string: item, attributes: dimAttrs)
            let sz = str.size()
            rightX -= sz.width
            str.draw(at: NSPoint(x: rightX, y: bounds.midY - sz.height / 2))
            rightX -= 8
        }

        // Left: session name pill
        if !sessionName.isEmpty {
            let pillAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let label = NSAttributedString(string: sessionName, attributes: pillAttrs)
            let sz = label.size()
            let pillRect = NSRect(x: leftX, y: bounds.midY - 9, width: sz.width + 12, height: 18)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            NSColor(calibratedHue: 0.83, saturation: 0.35, brightness: 0.55, alpha: 1).setFill()
            pill.fill()
            label.draw(at: NSPoint(x: leftX + 6, y: pillRect.minY + (18 - sz.height) / 2))
            leftX += pillRect.width + 10
        }

        // Center: attention chips
        let chipAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 1, green: 0.6, blue: 0.2, alpha: 1),
        ]
        for name in attentionNames {
            let chip = NSAttributedString(string: "[\(name)]", attributes: chipAttrs)
            let sz = chip.size()
            chip.draw(at: NSPoint(x: leftX, y: bounds.midY - sz.height / 2))
            leftX += sz.width + 6
        }
    }
}
```

### Step 2: Build

```bash
swift build 2>&1 | head -20
```

### Step 3: Commit

```bash
git add Sources/UtenaTerm/Chrome/Statusline.swift
git commit -m "feat(chrome): Statusline — session pill, attention chips, branch, clock"
```

---

## Task 5: Create `SessionChrome`

### Files
- Create: `Sources/UtenaTerm/Chrome/SessionChrome.swift`

### Step 1: Write the file

```swift
import AppKit

protocol SessionChromeDelegate: AnyObject {
    var sessionName: String { get }
    var orderedWindowIDs: [String] { get }
    var activeWindowID: String? { get }
    func selectWindow(id: String)
}

final class SessionChrome: NSView {
    let windowTabRow = WindowTabRow()
    let statusline = Statusline()

    weak var delegate: SessionChromeDelegate?
    private var daemonTask: Task<Void, Never>?

    init(contentView: NSView) {
        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        windowTabRow.translatesAutoresizingMaskIntoConstraints = false
        statusline.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentView)
        addSubview(windowTabRow)
        addSubview(statusline)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: windowTabRow.topAnchor),

            windowTabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            windowTabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            windowTabRow.bottomAnchor.constraint(equalTo: statusline.topAnchor),
            windowTabRow.heightAnchor.constraint(equalToConstant: 22),

            statusline.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusline.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusline.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusline.heightAnchor.constraint(equalToConstant: 26),
        ])

        windowTabRow.onSelectWindow = { [weak self] id in
            self?.delegate?.selectWindow(id: id)
        }

        daemonTask = Task { @MainActor [weak self] in
            for await sessions in UtenaDaemonClient.shared.sessions {
                guard let self else { return }
                self.update(from: sessions)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { daemonTask?.cancel() }

    // Called by TmuxWindowController when windows are added, removed, or a different tab is selected.
    func windowsDidChange() {
        guard let d = delegate else { return }
        windowTabRow.windowIDs = d.orderedWindowIDs
        windowTabRow.activeID = d.activeWindowID
    }

    // Called by TmuxWindowController when the tmux session itself switches (switch-client fires).
    func sessionDidChange(to name: String) {
        statusline.sessionName = name
        windowsDidChange()
    }

    private func update(from sessions: [Session]) {
        let name = statusline.sessionName
        let current = sessions.first { $0.name == name || $0.tmuxSession?.name == name }
        statusline.branchName = current?.branchName
        statusline.attentionNames = sessions
            .filter { $0.needsAttention && $0.name != name && $0.tmuxSession?.name != name }
            .map { $0.name }
    }
}
```

### Step 2: Build

```bash
swift build 2>&1 | head -20
```

### Step 3: Commit

```bash
git add Sources/UtenaTerm/Chrome/SessionChrome.swift
git commit -m "feat(chrome): SessionChrome — wires daemon stream + delegate into layout"
```

---

## Task 6: Wire `SessionChrome` into `TmuxWindowController`

### Files
- Modify: `Sources/UtenaTerm/Tmux/TmuxWindowController.swift`

### Step 1: Add `chrome` property

After `private let layoutParser = TmuxLayoutParser()`:

```swift
private var chrome: SessionChrome?
```

### Step 2: In `convenience init()`, remove `autoresizingMask` and replace `win.contentView = tv` with chrome

Find:
```swift
let tv = NSTabView(frame: NSRect(origin: .zero, size: initialSize))
tv.tabViewType = .topTabsBezelBorder
tv.autoresizingMask = [.width, .height]
```

Replace with:
```swift
let tv = NSTabView(frame: NSRect(origin: .zero, size: initialSize))
tv.tabViewType = .noTabsNoBorder
```

Find:
```swift
win.contentView = tv
win.center()

self.init(window: win)

tabView = tv
win.splitDelegate = self
controlSession.delegate = self
```

Replace with:
```swift
let chrome = SessionChrome(contentView: tv)
win.contentView = chrome
win.center()

self.init(window: win)

tabView = tv
self.chrome = chrome
chrome.delegate = self
win.splitDelegate = self
controlSession.delegate = self
```

(`win.contentView = chrome` is all that's needed — NSWindow manages the contentView's frame directly, no Auto Layout constraints required at the window boundary.)

### Step 3: Add `SessionChromeDelegate` conformance

Add a new extension at the bottom of the file (before the `syncAwait` helper):

```swift
// MARK: - SessionChromeDelegate

extension TmuxWindowController: SessionChromeDelegate {
    var sessionName: String { window?.title ?? "" }
    var activeWindowID: String? { currentWindowID }
    func selectWindow(id: String) {
        guard let item = tabItems[id] else { return }
        tabView.selectTabViewItem(item)
        currentWindowID = id
        chrome?.windowsDidChange()
    }
}
```

(`orderedWindowIDs` is `private(set) var` on the main class — its getter is internal and automatically satisfies the protocol's `{ get }` requirement; no redeclaration needed in the extension.)

### Step 4: Notify chrome from delegate callbacks

In `session(_:didAddWindow:)`, at the end:
```swift
chrome?.windowsDidChange()
```

In `session(_:didCloseWindow:)`, at the end:
```swift
chrome?.windowsDidChange()
```

In `session(_:didChangeTo:name:)`, replace:
```swift
window?.title = name
```
with:
```swift
window?.title = name
chrome?.sessionDidChange(to: name)
```

In `applyLayout(_:forWindow:)`, inside the `else` branch where `currentWindowID` is first set (when a new tab item is created), after `tabView.selectTabViewItem(item)`:
```swift
chrome?.windowsDidChange()
```

### Step 5: Build

```bash
swift build 2>&1 | head -40
```

Expected: clean. Common errors:
- `'chrome' used before 'self.init'` — make sure `self.chrome = chrome` is after `self.init(window: win)`.
- `'orderedWindowIDs' is inaccessible` — verify the property is `private(set) var`, not `private var`.

### Step 6: Commit

```bash
git add Sources/UtenaTerm/Tmux/TmuxWindowController.swift
git commit -m "feat(tmux): integrate SessionChrome — statusline dock + window tab row"
```

---

## Task 7: Manual smoke test

### Step 1: Build release

```bash
swift build -c release 2>&1 | tail -5
```

### Step 2: Launch and verify (daemon running)

1. Open a tmux window (⌘⇧N)
2. Verify: a 22 px tab row appears at the bottom (numbered "1", "2"…)
3. Verify: a 26 px statusline below it with session name pill on the left
4. Open a second tmux window in the session: tab row gains "2"
5. Click "2" in the tab row: the tab switches
6. Verify branch name appears on the right (from daemon)
7. Verify clock ticks

### Step 3: Launch without daemon

1. Kill the daemon
2. Open a tmux window
3. Verify: chrome appears, branch is blank, attention chips absent — no crash

---

## Task 8: Simplify pass + PR

### Step 1: Run /simplify

### Step 2: Final build

```bash
swift build 2>&1 | tail -5
```

### Step 3: PR

Use `git-workflows:working-with-prs` with title `feat: StatuslineDock — window tab row + statusline (Phase 3)`.
