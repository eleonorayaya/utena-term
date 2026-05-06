import AppKit

/// Manages the new-session multi-step flow as an overlay panel.
/// Replaces the old synchronous SessionPickerController.run() with a callback-based async API.
final class NewSessionPanelController: NSWindowController {

    enum Outcome {
        case cancel
        case attach(Session)
        case create(CreateSessionInput)
    }

    var onComplete: ((Outcome) -> Void)?

    // MARK: - State

    private enum Step {
        case pickWorkspace
        case pickBranch(workspace: Workspace)
        case pickBranchMode(workspace: Workspace, baseBranch: String)
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

        Task { @MainActor [weak self] in
            do {
                let ws = try await UtenaDaemonClient.shared.fetchWorkspaces()
                self?.allWorkspaces = ws.sorted { a, b in
                    if a.isHidden != b.isHidden { return !a.isHidden }
                    return a.name.localizedCompare(b.name) == .orderedAscending
                }
                self?.updateWorkspaceList()
                self?.footer.isLoading = false
            } catch {
                DebugLog.log("picker", "fetchWorkspaces failed: \(error)")
                self?.footer.errorMessage = "Failed to load workspaces"
                self?.footer.isLoading = false
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

    private func updateBranchList() {
        branches = filtered(allBranches) { $0.name }
        let items = branches.map { branch in
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
            if let branch = branches.first(where: { $0.name == selected.id }) {
                transitionToPickBranchMode(workspace: workspace, baseBranch: branch.name)
            }

        case .pickBranchMode(let workspace, let baseBranch):
            if selected.id == "USE" {
                // Use existing branch directly — session name defaults to the
                // branch name; no name step needed.
                performCreateSession(CreateSessionInput(
                    name: baseBranch,
                    workspaceId: workspace.id,
                    branch: baseBranch,
                    baseBranch: nil,
                    createWorktree: true
                ))
            } else if selected.id == "NEW" {
                showNewBranchPrompt(workspace: workspace, baseBranch: baseBranch)
            }

        case .enterName:
            createSessionIfValid()
        }
    }

    /// Centralized step-transition primitive: updates the controller, the
    /// header breadcrumb, the footer, and resets the search query / mode in
    /// one place. Anything outside this function (list-vs-textField visibility,
    /// async fetches) stays in the calling transition method.
    private func setStep(_ step: Step) {
        currentStep = step
        query = ""
        header.query = ""
        footer.errorMessage = nil
        footer.isLoading = false
        switch step {
        case .pickWorkspace:
            isInsertMode = false
            header.currentStep = .workspace
            header.modeIndicator = .normal
            footer.currentStep = .workspace
        case .pickBranch:
            isInsertMode = false
            header.currentStep = .branch
            header.modeIndicator = .normal
            footer.currentStep = .branch
        case .pickBranchMode:
            isInsertMode = false
            header.currentStep = .mode
            header.modeIndicator = .normal
            footer.currentStep = .mode
        case .enterName:
            header.currentStep = .name
            header.modeIndicator = .hidden
            footer.currentStep = .name
        }
    }

    private func transitionToBranchStep(workspace: Workspace) {
        setStep(.pickBranch(workspace: workspace))
        footer.isLoading = true

        Task { @MainActor [weak self] in
            do {
                let response = try await UtenaDaemonClient.shared.fetchBranches(workspaceId: workspace.id)
                self?.allBranches = response.branches
                self?.currentBranch = response.currentBranch
                self?.updateBranchList()
                self?.footer.isLoading = false
            } catch {
                DebugLog.log("picker", "fetchBranches failed: \(error)")
                self?.footer.errorMessage = "Failed to load branches"
                self?.footer.isLoading = false
            }
        }
    }

    private func transitionToNameStep(workspace: Workspace, branch: String, baseBranch: String?, createWorktree: Bool) {
        setStep(.enterName(workspace: workspace, branch: branch, baseBranch: baseBranch, createWorktree: createWorktree))
        listView.isHidden = true
        textField.isHidden = false
        textField.setText("")
        textField.focus()
    }

    private func transitionToPickBranchMode(workspace: Workspace, baseBranch: String) {
        setStep(.pickBranchMode(workspace: workspace, baseBranch: baseBranch))
        // NEW first so it's the default selection — most common path is forking
        // a fresh branch off the picked one.
        let items = [
            NewSessionListView.ListItem(
                id: "NEW",
                title: "Create new branch off \(baseBranch)",
                subtitle: "Fork a fresh branch and create a worktree on it",
                isCurrentBranch: false
            ),
            NewSessionListView.ListItem(
                id: "USE",
                title: "Use \(baseBranch)",
                subtitle: "Create a worktree from the existing branch",
                isCurrentBranch: false
            ),
        ]
        listView.update(items: items, selectedIndex: 0)
    }

    private func showNewBranchPrompt(workspace: Workspace, baseBranch: String) {
        let alert = NSAlert()
        alert.messageText = "New Branch"
        alert.informativeText = "Enter the name for the new branch (forked from \(baseBranch))"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Branch name"
        alert.accessoryView = textField
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let branchName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !branchName.isEmpty else { return }
            self?.transitionToNameStep(workspace: workspace, branch: branchName, baseBranch: baseBranch, createWorktree: true)
        }
    }

    private func goBackOneStep() {
        switch currentStep {
        case .pickWorkspace:
            onComplete?(.cancel)
            close()

        case .pickBranch:
            setStep(.pickWorkspace)
            updateWorkspaceList()

        case .pickBranchMode(let workspace, _):
            setStep(.pickBranch(workspace: workspace))
            updateBranchList()

        case .enterName(let workspace, let branch, let baseBranch, _):
            // Came from fork path? Return to mode picker. Otherwise the use-existing path.
            listView.isHidden = false
            textField.isHidden = true
            if let baseBranch, branch != baseBranch {
                // The "fork" path was used (newBranch != baseBranch)
                transitionToPickBranchMode(workspace: workspace, baseBranch: baseBranch)
            } else {
                // The "use existing" path was used (branch == baseBranch or no baseBranch)
                setStep(.pickBranch(workspace: workspace))
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
        performCreateSession(CreateSessionInput(
            name: name,
            workspaceId: workspace.id,
            branch: branch,
            baseBranch: baseBranch,
            createWorktree: createWorktree
        ))
    }

    /// Dispatches the create-session API call with footer loading/error UI.
    /// Used by both the name-step submission and the "use existing branch"
    /// path (which skips naming since the session inherits the branch name).
    private func performCreateSession(_ input: CreateSessionInput) {
        footer.isLoading = true
        footer.errorMessage = nil
        Task { @MainActor [weak self] in
            do {
                _ = try await UtenaDaemonClient.shared.createSession(input)
                self?.onComplete?(.create(input))
                self?.close()
            } catch {
                DebugLog.log("picker", "createSession failed: \(error)")
                self?.footer.isLoading = false
                self?.footer.errorMessage = "Failed to create session"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.footer.errorMessage = nil
                }
            }
        }
    }
}

// MARK: - Helpers

private extension NewSessionPanelController {
    var isListStep: Bool {
        switch currentStep {
        case .pickWorkspace, .pickBranch, .pickBranchMode:
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
        }
    }
}
