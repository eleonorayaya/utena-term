import AppKit

protocol WorkspacesDelegate: AnyObject {
    /// Open an NSOpenPanel to select a workspace directory.
    func workspacesAddWorkspace() -> String?
}


/// WorkspacesController owns the floating panel for workspace management.
final class WorkspacesController: NSWindowController {

    weak var delegate: WorkspacesDelegate?

    private var allWorkspaces: [Workspace] = []
    private var selectedIndex: Int = 0
    private var showHidden: Bool = false
    private var deleteGuard = DoublePressGuard<UInt>()
    private let errorManager = OverlayErrorManager()

    private let header = WorkspacesHeader()
    private let listView = WorkspacesList()
    private let footer = WorkspacesFooter()

    // MARK: - Lifecycle

    convenience init() {
        let panel = WorkspacesPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))

        self.init(window: panel)
        panel.keyHandler = self
        buildContentView(in: panel)
    }

    // MARK: - Open / close

    func open(near anchorWindow: NSWindow?) {
        Task { @MainActor in
            await refreshWorkspaces()
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
        let root = WorkspacesRootView()
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

    private func refreshWorkspaces() async {
        do {
            allWorkspaces = try await UtenaDaemonClient.shared.fetchWorkspaces()
            selectedIndex = min(selectedIndex, max(0, allWorkspaces.count - 1))
            refreshUI()
            clearError()
        } catch {
            showError("Failed to load workspaces")
        }
    }

    private func refreshUI() {
        listView.update(workspaces: allWorkspaces, selectedIndex: selectedIndex, showHidden: showHidden)
        let visibleCount = allWorkspaces.filter { !$0.isHidden }.count
        let hiddenCount = allWorkspaces.count - visibleCount
        header.totalCount = allWorkspaces.count
        header.hiddenCount = hiddenCount
        header.showingHidden = showHidden
        footer.errorMessage = errorManager.errorMessage
    }

    // MARK: - Actions

    private func move(by delta: Int) {
        guard !allWorkspaces.isEmpty else { return }
        let visibleCount = showHidden ? allWorkspaces.count : allWorkspaces.filter { !$0.isHidden }.count
        guard visibleCount > 0 else { return }
        let next = (selectedIndex + delta + visibleCount) % visibleCount
        selectedIndex = next
        refreshUI()
    }

    private func addWorkspace() {
        guard let path = delegate?.workspacesAddWorkspace() else { return }
        Task { @MainActor in
            do {
                let ws = try await UtenaDaemonClient.shared.addWorkspace(path: path)
                allWorkspaces.append(ws)
                selectedIndex = allWorkspaces.count - 1
                refreshUI()
                clearError()
            } catch {
                showError("Failed to add workspace")
            }
        }
    }

    private func deleteSelected() {
        guard !allWorkspaces.isEmpty else { return }
        let ws = allWorkspaces[selectedIndex]
        if deleteGuard.confirm(ws.id) {
            // Second press — execute delete.
            listView.confirmDeleteFor = nil
            Task { @MainActor in
                do {
                    try await UtenaDaemonClient.shared.deleteWorkspace(id: ws.id)
                    allWorkspaces.removeAll { $0.id == ws.id }
                    selectedIndex = min(selectedIndex, max(0, allWorkspaces.count - 1))
                    refreshUI()
                    clearError()
                } catch {
                    showError("Failed to delete workspace")
                }
            }
        } else {
            // First press — show affordance.
            listView.confirmDeleteFor = ws.id
            refreshUI()
        }
    }

    private func toggleHidden() {
        guard !allWorkspaces.isEmpty else { return }
        let ws = allWorkspaces[selectedIndex]
        Task { @MainActor in
            do {
                try await UtenaDaemonClient.shared.setWorkspaceHidden(id: ws.id, hidden: !ws.isHidden)
                if let idx = allWorkspaces.firstIndex(where: { $0.id == ws.id }) {
                    var updated = allWorkspaces[idx]
                    updated.isHidden = !updated.isHidden
                    allWorkspaces[idx] = updated
                }
                refreshUI()
                clearError()
            } catch {
                showError("Failed to toggle hidden")
            }
        }
    }

    private func toggleShowHidden() {
        showHidden.toggle()
        refreshUI()
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

// MARK: - WorkspacesKeyHandling

extension WorkspacesController: WorkspacesKeyHandling {
    func workspacesKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyMap.Key.returnKey: return true  // No-op on enter
        case KeyMap.Key.escape:    close(); return true
        case KeyMap.Key.arrowDown: move(by: +1); return true
        case KeyMap.Key.arrowUp:   move(by: -1); return true
        default: break
        }
        let chars = event.charactersIgnoringModifiers ?? ""
        switch chars {
        case "j": move(by: +1); return true
        case "k": move(by: -1); return true
        case "a": addWorkspace(); return true
        case "d": deleteSelected(); return true
        case "h": toggleHidden(); return true
        case ".": toggleShowHidden(); return true
        default: break
        }
        return false
    }
}

/// Root view — uses shared OverlayRootView from Chrome module.
typealias WorkspacesRootView = OverlayRootView
