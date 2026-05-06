import AppKit

protocol PullRequestsDelegate: AnyObject {
    // Currently no delegate actions needed
}

/// PullRequestsController owns the floating panel for pull request browsing.
final class PullRequestsController: NSWindowController {

    weak var delegate: PullRequestsDelegate?

    private var allPullRequests: [PullRequest] = []
    private var workspaceName: String = ""
    private var workspaceId: UInt = 0
    private var isLoading: Bool = false
    private var errorMessage: String?
    private var errorDismissTimer: Timer?

    private let header = PullRequestsHeader()
    private let listView = PullRequestsList()
    private let footer = PullRequestsFooter()

    // MARK: - Lifecycle

    convenience init() {
        let panel = PullRequestsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        self.init(window: panel)
        panel.keyHandler = self
        buildContentView(in: panel)
    }

    // MARK: - Open / close

    func open(near anchorWindow: NSWindow?, workspaceId: UInt, workspaceName: String) {
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName

        if let anchor = anchorWindow, let panel = window {
            let anchorFrame = anchor.frame
            let panelSize = panel.frame.size
            let origin = NSPoint(
                x: anchorFrame.midX - panelSize.width / 2,
                y: anchorFrame.midY - panelSize.height / 2
            )
            panel.setFrameOrigin(origin)
        } else {
            window?.center()
        }

        Task { @MainActor in
            await refreshPullRequests()
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        errorDismissTimer?.invalidate()
        errorDismissTimer = nil
        window?.orderOut(nil)
    }

    var isOpen: Bool { window?.isVisible ?? false }

    // MARK: - Build view tree

    private func buildContentView(in panel: NSPanel) {
        let root = PullRequestsRootView()
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

        for v in [header, listView, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(header)
        root.addSubview(listView)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),

            listView.topAnchor.constraint(equalTo: header.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    // MARK: - Data flow

    private func refreshPullRequests() async {
        isLoading = true
        refreshUI()

        do {
            let prs = try await UtenaDaemonClient.shared.fetchPullRequests(workspaceId: workspaceId)
            allPullRequests = prs
            refreshUI()
            clearError()
        } catch {
            showError(error.localizedDescription)
        }

        isLoading = false
        refreshUI()
    }

    private func refreshUI() {
        listView.update(pullRequests: allPullRequests, selectedIndex: 0)
        header.workspaceName = workspaceName
        header.isLoading = isLoading
        header.errorMessage = errorMessage
    }

    // MARK: - Actions

    private func move(by delta: Int) {
        listView.moveSelection(by: delta)
    }

    private func openSelected() {
        guard let pr = listView.getSelectedPR(),
              let url = URL(string: pr.htmlURL) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Error handling

    private func showError(_ message: String) {
        errorMessage = message
        errorDismissTimer?.invalidate()
        errorDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.clearError()
        }
        refreshUI()
    }

    private func clearError() {
        errorMessage = nil
        errorDismissTimer?.invalidate()
        errorDismissTimer = nil
        refreshUI()
    }
}

// MARK: - PullRequestsKeyHandling

extension PullRequestsController: PullRequestsKeyHandling {
    func pullRequestsKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyMap.Key.escape:    close(); return true
        case KeyMap.Key.arrowDown: move(by: +1); return true
        case KeyMap.Key.arrowUp:   move(by: -1); return true
        case KeyMap.Key.returnKey: openSelected(); return true
        default: break
        }
        let chars = event.charactersIgnoringModifiers ?? ""
        switch chars {
        case "j": move(by: +1); return true
        case "k": move(by: -1); return true
        case "o": openSelected(); return true
        default: break
        }
        return false
    }
}

/// Root view — mirrors SwitcherRootView.
final class PullRequestsRootView: NSView {
    override var wantsDefaultClipping: Bool { true }

    override func updateLayer() {
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Palette.border.cgColor
    }

    override var allowsVibrancy: Bool { false }
}
