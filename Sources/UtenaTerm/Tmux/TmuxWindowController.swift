import AppKit

final class TmuxWindowController: NSWindowController {
    private(set) var isReady = false
    private let controlSession = TmuxControlSession()
    private var panes: [String: TmuxPane] = [:]
    private var windowPanes: [String: [String]] = [:]   // windowID → DFS-ordered pane IDs
    private var tabItems: [String: NSTabViewItem] = [:]  // windowID → tab item
    private(set) var orderedWindowIDs: [String] = []
    private var pendingSelectAfterLayout: Set<String> = []
    private var focusedPane: TmuxPane?
    private var currentWindowID: String?
    private var lastRefreshedSize: (cols: Int, rows: Int) = (0, 0)
    private var tabView: NSTabView!
    private let layoutParser = TmuxLayoutParser()
    private var chrome: SessionChrome?
    private lazy var switcher: SwitcherController = {
        let s = SwitcherController()
        s.delegate = self
        return s
    }()

    convenience init() {
        let initialSize = NSSize(width: 880, height: 550)

        let tv = NSTabView(frame: NSRect(origin: .zero, size: initialSize))
        tv.tabViewType = .noTabsNoBorder

        let win = TerminalWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "tmux"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = Palette.surfaceBackground
        // Full-bleed: hide the standard window buttons. Close still works
        // via ⌘W / killing all panes; minimize via ⌘M; quit via ⌘Q.
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(kind)?.isHidden = true
        }
        let chrome = SessionChrome(contentView: tv)
        win.contentView = chrome
        win.center()

        self.init(window: win)

        tabView = tv
        self.chrome = chrome
        chrome.delegate = self
        win.splitDelegate = self
        controlSession.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: win
        )

        guard let tmuxPath = TmuxControlSession.findTmux() else {
            let alert = NSAlert()
            alert.messageText = "tmux not found"
            alert.informativeText = "Please install tmux to use this window type."
            alert.runModal()
            win.close()
            return
        }

        let daemonSessions = syncAwait { try await UtenaDaemonClient.shared.fetchOnce() } ?? []
        let pickerResult = SessionPickerController.run(sessions: daemonSessions)
        var attachTarget: String?

        switch pickerResult {
        case .cancel:
            win.close(); return
        case .attach(let session):
            guard let tmuxName = session.tmuxSession?.name else { win.close(); return }
            attachTarget = tmuxName
        case .create(let name, let workspaceId):
            guard let s = syncAwait({ try await UtenaDaemonClient.shared.createSession(name: name, workspaceId: workspaceId) }),
                  let tmuxName = s.tmuxSession?.name else { win.close(); return }
            attachTarget = tmuxName
        }

        do {
            try controlSession.start(tmuxPath: tmuxPath, attachingTo: attachTarget)
            isReady = true
        } catch {
            win.close()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func applyLayout(_ layoutString: String, forWindow windowID: String) {
        guard let node = try? layoutParser.parse(layoutString) else {
            DebugLog.log("tmux", "applyLayout PARSE-FAIL window=\(windowID) layout=\(layoutString)")
            return
        }
        let newPaneIDs = Set(node.leafIDs())
        let oldPaneIDs = Set(windowPanes[windowID] ?? [])
        DebugLog.log("tmux", "applyLayout window=\(windowID) panes=\(node.leafIDs()) hadTabItem=\(tabItems[windowID] != nil) currentWindow=\(currentWindowID ?? "nil") pendingSwitch=\(pendingSelectAfterLayout)")

        for id in oldPaneIDs.subtracting(newPaneIDs) {
            if focusedPane?.paneID == id { focusedPane = nil }
            panes.removeValue(forKey: id)
        }

        let rootView = buildViewHierarchy(from: node, windowID: windowID)
        rootView.autoresizingMask = [.width, .height]
        windowPanes[windowID] = node.leafIDs()

        let containerFrame: NSRect
        if let existing = tabItems[windowID] {
            // NSTabView caches the original item.view at add-time and won't
            // re-wire when we mutate .view in place — the tab stays blank.
            // Force a refresh by removing the placeholder and re-inserting
            // a fresh tab item with the real view set up front.
            let idx = tabView.indexOfTabViewItem(existing)
            let wasSelected = tabView.selectedTabViewItem === existing
            DebugLog.log("tmux", "applyLayout IF window=\(windowID) idx=\(idx) wasSelected=\(wasSelected) tabCount=\(tabView.numberOfTabViewItems)")
            if idx != NSNotFound { tabView.removeTabViewItem(existing) }
            let item = NSTabViewItem()
            item.label = windowID
            item.view = rootView
            tabItems[windowID] = item
            if idx != NSNotFound, idx <= tabView.numberOfTabViewItems {
                tabView.insertTabViewItem(item, at: idx)
            } else {
                tabView.addTabViewItem(item)
            }
            containerFrame = tabView.contentRect
            rootView.frame = containerFrame
            DebugLog.log("tmux", "applyLayout IF post-insert containerFrame=\(containerFrame) rootView=\(type(of: rootView)) tabCount=\(tabView.numberOfTabViewItems) selected=\(tabView.selectedTabViewItem?.label ?? "nil")")
            let shouldSwitch = wasSelected || pendingSelectAfterLayout.contains(windowID)
            if shouldSwitch {
                pendingSelectAfterLayout.remove(windowID)
                DebugLog.log("tmux", "applyLayout IF switching to window=\(windowID)")
                selectWindow(id: windowID)
            }
        } else {
            containerFrame = tabView.contentRect
            let item = NSTabViewItem()
            item.label = windowID
            item.view = rootView
            tabItems[windowID] = item
            tabView.addTabViewItem(item)
            appendWindowID(windowID)
            DebugLog.log("tmux", "applyLayout ELSE window=\(windowID) containerFrame=\(containerFrame) tabCount=\(tabView.numberOfTabViewItems)")
            if currentWindowID == nil {
                currentWindowID = windowID
                tabView.selectTabViewItem(item)
            } else {
                selectWindow(id: windowID)
            }
        }
        applySplitPositions(view: rootView, node: node, frame: containerFrame)

        if focusedPane == nil,
           let firstID = windowPanes[windowID]?.first,
           let pane = panes[firstID]
        {
            setFocus(pane)
            sendRefreshClient()
        }
    }

    private func buildViewHierarchy(from node: TmuxLayoutNode, windowID: String) -> NSView {
        switch node {
        case .leaf(let id, let cols, let rows):
            if panes[id] == nil {
                panes[id] = TmuxPane(
                    paneID: id,
                    cols: UInt16(cols),
                    rows: UInt16(rows),
                    controlSession: controlSession
                )
            }
            let pane = panes[id]!
            pane.resize(cols: UInt16(cols), rows: UInt16(rows))
            return pane.view

        case .hsplit(let children):
            let sv = NSSplitView()
            sv.isVertical = true
            sv.dividerStyle = .thin
            for child in children { sv.addArrangedSubview(buildViewHierarchy(from: child, windowID: windowID)) }
            return sv

        case .vsplit(let children):
            let sv = NSSplitView()
            sv.isVertical = false
            sv.dividerStyle = .thin
            for child in children { sv.addArrangedSubview(buildViewHierarchy(from: child, windowID: windowID)) }
            return sv
        }
    }

    // Sets NSSplitView divider positions to match tmux column/row proportions.
    private func applySplitPositions(view: NSView, node: TmuxLayoutNode, frame: NSRect) {
        guard let sv = view as? NSSplitView else { return }
        switch node {
        case .leaf: return
        case .hsplit(let children):
            let totalCols = children.reduce(0) { $0 + $1.cols }
            guard totalCols > 0 else { return }
            var pos: CGFloat = 0
            for (i, child) in children.dropLast().enumerated() {
                pos += frame.width * CGFloat(child.cols) / CGFloat(totalCols)
                sv.setPosition(pos, ofDividerAt: i)
                pos += sv.dividerThickness
            }
            for (i, child) in children.enumerated() {
                let childW = frame.width * CGFloat(child.cols) / CGFloat(totalCols)
                let childFrame = NSRect(x: 0, y: 0, width: childW, height: frame.height)
                applySplitPositions(view: sv.arrangedSubviews[i], node: child, frame: childFrame)
            }
        case .vsplit(let children):
            let totalRows = children.reduce(0) { $0 + $1.rows }
            guard totalRows > 0 else { return }
            var pos: CGFloat = 0
            for (i, child) in children.dropLast().enumerated() {
                pos += frame.height * CGFloat(child.rows) / CGFloat(totalRows)
                sv.setPosition(pos, ofDividerAt: i)
                pos += sv.dividerThickness
            }
            for (i, child) in children.enumerated() {
                let childH = frame.height * CGFloat(child.rows) / CGFloat(totalRows)
                let childFrame = NSRect(x: 0, y: 0, width: frame.width, height: childH)
                applySplitPositions(view: sv.arrangedSubviews[i], node: child, frame: childFrame)
            }
        }
    }

    private func appendWindowID(_ id: String) {
        if !orderedWindowIDs.contains(id) { orderedWindowIDs.append(id) }
    }

    private func tearDownAll() {
        for item in tabItems.values { tabView.removeTabViewItem(item) }
        tabItems.removeAll()
        panes.removeAll()
        windowPanes.removeAll()
        orderedWindowIDs.removeAll()
        pendingSelectAfterLayout.removeAll()
        focusedPane = nil
        currentWindowID = nil
        lastRefreshedSize = (0, 0)
    }

    private func rebuildFromSession() async {
        guard let output = try? await controlSession.listWindows() else { return }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            applyLayout(String(parts[1]), forWindow: String(parts[0]))
        }
        sendRefreshClient()
        chrome?.windowsDidChange()
    }

    private func setFocus(_ pane: TmuxPane) {
        focusedPane?.view.isActive = false
        focusedPane = pane
        pane.view.isActive = true
        window?.makeFirstResponder(pane.view)
    }

    private func sendRefreshClient() {
        guard let pane = focusedPane ?? panes.values.first else { return }
        let rect = tabView.contentRect
        let cols = max(1, Int(rect.width / pane.view.cellWidth))
        let rows = max(1, Int(rect.height / pane.view.cellHeight))
        guard cols != lastRefreshedSize.cols || rows != lastRefreshedSize.rows else { return }
        lastRefreshedSize = (cols, rows)
        controlSession.refreshClient(cols: cols, rows: rows)
    }

    @objc private func windowDidResize(_ notification: Notification) {
        sendRefreshClient()
    }
}

// MARK: - TmuxControlSessionDelegate

extension TmuxWindowController: TmuxControlSessionDelegate {
    func session(_ session: TmuxControlSession, didReceiveOutput data: Data, forPane paneID: String) {
        panes[paneID]?.receive(data)
    }

    func session(_ session: TmuxControlSession, didLayoutChange layout: String, forWindow windowID: String) {
        DebugLog.log("tmux", "didLayoutChange window=\(windowID) orderedWindows=\(orderedWindowIDs)")
        applyLayout(layout, forWindow: windowID)
    }

    func session(_ session: TmuxControlSession, didAddWindow windowID: String) {
        DebugLog.log("tmux", "didAddWindow window=\(windowID) currentWindow=\(currentWindowID ?? "nil") alreadyHasTab=\(tabItems[windowID] != nil)")
        guard tabItems[windowID] == nil else { return }
        let item = NSTabViewItem()
        item.label = windowID
        tabItems[windowID] = item
        tabView.addTabViewItem(item)
        appendWindowID(windowID)
        chrome?.windowsDidChange()
        guard currentWindowID != nil else { return }
        // Past initial attach: user-initiated new-window. In a grouped tmux
        // session %layout-change may never arrive for the new window, so we
        // proactively fetch its layout instead of waiting for the event.
        DebugLog.log("tmux", "didAddWindow fetching layout for new window=\(windowID)")
        Task { @MainActor [weak self] in
            guard let self,
                  let output = try? await self.controlSession.listWindows() else { return }
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, String(parts[0]) == windowID else { continue }
                DebugLog.log("tmux", "didAddWindow applying fetched layout for window=\(windowID)")
                self.applyLayout(String(parts[1]), forWindow: windowID)
                // Also switch to it — %session-window-changed fired before %window-add,
                // so didSelectWindow already skipped it. Do it explicitly here.
                self.selectWindow(id: windowID)
                break
            }
        }
    }

    func session(_ session: TmuxControlSession, didCloseWindow windowID: String) {
        if let item = tabItems.removeValue(forKey: windowID) {
            tabView.removeTabViewItem(item)
        }
        orderedWindowIDs.removeAll { $0 == windowID }
        pendingSelectAfterLayout.remove(windowID)
        let removedIDs = windowPanes.removeValue(forKey: windowID) ?? []
        for id in removedIDs {
            if focusedPane?.paneID == id { focusedPane = nil }
            panes.removeValue(forKey: id)
        }
        if currentWindowID == windowID {
            currentWindowID = tabView.selectedTabViewItem.flatMap { selected in
                tabItems.first { $0.value === selected }?.key
            }
            // The killed window contained the focused pane; hand focus to
            // the first pane of the now-selected window so the user lands
            // somewhere typable instead of nowhere.
            if let newID = currentWindowID,
               let firstPaneID = windowPanes[newID]?.first,
               let pane = panes[firstPaneID]
            {
                setFocus(pane)
            }
        }
        if tabView.numberOfTabViewItems == 0 { window?.close() }
        chrome?.windowsDidChange()
    }

    func session(_ session: TmuxControlSession, didChangeTo sessionID: String, name: String) {
        tearDownAll()
        window?.title = name
        chrome?.sessionDidChange(to: name)
        Task { await self.rebuildFromSession() }
    }

    func session(_ session: TmuxControlSession, didSelectWindow windowID: String) {
        // tmux changed the active window (e.g. after `new-window` selects
        // its newly-created window). Mirror that into our NSTabView so
        // the right content shows.
        DebugLog.log("tmux", "didSelectWindow window=\(windowID) currentWindow=\(currentWindowID ?? "nil") hasTab=\(tabItems[windowID] != nil)")
        guard windowID != currentWindowID, tabItems[windowID] != nil else {
            DebugLog.log("tmux", "didSelectWindow SKIPPED (same window or no tab yet)")
            return
        }
        selectWindow(id: windowID)
    }

    func session(_ session: TmuxControlSession, paneDidExit paneID: String) {
        // %layout-change follows and handles the removal.
    }

    func sessionDidClose(_ session: TmuxControlSession) {
        window?.close()
    }
}

// MARK: - TerminalWindowDelegate

extension TmuxWindowController: TerminalWindowDelegate {
    func terminalWindowSplitVertical() {
        guard let pane = focusedPane else { return }
        Task { try? await controlSession.splitPane(target: pane.paneID, vertical: false) }
    }

    func terminalWindowSplitHorizontal() {
        guard let pane = focusedPane else { return }
        Task { try? await controlSession.splitPane(target: pane.paneID, vertical: true) }
    }

    func terminalWindowFocusNext() {
        guard let id = currentWindowID,
              let order = windowPanes[id],
              let current = focusedPane,
              let idx = order.firstIndex(of: current.paneID),
              let pane = panes[order[(idx + 1) % order.count]]
        else { return }
        setFocus(pane)
    }

    func terminalWindowFocusPrev() {
        guard let id = currentWindowID,
              let order = windowPanes[id],
              let current = focusedPane,
              let idx = order.firstIndex(of: current.paneID),
              let pane = panes[order[(idx + order.count - 1) % order.count]]
        else { return }
        setFocus(pane)
    }

    func terminalWindowClosePane() {
        guard let pane = focusedPane else { return }
        controlSession.killPane(target: pane.paneID)
    }

    func terminalWindowToggleSwitcher() {
        if switcher.isOpen { switcher.close() }
        else { switcher.open(near: window) }
    }

    func terminalWindowNewWindow() {
        controlSession.newWindow()
    }

    func terminalWindowSelectWindow(index: Int) {
        // 1-indexed in the UI, 0-indexed in orderedWindowIDs.
        guard index >= 1, index <= orderedWindowIDs.count else { return }
        selectWindow(id: orderedWindowIDs[index - 1])
    }

    func terminalWindowNextWindow() { cycleWindow(by: +1) }
    func terminalWindowPrevWindow() { cycleWindow(by: -1) }

    func terminalWindowKillTmuxWindow() {
        guard let id = currentWindowID else { return }
        controlSession.killWindow(target: id)
    }

    private func cycleWindow(by delta: Int) {
        guard let current = currentWindowID,
              let idx = orderedWindowIDs.firstIndex(of: current),
              !orderedWindowIDs.isEmpty
        else { return }
        let n = orderedWindowIDs.count
        selectWindow(id: orderedWindowIDs[(idx + delta + n) % n])
    }
}

// MARK: - SwitcherDelegate

extension TmuxWindowController: SwitcherDelegate {
    var currentSessionName: String { window?.title ?? "" }

    func switcherAttach(tmuxName: String) {
        controlSession.switchSession(name: tmuxName)
    }
}

// MARK: - SessionChromeDelegate

extension TmuxWindowController: SessionChromeDelegate {
    var sessionName: String { window?.title ?? "" }
    var activeWindowID: String? { currentWindowID }
    func selectWindow(id: String) {
        guard let item = tabItems[id] else {
            DebugLog.log("tmux", "selectWindow BAIL no tabItem for window=\(id)")
            return
        }
        DebugLog.log("tmux", "selectWindow window=\(id) itemHasView=\(item.view != nil) panes=\(windowPanes[id] ?? [])")
        tabView.selectTabViewItem(item)
        currentWindowID = id
        if let firstPaneID = windowPanes[id]?.first, let pane = panes[firstPaneID] {
            setFocus(pane)
        } else {
            DebugLog.log("tmux", "selectWindow no pane to focus for window=\(id) windowPanes=\(windowPanes[id] ?? [])")
        }
        chrome?.windowsDidChange()
    }
}

// Blocks the calling thread until an async throwing operation completes.
// Use only from synchronous main-thread init (mirrors NSAlert.runModal() behavior).
private func syncAwait<T>(_ work: @Sendable @escaping () async throws -> T) -> T? {
    var result: T?
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        result = try? await work()
        sem.signal()
    }
    sem.wait()
    return result
}
