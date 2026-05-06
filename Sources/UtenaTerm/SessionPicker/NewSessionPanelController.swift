import AppKit

/// Manages the new-session multi-step flow as an overlay panel.
/// Replaces the old synchronous SessionPickerController.run() with a callback-based async API.
final class NewSessionPanelController: NSWindowController {

    enum Outcome {
        case cancel
        case attach(Session)
        case create(name: String, workspaceId: UInt, branch: String?, baseBranch: String?, createWorktree: Bool)
    }

    var onComplete: ((Outcome) -> Void)?

    // MARK: - State

    private enum Step {
        case pickWorkspace
        case pickBranch(workspace: Workspace)
        case pickBaseBranch(workspace: Workspace, newBranchName: String)
        case enterName(workspace: Workspace, branch: String?, baseBranch: String?, createWorktree: Bool)
    }

    private var currentStep: Step = .pickWorkspace
    private var isInsertMode: Bool = true   // search-as-you-type by default; Esc on empty query → normal
    private var query: String = ""
    private var allWorkspaces: [Workspace] = []
    private var workspaces: [Workspace] = []  // filtered by query
    private var allBranches: [BranchInfo] = []
    private var branches: [BranchInfo] = []  // filtered by query
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
        isInsertMode = false
        query = ""
        allWorkspaces = []
        workspaces = []
        allBranches = []
        branches = []
        currentBranch = nil
        newBranchName = nil

        // Load workspaces immediately
        footer.isLoading = true
        header.currentStep = .workspace
        header.query = ""
        header.modeIndicator = .normal
        listView.update(items: [], selectedIndex: 0)
        footer.currentStep = .workspace

        // Reset visibility — re-opens may land on a different step than last time.
        listView.isHidden = false
        textField.isHidden = true

        showWindow(nil)
        if let panel = window {
            centerPanel(panel, near: anchorWindow)
            // Take first responder explicitly so keystrokes reach
            // newSessionKeyDown (otherwise NSTextField inside the tree may
            // claim focus and swallow j/k/arrows).
            panel.makeFirstResponder(panel)
        }

        // Fetch workspaces asynchronously
        Task { @MainActor in
            do {
                let ws = try await UtenaDaemonClient.shared.fetchWorkspaces()
                self.allWorkspaces = ws.sorted { a, b in
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

        // Only the name step shows the text field — start it hidden so it
        // doesn't overlap the workspace/branch list and steal first-responder.
        textField.isHidden = true
        listView.isHidden = false

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

    private func filtered<T>(_ items: [T], title: (T) -> String) -> [T] {
        guard !query.isEmpty else { return items }
        let q = query.lowercased()
        return items.filter { title($0).lowercased().contains(q) }
    }

    private func updateWorkspaceList() {
        workspaces = filtered(allWorkspaces) { $0.name }
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

    private func updateBranchList(includeNewOption: Bool = true) {
        branches = filtered(allBranches) { $0.name }
        var items: [NewSessionListView.ListItem] = []
        if includeNewOption {
            items.append(NewSessionListView.ListItem(
                id: "NEW",
                title: "+ New branch",
                subtitle: "Enter a custom branch name",
                isCurrentBranch: false
            ))
        }
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

        case .pickBranch(let workspace):
            if selected.id == "NEW" {
                // Prompt for new branch name, then transition to pickBaseBranch
                showNewBranchPrompt(workspace: workspace)
            } else if let branch = branches.first(where: { $0.name == selected.id }) {
                transitionToNameStep(workspace: workspace, branch: branch.name, baseBranch: nil, createWorktree: false)
            }

        case .pickBaseBranch(let workspace, let newBranchName):
            if let branch = branches.first(where: { $0.name == selected.id }) {
                transitionToNameStep(workspace: workspace, branch: newBranchName, baseBranch: branch.name, createWorktree: true)
            }

        case .enterName:
            createSessionIfValid()
        }
    }

    private func transitionToBranchStep(workspace: Workspace) {
        currentStep = .pickBranch(workspace: workspace)
        query = ""
        isInsertMode = false
        header.currentStep = .branch
        header.query = ""
        header.modeIndicator = .normal
        footer.currentStep = .branch
        footer.isLoading = true
        footer.errorMessage = nil
        footer.needsDisplay = true

        Task { @MainActor in
            do {
                let response = try await UtenaDaemonClient.shared.fetchBranches(workspaceId: workspace.id)
                self.allBranches = response.branches
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

    private func transitionToNameStep(workspace: Workspace, branch: String, baseBranch: String?, createWorktree: Bool) {
        currentStep = .enterName(workspace: workspace, branch: branch, baseBranch: baseBranch, createWorktree: createWorktree)
        newBranchName = nil
        header.currentStep = .name
        header.modeIndicator = .hidden
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

    private func showNewBranchPrompt(workspace: Workspace) {
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
                    self.transitionToPickBaseBranchStep(workspace: workspace, newBranchName: branchName)
                }
            }
        }
    }

    private func transitionToPickBaseBranchStep(workspace: Workspace, newBranchName: String) {
        currentStep = .pickBaseBranch(workspace: workspace, newBranchName: newBranchName)
        query = ""
        isInsertMode = false
        header.currentStep = .base
        header.query = ""
        header.modeIndicator = .normal
        footer.currentStep = .base
        footer.isLoading = false
        footer.errorMessage = nil
        footer.needsDisplay = true

        // List is already populated from the previous branch step, just refresh without "+ New"
        updateBranchList(includeNewOption: false)
    }

    private func goBackOneStep() {
        switch currentStep {
        case .pickWorkspace:
            // Cancel
            onComplete?(.cancel)
            close()

        case .pickBranch:
            currentStep = .pickWorkspace
            query = ""
            isInsertMode = false
            header.currentStep = .workspace
            header.query = ""
            header.modeIndicator = .normal
            footer.currentStep = .workspace
            footer.isLoading = false
            footer.errorMessage = nil
            footer.needsDisplay = true
            updateWorkspaceList()

        case .pickBaseBranch(let workspace, _):
            currentStep = .pickBranch(workspace: workspace)
            query = ""
            isInsertMode = false
            header.currentStep = .branch
            header.query = ""
            header.modeIndicator = .normal
            footer.currentStep = .branch
            footer.isLoading = false
            footer.errorMessage = nil
            footer.needsDisplay = true
            updateBranchList()

        case .enterName(let workspace, _, _, _):
            // Check if this was a new branch (has baseBranch); if so, go back to pickBaseBranch
            guard case .enterName(_, let branch, let baseBranch, _) = currentStep else { return }
            if baseBranch != nil {
                // Go back to pickBaseBranch
                currentStep = .pickBaseBranch(workspace: workspace, newBranchName: branch!)
                query = ""
                isInsertMode = false
                header.currentStep = .base
                header.query = ""
                header.modeIndicator = .normal
                footer.currentStep = .base
                footer.isLoading = false
                footer.errorMessage = nil
                footer.needsDisplay = true
                listView.isHidden = false
                textField.isHidden = true
                updateBranchList(includeNewOption: false)
            } else {
                // Go back to pickBranch
                currentStep = .pickBranch(workspace: workspace)
                query = ""
                isInsertMode = false
                header.currentStep = .branch
                header.query = ""
                header.modeIndicator = .normal
                footer.currentStep = .branch
                footer.isLoading = false
                footer.errorMessage = nil
                footer.needsDisplay = true
                listView.isHidden = false
                textField.isHidden = true
                updateBranchList()
            }
        }
    }

    private func createSessionIfValid() {
        guard case .enterName(let workspace, let branch, let baseBranch, let createWorktree) = currentStep else { return }
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
                    branch: branch,
                    baseBranch: baseBranch,
                    createWorktree: createWorktree
                )
                self.onComplete?(.create(name: name, workspaceId: workspace.id, branch: branch, baseBranch: baseBranch, createWorktree: createWorktree))
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

// MARK: - Helpers

private extension NewSessionPanelController {
    var isListStep: Bool {
        switch currentStep {
        case .pickWorkspace, .pickBranch, .pickBaseBranch:
            return true
        case .enterName:
            return false
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

        // The .enterName step has the text field focused — let it own keys.
        if !isListStep { return handleEnterNameKey(event) }
        if isInsertMode { return handleListInsertKey(event) }
        return handleListNormalKey(event)
    }

    private func handleEnterNameKey(_ event: NSEvent) -> Bool {
        // Only ⎋ is intercepted — go back to the branch step.
        if event.keyCode == KeyMap.Key.escape {
            goBackOneStep()
            return true
        }
        return false
    }

    private func handleListInsertKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyMap.Key.escape:
            // Non-empty query → clear it. Empty query → exit to normal mode
            // (rather than going back, so users can use j/k from there).
            if !query.isEmpty {
                query = ""
                header.query = ""
                refilter()
            } else {
                isInsertMode = false
                header.modeIndicator = .normal
            }
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
        case KeyMap.Key.backspace:
            if !query.isEmpty {
                query.removeLast()
                header.query = query
                refilter()
                return true
            }
            return true   // eat empty-backspace so it doesn't fall through
        default:
            // Alphanumerics + - / _ feed the query
            let chars = event.charactersIgnoringModifiers ?? ""
            if chars.count == 1, let scalar = chars.unicodeScalars.first,
               (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "/"),
               !event.modifierFlags.contains(.command) {
                query += chars
                header.query = query
                refilter()
                return true
            }
            return false
        }
    }

    private func handleListNormalKey(_ event: NSEvent) -> Bool {
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
            case "i", "/":
                isInsertMode = true
                header.modeIndicator = .insert
                if chars == "/" {
                    // `/` is a fresh search; clear any leftover query.
                    query = ""
                    header.query = ""
                    refilter()
                }
                return true
            default:
                return true   // eat unknown keys in normal mode
            }
        }
    }

    private func refilter() {
        if case .pickWorkspace = currentStep {
            updateWorkspaceList()
        } else if case .pickBranch = currentStep {
            updateBranchList()
        } else if case .pickBaseBranch = currentStep {
            updateBranchList(includeNewOption: false)
        }
    }
}
