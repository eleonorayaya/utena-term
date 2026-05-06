import AppKit

protocol SwitcherDelegate: AnyObject {
    /// Attach to the named tmux session (calls `switch-client -t name`).
    func switcherAttach(tmuxName: String)
    /// Returns the currently focused session name (so we can highlight it).
    var currentSessionName: String { get }
    /// Create a new session (open the session picker flow in a new window).
    func switcherCreateSession()
    /// Delete a session by id.
    func switcherDeleteSession(id: UInt)
    /// Repair a session by id.
    func switcherRepairSession(id: UInt)
    /// Archive a session by id.
    func switcherArchiveSession(id: UInt)
}


/// SwitcherController owns the floating panel and the inner view tree.
/// Lifecycle: created on first ⌃b p, kept alive across opens (cheap to
/// re-show; expensive to re-build the visual-effect view).
final class SwitcherController: NSWindowController {

    // MARK: - State

    weak var delegate: SwitcherDelegate?

    private var sessions: [Session] = []
    private var filtered: [Session] = []
    private var selectedIndex: Int = 0
    private var query: String = ""
    private var sessionsObserver: NSObjectProtocol?
    private var deleteGuard = DoublePressGuard<UInt>()
    private var isInsertMode = true  // Vim-style: insert (search) vs normal (command) mode

    private let header = SwitcherHeader()
    private let listView = SwitcherSessionList()
    private let detailView = SwitcherDetailView()
    private let footer = SwitcherFooter()

    // MARK: - Lifecycle

    convenience init() {
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720))

        self.init(window: panel)
        panel.keyHandler = self
        buildContentView(in: panel)

        sessionsObserver = NotificationCenter.default.addObserver(
            forName: .utenaSessionsDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let s = note.userInfo?["sessions"] as? [Session] else { return }
            self?.applySessions(s)
            self?.updateDetailFromNotification(s)
        }
    }

    deinit {
        if let sessionsObserver { NotificationCenter.default.removeObserver(sessionsObserver) }
    }

    // MARK: - Open / close

    func open(near anchorWindow: NSWindow?) {
        // Reset to insert mode on each open
        isInsertMode = true
        query = ""
        selectedIndex = 0
        deleteGuard.clear()
        listView.confirmKillFor = nil

        // Pre-populate from cached sessions so the panel renders instantly,
        // even on the first open before any notification has fired.
        Task { @MainActor in
            let cached = await UtenaDaemonClient.shared.cachedSessions
            if !cached.isEmpty { applySessions(cached) }
        }

        showWindow(nil)
        if let panel = window {
            centerPanel(panel, near: anchorWindow)
        }
    }

    override func close() {
        window?.orderOut(nil)
    }

    var isOpen: Bool { window?.isVisible ?? false }

    // MARK: - Build view tree

    private func buildContentView(in panel: NSPanel) {
        let root = SwitcherRootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.masksToBounds = true
        root.addSubview(blur)

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        let leftHost = NSView()
        leftHost.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(leftHost)

        let rightHost = NSView()
        rightHost.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(rightHost)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.borderSubtle.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(divider)

        for v in [header, listView, detailView, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(header)
        leftHost.addSubview(listView)
        rightHost.addSubview(detailView)
        root.addSubview(footer)

        let leftWidth = leftHost.widthAnchor.constraint(
            equalTo: rightHost.widthAnchor, multiplier: 1.15
        )

        NSLayoutConstraint.activate([
            // Blur fills the whole panel.
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Header at top.
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),

            // Body fills the middle.
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor),

            // Left | divider | right inside body.
            leftHost.topAnchor.constraint(equalTo: body.topAnchor),
            leftHost.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            leftHost.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            leftHost.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            leftWidth,

            divider.topAnchor.constraint(equalTo: body.topAnchor),
            divider.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            rightHost.topAnchor.constraint(equalTo: body.topAnchor),
            rightHost.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            rightHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightHost.trailingAnchor.constraint(equalTo: body.trailingAnchor),

            listView.topAnchor.constraint(equalTo: leftHost.topAnchor),
            listView.leadingAnchor.constraint(equalTo: leftHost.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: leftHost.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: leftHost.bottomAnchor),

            detailView.topAnchor.constraint(equalTo: rightHost.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: rightHost.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: rightHost.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: rightHost.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 38),
        ])

        listView.onActivate = { [weak self] in self?.attachSelected() }
    }

    // MARK: - Data flow

    private func applySessions(_ s: [Session]) {
        let liveStatuses: Set<SessionStatus> = [.active, .creating, .pending]
        sessions = s.filter { liveStatuses.contains($0.status) }
        applyFilter()
    }

    private func applyFilter() {
        let pool: [Session]
        if query.isEmpty {
            pool = sessions
        } else {
            let q = query.lowercased()
            pool = sessions.filter { $0.name.lowercased().contains(q) }
        }
        // Sort by section priority so j/k navigation order matches visual
        // (attention first, then active, then idle).
        filtered = pool.sorted { lhs, rhs in
            let lp = Self.sectionPriority(lhs)
            let rp = Self.sectionPriority(rhs)
            if lp != rp { return lp < rp }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
        selectedIndex = min(selectedIndex, max(0, filtered.count - 1))
        refreshUI()
    }

    private static func sectionPriority(_ s: Session) -> Int {
        if s.needsAttention { return 0 }
        if s.status == .active || s.status == .creating { return 1 }
        return 2
    }

    private func refreshUI() {
        listView.update(
            sessions: filtered,
            selectedIndex: selectedIndex,
            currentName: delegate?.currentSessionName ?? ""
        )
        let focused: Session? = {
            guard !filtered.isEmpty else { return nil }
            return filtered[selectedIndex]
        }()
        detailView.session = focused
        header.totalCount = sessions.count
        header.attentionCount = sessions.filter { $0.needsAttention }.count
        header.queryDisplay = query
        header.isInsertMode = isInsertMode
        footer.isInsertMode = isInsertMode
    }

    /// Called when daemon publishes new session data; find and update the
    /// currently-selected session in the detail view.
    private func updateDetailFromNotification(_ allSessions: [Session]) {
        guard !filtered.isEmpty, selectedIndex < filtered.count else { return }
        let currentSession = filtered[selectedIndex]
        if let updated = allSessions.first(where: { $0.id == currentSession.id }) {
            detailView.session = updated
        }
    }

    // MARK: - Actions

    private func attachSelected() {
        guard !filtered.isEmpty else { return }
        let s = filtered[selectedIndex]
        guard let tmuxName = s.tmuxSessionName else { return }
        delegate?.switcherAttach(tmuxName: tmuxName)
        close()
    }

    private func move(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let next = (selectedIndex + delta + filtered.count) % filtered.count
        selectedIndex = next
        refreshUI()
    }

    private func deleteSelected() {
        guard !filtered.isEmpty else { return }
        let s = filtered[selectedIndex]
        if deleteGuard.confirm(s.id) {
            // Second press within the window — confirm the delete.
            listView.confirmKillFor = nil
            delegate?.switcherDeleteSession(id: s.id)
        } else {
            // First press — show affordance.
            listView.confirmKillFor = s.id
        }
        refreshUI()
    }

    private func repairSelected() {
        guard !filtered.isEmpty else { return }
        let s = filtered[selectedIndex]
        delegate?.switcherRepairSession(id: s.id)
    }

    private func archiveSelected() {
        guard !filtered.isEmpty else { return }
        let s = filtered[selectedIndex]
        delegate?.switcherArchiveSession(id: s.id)
    }

    private func createSession() {
        deleteGuard.clear()
        listView.confirmKillFor = nil
        delegate?.switcherCreateSession()
        close()
    }

    private func appendQuery(_ s: String) {
        query += s
        applyFilter()
    }

    private func backspaceQuery() {
        guard !query.isEmpty else { return }
        query.removeLast()
        applyFilter()
    }

    private func clearQuery() {
        guard !query.isEmpty else {
            close()
            return
        }
        query = ""
        applyFilter()
    }
}

// MARK: - SwitcherKeyHandling

extension SwitcherController: SwitcherKeyHandling {
    func switcherKeyDown(_ event: NSEvent) -> Bool {
        if isInsertMode {
            return handleInsertKey(event)
        } else {
            return handleNormalKey(event)
        }
    }

    private func handleInsertKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyMap.Key.escape:
            if !query.isEmpty {
                clearQuery()
            } else {
                isInsertMode = false
                refreshUI()
            }
            return true
        case KeyMap.Key.returnKey:
            attachSelected()
            return true
        case KeyMap.Key.arrowUp:
            move(by: -1)
            return true
        case KeyMap.Key.arrowDown:
            move(by: +1)
            return true
        case KeyMap.Key.backspace:
            backspaceQuery()
            return true
        default:
            break
        }

        // Allow all alphanumerics and -_/. into the query in insert mode
        let chars = event.charactersIgnoringModifiers ?? ""
        if chars.count == 1, let scalar = chars.unicodeScalars.first,
           (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "/") {
            appendQuery(chars)
            return true
        }
        return false
    }

    private func handleNormalKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyMap.Key.escape:
            close()
            return true
        case KeyMap.Key.returnKey:
            attachSelected()
            return true
        case KeyMap.Key.arrowUp, KeyMap.Key.k:
            move(by: -1)
            return true
        case KeyMap.Key.arrowDown, KeyMap.Key.j:
            move(by: +1)
            return true
        default:
            break
        }

        let chars = event.charactersIgnoringModifiers ?? ""
        switch chars {
        case "j":
            move(by: +1)
            return true
        case "k":
            move(by: -1)
            return true
        case "c":
            createSession()
            return true
        case "d":
            deleteSelected()
            return true
        case "r":
            repairSelected()
            return true
        case "a":
            archiveSelected()
            return true
        case "i":
            isInsertMode = true
            refreshUI()
            return true
        case "/":
            isInsertMode = true
            clearQuery()
            refreshUI()
            return true
        default:
            return true  // Eat all other keys in normal mode
        }
    }
}

/// Root view — uses shared OverlayRootView from Chrome module.
typealias SwitcherRootView = OverlayRootView
