import AppKit

/// Manages the new-session multi-step flow as an overlay panel.
/// Replaces the old synchronous SessionPickerController.run() with a callback-based async API.
final class NewSessionPanelController: NSWindowController {

    enum Outcome {
        case cancel
        case attach(Session)
        case create(name: String, workspaceId: UInt, branch: String?)
    }

    var onComplete: ((Outcome) -> Void)?

    // MARK: - State

    private enum Step {
        case pickWorkspace
        case pickBranch(workspace: Workspace)
        case enterName(workspace: Workspace, branch: String?)
    }

    private var currentStep: Step = .pickWorkspace
    private var workspaces: [Workspace] = []
    private var branches: [BranchInfo] = []
    private var currentBranch: String?
    private var newBranchName: String?

    // MARK: - UI components

    private let header = NewSessionHeader()
    private let listView = NewSessionListView()
    private let textField = NewSessionTextField()
    private let footer = NewSessionFooter()

    // MARK: - Lifecycle

    convenience init() {
        let panel = NewSessionPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500))
        self.init(window: panel)
        panel.keyHandler = self
        buildContentView(in: panel)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Open / close

    func open(near anchorWindow: NSWindow?) {
        currentStep = .pickWorkspace
        workspaces = []
        branches = []
        currentBranch = nil
        newBranchName = nil

        // Load workspaces immediately
        footer.isLoading = true
        header.currentStep = .workspace
        listView.update(items: [], selectedIndex: 0)
        footer.currentStep = .workspace

        showWindow(nil)
        if let panel = window {
            centerPanel(panel, near: anchorWindow)
        }

        // Fetch workspaces asynchronously
        Task { @MainActor in
            do {
                let ws = try await UtenaDaemonClient.shared.fetchWorkspaces()
                self.workspaces = ws.sorted { a, b in
                    // Visible workspaces first, then hidden
                    if a.isHidden != b.isHidden { return !a.isHidden }
                    return a.name.localizedCompare(b.name) == .orderedAscending
                }
                self.updateWorkspaceList()
                self.footer.isLoading = false
                self.footer.needsDisplay = true
            } catch {
                DebugLog.log("picker", "fetchWorkspaces failed: \(error)")
                self.footer.errorMessage = "Failed to load workspaces"
                self.footer.isLoading = false
                self.footer.needsDisplay = true
            }
        }
    }

    override func close() {
        window?.orderOut(nil)
    }

    var isOpen: Bool { window?.isVisible ?? false }

    // MARK: - Build view tree

    private func buildContentView(in panel: NSPanel) {
        let (root, blur) = (panel as! NewSessionPanel).installStandardVisualization()

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        for v in [header, listView, textField, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(header)
        body.addSubview(listView)
        body.addSubview(textField)
        root.addSubview(footer)

        textField.onCommit = { [weak self] in self?.createSessionIfValid() }

        NSLayoutConstraint.activate([
            // Blur fills the whole panel.
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Header at top
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),

            // Body fills the middle
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor),

            // List and text field fill the body
            listView.topAnchor.constraint(equalTo: body.topAnchor, constant: 16),
            listView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),

            textField.topAnchor.constraint(equalTo: body.topAnchor, constant: 16),
            textField.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            textField.heightAnchor.constraint(equalToConstant: 36),

            // Footer at bottom
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 38),
        ])

        listView.onActivate = { [weak self] in self?.handleListActivation() }
    }

    // MARK: - Step transitions

    private func updateWorkspaceList() {
        let items = workspaces.map { ws in
            NewSessionListView.ListItem(
                id: "\(ws.id)",
                title: ws.name,
                subtitle: ws.isHidden ? "(hidden)" : nil,
                isCurrentBranch: false
            )
        }
        listView.update(items: items, selectedIndex: 0)
    }

    private func updateBranchList() {
        var items = [
            NewSessionListView.ListItem(
                id: "NEW",
                title: "+ New branch",
                subtitle: "Enter a custom branch name",
                isCurrentBranch: false
            )
        ]
        items += branches.map { branch in
            NewSessionListView.ListItem(
                id: branch.name,
                title: branch.name,
                subtitle: nil,
                isCurrentBranch: branch.name == self.currentBranch
            )
        }
        listView.update(items: items, selectedIndex: 0)
    }

    private func handleListActivation() {
        guard let selected = listView.getSelectedItem() else { return }

        switch currentStep {
        case .pickWorkspace:
            if let workspace = workspaces.first(where: { "\($0.id)" == selected.id }) {
                transitionToBranchStep(workspace: workspace)
            }

        case .pickBranch:
            if selected.id == "NEW" {
                // Prompt for new branch name
                showNewBranchPrompt()
            } else if let branch = branches.first(where: { $0.name == selected.id }) {
                transitionToNameStep(branch: branch.name)
            }

        case .enterName:
            createSessionIfValid()
        }
    }

    private func transitionToBranchStep(workspace: Workspace) {
        currentStep = .pickBranch(workspace: workspace)
        header.currentStep = .branch
        footer.currentStep = .branch
        footer.isLoading = true
        footer.errorMessage = nil
        footer.needsDisplay = true

        Task { @MainActor in
            do {
                let response = try await UtenaDaemonClient.shared.fetchBranches(workspaceId: workspace.id)
                self.branches = response.branches
                self.currentBranch = response.currentBranch
                self.updateBranchList()
                self.footer.isLoading = false
                self.footer.needsDisplay = true
            } catch {
                DebugLog.log("picker", "fetchBranches failed: \(error)")
                self.footer.errorMessage = "Failed to load branches"
                self.footer.isLoading = false
                self.footer.needsDisplay = true
            }
        }
    }

    private func transitionToNameStep(branch: String) {
        guard case .pickBranch(let workspace) = currentStep else { return }
        currentStep = .enterName(workspace: workspace, branch: branch)
        newBranchName = nil
        header.currentStep = .name
        footer.currentStep = .name
        footer.isLoading = false
        footer.errorMessage = nil
        footer.needsDisplay = true

        // Hide list, show text field
        listView.isHidden = true
        textField.isHidden = false
        textField.setText("")
        textField.focus()
    }

    private func showNewBranchPrompt() {
        let alert = NSAlert()
        alert.messageText = "New Branch"
        alert.informativeText = "Enter the branch name"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Branch name"
        alert.accessoryView = textField
        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn {
                let branchName = textField.stringValue.trimmingCharacters(in: .whitespaces)
                if !branchName.isEmpty {
                    self.newBranchName = branchName
                    self.transitionToNameStep(branch: branchName)
                }
            }
        }
    }

    private func goBackOneStep() {
        switch currentStep {
        case .pickWorkspace:
            // Cancel
            onComplete?(.cancel)
            close()

        case .pickBranch:
            currentStep = .pickWorkspace
            header.currentStep = .workspace
            footer.currentStep = .workspace
            footer.isLoading = false
            footer.errorMessage = nil
            footer.needsDisplay = true
            updateWorkspaceList()

        case .enterName:
            guard case .enterName(let workspace, _) = currentStep else { return }
            currentStep = .pickBranch(workspace: workspace)
            header.currentStep = .branch
            footer.currentStep = .branch
            footer.isLoading = false
            footer.errorMessage = nil
            footer.needsDisplay = true
            listView.isHidden = false
            textField.isHidden = true
            updateBranchList()
        }
    }

    private func createSessionIfValid() {
        guard case .enterName(let workspace, let branch) = currentStep else { return }
        let name = textField.getText()
        guard !name.isEmpty else {
            textField.shake()
            return
        }

        footer.isLoading = true
        footer.errorMessage = nil
        footer.needsDisplay = true

        Task { @MainActor in
            do {
                _ = try await UtenaDaemonClient.shared.createSession(
                    name: name,
                    workspaceId: workspace.id,
                    branch: branch
                )
                self.onComplete?(.create(name: name, workspaceId: workspace.id, branch: branch))
                self.close()
            } catch {
                DebugLog.log("picker", "createSession failed: \(error)")
                self.footer.isLoading = false
                self.footer.errorMessage = "Failed to create session"
                self.footer.needsDisplay = true

                // Clear the error after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    self.footer.errorMessage = nil
                    self.footer.needsDisplay = true
                }
            }
        }
    }
}

// MARK: - NewSessionKeyHandling

extension NewSessionPanelController: NewSessionKeyHandling {
    func newSessionKeyDown(_ event: NSEvent) -> Bool {
        // ⌘W cancels the picker entirely (mirrors a Mac window close).
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "w" {
            onComplete?(.cancel)
            close()
            return true
        }
        switch event.keyCode {
        case KeyMap.Key.escape:
            goBackOneStep()
            return true

        case KeyMap.Key.returnKey:
            handleListActivation()
            return true

        case KeyMap.Key.arrowUp:
            listView.move(by: -1)
            return true

        case KeyMap.Key.arrowDown:
            listView.move(by: +1)
            return true

        default:
            let chars = event.charactersIgnoringModifiers ?? ""
            switch chars {
            case "j":
                listView.move(by: +1)
                return true
            case "k":
                listView.move(by: -1)
                return true
            case "n":
                // "n" for "new branch" in the branch step
                if case .pickBranch = currentStep {
                    showNewBranchPrompt()
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}
