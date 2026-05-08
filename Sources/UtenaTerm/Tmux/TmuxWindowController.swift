import AppKit

// MARK: - TmuxLaunch

enum TmuxLaunch {
    case attach(tmuxName: String)
    case create(CreateSessionInput)
}

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
    private var windowNames: [String: String] = [:]  // windowID → name
    private lazy var switcher: SwitcherController = {
        let s = SwitcherController()
        s.delegate = self
        return s
    }()
    private lazy var workspaces: WorkspacesController = {
        let w = WorkspacesController()
        w.delegate = self
        return w
    }()
    private lazy var help: HelpController = HelpController()
    private lazy var pullRequests: PullRequestsController = PullRequestsController()
    private var newSessionPicker: NewSessionPanelController?

    convenience init?(launch: TmuxLaunch) {
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
            return nil
        }

        let attachTarget: String?
        switch launch {
        case .attach(let tmuxName):
            attachTarget = tmuxName
        case .create(let input):
            guard let s = syncAwait({ try await UtenaDaemonClient.shared.createSession(input) }),
                  let tmuxName = s.tmuxSession?.name else {
                win.close()
                return nil
            }
            attachTarget = tmuxName
        }

        do {
            try controlSession.start(tmuxPath: tmuxPath, attachingTo: attachTarget)
            isReady = true
        } catch {
            win.close()
            return nil
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

        for id in oldPaneIDs.subtracting(newPaneIDs) {
            if focusedPane?.paneID == id { focusedPane = nil }
            panes.removeValue(forKey: id)
        }

        windowPanes[windowID] = node.leafIDs()

        // Capture and remove the existing tab item BEFORE rebuilding the view
        // hierarchy. buildViewHierarchy reparents existing pane.views into a
        // new NSSplitView via addArrangedSubview; if those views are still
        // mounted inside NSTabView at that point, the subsequent
        // removeTabViewItem prints
        //   "WARNING: oldView is not a subview of NSTabView. Removing
        //    oldView from its superview anyways."
        // and leaves NSTabView with stale internal state — visible as
        // "first split shows no change, second split finally shows all panes."
        // Detaching the old tab first lets buildViewHierarchy reparent cleanly.
        let existing = tabItems[windowID]
        let existingIdx: Int? = existing.flatMap { e in
            let i = tabView.indexOfTabViewItem(e)
            return i == NSNotFound ? nil : i
        }
        let existingWasSelected = existing.map { tabView.selectedTabViewItem === $0 } ?? false
        if let existing {
            tabView.removeTabViewItem(existing)
            tabItems.removeValue(forKey: windowID)
        }

        let rootView = buildViewHierarchy(from: node, windowID: windowID)
        // Detach rootView from any prior parent before handing it to NSTabView.
        // For split layouts rootView is a freshly-built NSSplitView (no parent
        // — the noop case). For a single-leaf layout rootView IS pane.view,
        // which may still be a subview of the previous NSSplitView (e.g. when
        // closing one of two panes leaves a single survivor): without this
        // detach NSTabView's item.view points at a view that's parented
        // elsewhere and the content area renders blank.
        rootView.removeFromSuperview()
        // NSSplitView sets `translatesAutoresizingMaskIntoConstraints = false`
        // on every arranged subview when it adopts them and does NOT restore
        // it on removal. After a kill-pane reduces 2 → 1 we hand the survivor
        // (pane.view, formerly an arranged subview) to NSTabView, but with
        // the flag still false the autoresizingMask we set below is ignored,
        // NSTabView's autoresizing-based content sizing path can't grow the
        // view to fill the tab area, and the content renders blank. Restoring
        // the flag explicitly re-enables the autoresize contract NSTabView
        // expects. For freshly-built NSSplitView roots this is a no-op (the
        // flag is already true on a brand-new instance).
        rootView.translatesAutoresizingMaskIntoConstraints = true
        rootView.autoresizingMask = [.width, .height]

        let item = NSTabViewItem()
        item.label = windowID
        item.view = rootView
        tabItems[windowID] = item

        let containerFrame: NSRect
        if existing != nil {
            if let idx = existingIdx, idx <= tabView.numberOfTabViewItems {
                tabView.insertTabViewItem(item, at: idx)
            } else {
                tabView.addTabViewItem(item)
            }
            containerFrame = tabView.contentRect
            rootView.frame = containerFrame
            let shouldSwitch = existingWasSelected || pendingSelectAfterLayout.contains(windowID)
            if shouldSwitch {
                pendingSelectAfterLayout.remove(windowID)
                selectWindow(id: windowID)
            }
        } else {
            containerFrame = tabView.contentRect
            tabView.addTabViewItem(item)
            appendWindowID(windowID)
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
        // NSSplitView's `addArrangedSubview` is a no-op when the view is
        // already an arranged subview, so if `buildViewHierarchy` ever returns
        // duplicate views (e.g. two leaves resolving to the same pane.view via
        // a stale `panes[id]` cache, or a layout-string ID collision after a
        // split that recycled a pane number), `arrangedSubviews.count` will
        // be smaller than `children.count` and the unguarded `[i]` subscript
        // crashes with an `__NSSingleObjectArrayI` exception. Iterate by zip
        // so we apply what we can and log the discrepancy for diagnosis.
        switch node {
        case .leaf: return
        case .hsplit(let children):
            let totalCols = children.reduce(0) { $0 + $1.cols }
            guard totalCols > 0 else { return }
            let arranged = sv.arrangedSubviews
            if arranged.count != children.count {
                DebugLog.log("tmux", "applySplitPositions hsplit MISMATCH children=\(children.count) arranged=\(arranged.count) leafIDs=\(node.leafIDs())")
            }
            let pairCount = min(children.count, arranged.count)
            // N panes have N-1 dividers; the position loop is empty (and
            // would underflow `pairCount - 1`) when arrangedSubviews is
            // mismatched down to 0 or 1 entry, so guard explicitly.
            if pairCount > 1 {
                var pos: CGFloat = 0
                for i in 0 ..< pairCount - 1 {
                    let child = children[i]
                    pos += frame.width * CGFloat(child.cols) / CGFloat(totalCols)
                    sv.setPosition(pos, ofDividerAt: i)
                    pos += sv.dividerThickness
                }
            }
            for i in 0 ..< pairCount {
                let child = children[i]
                let childW = frame.width * CGFloat(child.cols) / CGFloat(totalCols)
                let childFrame = NSRect(x: 0, y: 0, width: childW, height: frame.height)
                applySplitPositions(view: arranged[i], node: child, frame: childFrame)
            }
        case .vsplit(let children):
            let totalRows = children.reduce(0) { $0 + $1.rows }
            guard totalRows > 0 else { return }
            let arranged = sv.arrangedSubviews
            if arranged.count != children.count {
                DebugLog.log("tmux", "applySplitPositions vsplit MISMATCH children=\(children.count) arranged=\(arranged.count) leafIDs=\(node.leafIDs())")
            }
            let pairCount = min(children.count, arranged.count)
            if pairCount > 1 {
                var pos: CGFloat = 0
                for i in 0 ..< pairCount - 1 {
                    let child = children[i]
                    pos += frame.height * CGFloat(child.rows) / CGFloat(totalRows)
                    sv.setPosition(pos, ofDividerAt: i)
                    pos += sv.dividerThickness
                }
            }
            for i in 0 ..< pairCount {
                let child = children[i]
                let childH = frame.height * CGFloat(child.rows) / CGFloat(totalRows)
                let childFrame = NSRect(x: 0, y: 0, width: frame.width, height: childH)
                applySplitPositions(view: arranged[i], node: child, frame: childFrame)
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
        windowNames.removeAll()
    }

    private func refreshWindowNames() {
        Task { @MainActor [weak self] in
            guard let self,
                  let output = try? await self.controlSession.listWindowsWithNames() else { return }
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let windowID = String(parts[0])
                let windowName = String(parts[1])
                self.windowNames[windowID] = windowName
            }
            self.chrome?.windowsDidChange()
        }
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
        // The pane reserves padX/padY around the cell grid; subtract it so
        // tmux's reported window size matches what's actually visible. Without
        // this we over-report by ~2 cols and apps inside think the terminal
        // is wider than the rendered grid → text wraps a row early.
        let rect = tabView.contentRect
        let usableW = max(0, rect.width - 2 * pane.view.padX)
        let usableH = max(0, rect.height - 2 * pane.view.padY)
        let cols = max(1, Int(usableW / pane.view.cellWidth))
        let rows = max(1, Int(usableH / pane.view.cellHeight))
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
            self.refreshWindowNames()
        }
    }

    func session(_ session: TmuxControlSession, didCloseWindow windowID: String) {
        DebugLog.log("tmux", "didCloseWindow window=\(windowID) orderedWindows=\(orderedWindowIDs)")
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
        windowNames.removeValue(forKey: windowID)
        chrome?.windowsDidChange()
        refreshWindowNames()
    }

    func session(_ session: TmuxControlSession, didRenameWindow windowID: String, to newName: String) {
        windowNames[windowID] = newName
        chrome?.windowsDidChange()
    }

    func session(_ session: TmuxControlSession, didChangeTo sessionID: String, name: String) {
        tearDownAll()
        window?.title = name
        chrome?.sessionDidChange(to: name)
        Task {
            await self.rebuildFromSession()
            self.refreshWindowNames()
        }
    }

    func session(_ session: TmuxControlSession, didSelectWindow windowID: String) {
        // tmux changed the active window (e.g. after `new-window` selects
        // its newly-created window). Mirror that into our NSTabView so
        // the right content shows.
        let previousWindowID = currentWindowID
        guard windowID != currentWindowID, tabItems[windowID] != nil else {
            return
        }
        selectWindow(id: windowID)

        // %window-close is unreliable in attach-session mode — tmux often only
        // sends %session-window-changed. Check if the previous window still
        // exists and synthesize the close event if it's gone.
        guard let prev = previousWindowID else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let output = try? await self.controlSession.listWindows() else { return }
            let existing = Set(output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 1)
                return parts.first.map(String.init)
            })
            DebugLog.log("tmux", "didSelectWindow post-query prev=\(prev) exists=\(!existing.contains(prev))")
            if !existing.contains(prev) {
                self.session(session, didCloseWindow: prev)
            }
        }
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

    func terminalWindowToggleWorkspaces() {
        if workspaces.isOpen { workspaces.close() }
        else { workspaces.open(near: window) }
    }

    func terminalWindowTogglePullRequests() {
        if pullRequests.isOpen { pullRequests.close(); return }

        // Find the current session's workspace
        Task { @MainActor in
            let sessions = await UtenaDaemonClient.shared.cachedSessions
            guard let session = sessions.first(where: { $0.name == self.window?.title || $0.tmuxSession?.name == self.window?.title }),
                  let ws = session.workspace
            else {
                NSSound.beep()
                return
            }

            self.pullRequests.open(near: self.window, workspaceId: ws.id, workspaceName: ws.name)
        }
    }

    func terminalWindowToggleHelp() {
        if help.isOpen { help.close() }
        else { help.open(near: window) }
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

    func terminalWindowToggleZoom() {
        guard let pane = focusedPane else { return }
        controlSession.toggleZoom(target: pane.paneID)
    }

    func terminalWindowRenameWindow() {
        guard let windowID = currentWindowID else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Window"
        alert.informativeText = "Enter a new name for this window:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = ""
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue
        guard !newName.isEmpty else { return }
        controlSession.renameWindow(target: windowID, name: newName)
        // Optimistically update local state immediately instead of waiting for
        // %window-renamed event.
        windowNames[windowID] = newName
        chrome?.windowsDidChange()
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

    func switcherCreateSession() {
        // Close the switcher panel first; the new session picker is also a panel
        // and stacking two non-activating panels gets messy.
        switcher.close()

        let picker = NewSessionPanelController()
        picker.onComplete = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancel:
                // Just reopen the switcher; user can try again or close.
                if let win = self.window { self.switcher.open(near: win) }
            case .attach(let s):
                guard let n = s.tmuxSession?.name,
                      let app = NSApp.delegate as? AppDelegate,
                      let controller = TmuxWindowController(launch: .attach(tmuxName: n))
                else { return }
                app.adoptTmuxController(controller)
                controller.showWindow(nil)
            case .create(let input):
                guard let app = NSApp.delegate as? AppDelegate,
                      let controller = TmuxWindowController(launch: .create(input))
                else { return }
                app.adoptTmuxController(controller)
                controller.showWindow(nil)
            }
            self.newSessionPicker = nil   // release the picker once it's settled
        }
        self.newSessionPicker = picker
        if let win = window { picker.open(near: win) }
    }

    func switcherDeleteSession(id: UInt) {
        Task { try? await UtenaDaemonClient.shared.deleteSession(id: id) }
    }

    func switcherRepairSession(id: UInt) {
        Task { try? await UtenaDaemonClient.shared.repairSession(id: id) }
    }

    func switcherArchiveSession(id: UInt) {
        Task { try? await UtenaDaemonClient.shared.archiveSession(id: id) }
    }
}

// MARK: - WorkspacesDelegate

extension TmuxWindowController: WorkspacesDelegate {
    func workspacesAddWorkspace() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        let response = panel.runModal()
        guard response == .OK, let url = panel.urls.first else { return nil }
        return url.path
    }
}

// MARK: - SessionChromeDelegate

extension TmuxWindowController: SessionChromeDelegate {
    var sessionName: String { window?.title ?? "" }
    var activeWindowID: String? { currentWindowID }
    func selectWindow(id: String) {
        guard let item = tabItems[id] else {
            return
        }
        tabView.selectTabViewItem(item)
        currentWindowID = id
        if let firstPaneID = windowPanes[id]?.first, let pane = panes[firstPaneID] {
            setFocus(pane)
        }
        chrome?.windowsDidChange()
    }
    func windowName(forID id: String) -> String? {
        windowNames[id]
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
