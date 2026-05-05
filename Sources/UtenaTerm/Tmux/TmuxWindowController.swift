import AppKit

final class TmuxWindowController: NSWindowController {
    private(set) var isReady = false
    private let controlSession = TmuxControlSession()
    private var panes: [String: TmuxPane] = [:]
    private var windowPanes: [String: [String]] = [:]   // windowID → DFS-ordered pane IDs
    private var tabItems: [String: NSTabViewItem] = [:]  // windowID → tab item
    private var focusedPane: TmuxPane?
    private var currentWindowID: String?
    private var lastRefreshedSize: (cols: Int, rows: Int) = (0, 0)
    private var tabView: NSTabView!
    private let layoutParser = TmuxLayoutParser()

    convenience init() {
        let initialSize = NSSize(width: 880, height: 550)

        let tv = NSTabView(frame: NSRect(origin: .zero, size: initialSize))
        tv.tabViewType = .topTabsBezelBorder
        tv.autoresizingMask = [.width, .height]

        let win = TerminalWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "tmux"
        win.contentView = tv
        win.center()

        self.init(window: win)

        tabView = tv
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

        // Fetch daemon sessions (synchronous via semaphore — stays on main thread like NSAlert did)
        var daemonSessions: [Session] = []
        let sem = DispatchSemaphore(value: 0)
        Task {
            daemonSessions = (try? await UtenaDaemonClient.shared.fetchOnce()) ?? []
            sem.signal()
        }
        sem.wait()

        let pickerResult = SessionPickerController.run(sessions: daemonSessions)
        var groupTarget: String?

        switch pickerResult {
        case .cancel:
            win.close(); return
        case .attach(let session):
            guard let tmuxName = session.tmuxSession?.name else { win.close(); return }
            groupTarget = tmuxName
        case .create(let name, let workspaceId):
            var created: Session?
            let createSem = DispatchSemaphore(value: 0)
            Task {
                created = try? await UtenaDaemonClient.shared.createSession(name: name, workspaceId: workspaceId)
                createSem.signal()
            }
            createSem.wait()
            guard let s = created, let tmuxName = s.tmuxSession?.name else { win.close(); return }
            groupTarget = tmuxName
        }

        do {
            try controlSession.start(tmuxPath: tmuxPath, groupingWith: groupTarget)
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
        guard let node = try? layoutParser.parse(layoutString) else { return }
        let newPaneIDs = Set(node.leafIDs())
        let oldPaneIDs = Set(windowPanes[windowID] ?? [])

        for id in oldPaneIDs.subtracting(newPaneIDs) {
            if focusedPane?.paneID == id { focusedPane = nil }
            panes.removeValue(forKey: id)
        }

        let rootView = buildViewHierarchy(from: node, windowID: windowID)
        rootView.autoresizingMask = [.width, .height]
        windowPanes[windowID] = node.leafIDs()

        let containerFrame: NSRect
        if let item = tabItems[windowID] {
            containerFrame = item.view?.bounds ?? tabView.contentRect
            rootView.frame = containerFrame
            item.view = rootView
        } else {
            containerFrame = tabView.contentRect
            let item = NSTabViewItem()
            item.label = windowID
            item.view = rootView
            tabItems[windowID] = item
            tabView.addTabViewItem(item)
            if currentWindowID == nil {
                currentWindowID = windowID
                tabView.selectTabViewItem(item)
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

    private func tearDownAll() {
        for item in tabItems.values { tabView.removeTabViewItem(item) }
        tabItems.removeAll()
        panes.removeAll()
        windowPanes.removeAll()
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
        applyLayout(layout, forWindow: windowID)
    }

    func session(_ session: TmuxControlSession, didAddWindow windowID: String) {
        guard tabItems[windowID] == nil else { return }
        let item = NSTabViewItem()
        item.label = windowID
        tabItems[windowID] = item
        tabView.addTabViewItem(item)
    }

    func session(_ session: TmuxControlSession, didCloseWindow windowID: String) {
        if let item = tabItems.removeValue(forKey: windowID) {
            tabView.removeTabViewItem(item)
        }
        let removedIDs = windowPanes.removeValue(forKey: windowID) ?? []
        for id in removedIDs {
            if focusedPane?.paneID == id { focusedPane = nil }
            panes.removeValue(forKey: id)
        }
        if currentWindowID == windowID {
            currentWindowID = tabView.selectedTabViewItem.flatMap { selected in
                tabItems.first { $0.value === selected }?.key
            }
        }
        if tabView.numberOfTabViewItems == 0 { window?.close() }
    }

    func session(_ session: TmuxControlSession, didChangeTo sessionID: String, name: String) {
        tearDownAll()
        window?.title = name
        Task { await self.rebuildFromSession() }
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
}
