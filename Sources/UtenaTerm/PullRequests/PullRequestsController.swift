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
    private let errorManager = OverlayErrorManager()

    private let header = PullRequestsHeader()
    private let listView = PullRequestsList()
    private let footer = PullRequestsFooter()

    // MARK: - Lifecycle

    convenience init() {
        let panel = PullRequestsPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600))

        self.init(window: panel)
        panel.keyHandler = self
        buildContentView(in: panel)
    }

    // MARK: - Open / close

    func open(near anchorWindow: NSWindow?, workspaceId: UInt, workspaceName: String) {
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName

        Task { @MainActor in
            await refreshPullRequests()
        }

        showWindow(nil)
        if let panel = window {
            centerPanel(panel, near: anchorWindow)
        }
    }

    override func close() {
        errorManager.tearDown()
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
        header.errorMessage = errorManager.errorMessage
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
        errorManager.show(message) { [weak self] in
            self?.refreshUI()
        }
        refreshUI()
    }

    private func clearError() {
        errorManager.clear()
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

/// Root view — uses shared OverlayRootView from Chrome module.
typealias PullRequestsRootView = OverlayRootView
