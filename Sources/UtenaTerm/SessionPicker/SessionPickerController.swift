import AppKit

// MARK: - Result type

enum SessionPickerResult {
    case attach(Session)
    case create(name: String, workspaceId: UInt, branch: String?)
    case cancel
}

// MARK: - Row model

private struct SessionRow {
    let session: Session
    var dotColor: NSColor {
        guard !session.needsAttention else { return .systemOrange }
        switch session.status {
        case .active: return .systemGreen
        case .creating, .pending: return .systemYellow
        default: return .tertiaryLabelColor
        }
    }
    var subtitle: String {
        var parts: [String] = []
        if let branch = session.branchName { parts.append(branch) }
        parts.append(session.status.rawValue)
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Controller

final class SessionPickerController: NSWindowController {

    private let tableView = SessionTableView()
    private let scrollView = NSScrollView()
    private let newSessionForm = NewSessionFormView()
    private let toggleFormButton = NSButton()
    private let headerLabel = NSTextField(labelWithString: "Open Session")

    private var rows: [SessionRow] = []
    private var result: SessionPickerResult = .cancel

    static func run(sessions: [Session]) -> SessionPickerResult {
        let ctrl = SessionPickerController(sessions: sessions)
        NSApp.runModal(for: ctrl.window!)
        return ctrl.result
    }

    init(sessions: [Session]) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.center()
        super.init(window: panel)

        rows = sessions
            .filter { $0.status != .deleted && $0.status != .archived }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .map { SessionRow(session: $0) }

        setupContent(panel: panel)
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.pickerDelegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupContent(panel: NSPanel) {
        let blur = NSVisualEffectView(frame: panel.contentView!.bounds)
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur

        // Header
        headerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(headerLabel)

        // Toggle button
        toggleFormButton.title = "+ New"
        toggleFormButton.bezelStyle = .inline
        toggleFormButton.font = .systemFont(ofSize: 12)
        toggleFormButton.target = self
        toggleFormButton.action = #selector(toggleNewForm)
        toggleFormButton.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(toggleFormButton)

        // Table
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 46
        tableView.intercellSpacing = .zero

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        col.width = 520
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(openSelected)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(scrollView)

        // New session form (hidden initially)
        newSessionForm.isHidden = true
        newSessionForm.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(newSessionForm)
        newSessionForm.onCommit = { [weak self] name, workspaceId, branch in self?.commitCreate(name: name, workspaceId: workspaceId, branch: branch) }
        newSessionForm.onCancel = { [weak self] in self?.toggleNewForm() }

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: blur.topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 16),

            toggleFormButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            toggleFormButton.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: newSessionForm.topAnchor),

            newSessionForm.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            newSessionForm.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            newSessionForm.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            newSessionForm.heightAnchor.constraint(equalToConstant: 110),
        ])
    }

    @objc private func toggleNewForm() {
        let showing = newSessionForm.isHidden
        newSessionForm.isHidden = !showing
        toggleFormButton.title = showing ? "✕ Cancel" : "+ New"
        window?.makeFirstResponder(showing ? newSessionForm.nameField : tableView)
    }

    @objc func openSelected() {
        guard tableView.selectedRow >= 0 else { return }
        result = .attach(rows[tableView.selectedRow].session)
        dismiss()
    }

    private func commitCreate(name: String, workspaceId: UInt, branch: String?) {
        guard !name.isEmpty else { return }
        result = .create(name: name, workspaceId: workspaceId, branch: branch)
        dismiss()
    }

    private func dismiss() {
        NSApp.stopModal()
        window?.orderOut(nil)
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension SessionPickerController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let cell = SessionCellView()
        cell.configure(row: item)
        return cell
    }

}

// MARK: - SessionTableViewDelegate

extension SessionPickerController: SessionTableViewDelegate {
    func sessionTableViewDidPressReturn(_ tv: SessionTableView) { openSelected() }
    func sessionTableViewDidPressEscape(_ tv: SessionTableView) { dismiss() }
    func sessionTableViewDidPressN(_ tv: SessionTableView) {
        if newSessionForm.isHidden { toggleNewForm() }
    }
}

// MARK: - SessionTableView (keyboard nav)

protocol SessionTableViewDelegate: AnyObject {
    func sessionTableViewDidPressReturn(_ tv: SessionTableView)
    func sessionTableViewDidPressEscape(_ tv: SessionTableView)
    func sessionTableViewDidPressN(_ tv: SessionTableView)
}

final class SessionTableView: NSTableView {
    weak var pickerDelegate: SessionTableViewDelegate?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: pickerDelegate?.sessionTableViewDidPressReturn(self)
        case 53: pickerDelegate?.sessionTableViewDidPressEscape(self)
        case 125: move(by: +1)
        case 126: move(by: -1)
        default:
            switch event.charactersIgnoringModifiers {
            case "j": move(by: +1)
            case "k": move(by: -1)
            case "n": pickerDelegate?.sessionTableViewDidPressN(self)
            default:  super.keyDown(with: event)
            }
        }
    }

    private func move(by delta: Int) {
        let row = max(0, min(selectedRow + delta, numberOfRows - 1))
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowToVisible(row)
    }
}

// MARK: - Session cell view

private final class SessionCellView: NSView {
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(row: SessionRow) {
        dot.layer?.backgroundColor = row.dotColor.cgColor
        nameLabel.stringValue = row.session.name
        subtitleLabel.stringValue = row.subtitle
    }
}

// MARK: - New session form

private final class NewSessionFormView: NSView {
    enum State {
        case selectWorkspace
        case selectBranch(workspaceId: UInt)
        case enterName(workspaceId: UInt, branch: String?)
    }

    let nameField = NSTextField()
    private let workspacePopup = NSPopUpButton()
    private let branchPopup = NSPopUpButton()
    private let createButton = NSButton()
    private let backButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var workspaces: [Workspace] = []
    private var branches: [Branch] = []
    private var state: State = .selectWorkspace {
        didSet { updateUI() }
    }

    var onCommit: ((String, UInt, String?) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        nameField.placeholderString = "Session name"
        nameField.font = .systemFont(ofSize: 13)
        nameField.bezelStyle = .roundedBezel
        nameField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameField)

        workspacePopup.translatesAutoresizingMaskIntoConstraints = false
        workspacePopup.addItem(withTitle: "No workspace")
        workspacePopup.target = self
        workspacePopup.action = #selector(workspaceSelected)
        addSubview(workspacePopup)

        branchPopup.translatesAutoresizingMaskIntoConstraints = false
        branchPopup.addItem(withTitle: "Loading branches...")
        branchPopup.target = self
        branchPopup.action = #selector(branchSelected)
        addSubview(branchPopup)

        backButton.title = "← Back"
        backButton.bezelStyle = .inline
        backButton.font = .systemFont(ofSize: 12)
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backButton)

        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(create)
        createButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(createButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            nameField.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameField.widthAnchor.constraint(equalToConstant: 180),

            workspacePopup.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            workspacePopup.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 8),
            workspacePopup.widthAnchor.constraint(equalToConstant: 160),

            branchPopup.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            branchPopup.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 8),
            branchPopup.widthAnchor.constraint(equalToConstant: 160),

            backButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            backButton.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 8),
            backButton.widthAnchor.constraint(equalToConstant: 80),

            createButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            createButton.leadingAnchor.constraint(equalTo: workspacePopup.trailingAnchor, constant: 8),
            createButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        // Async load workspaces (best-effort; picker works without them)
        Task { @MainActor in
            guard let ws = try? await UtenaDaemonClient.shared.fetchWorkspaces() else { return }
            workspaces = ws
            workspacePopup.removeAllItems()
            workspacePopup.addItem(withTitle: "No workspace")
            for w in ws { workspacePopup.addItem(withTitle: w.name) }
        }

        updateUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateUI() {
        switch state {
        case .selectWorkspace:
            statusLabel.stringValue = "Step 1 of 3: Select workspace"
            nameField.isHidden = true
            workspacePopup.isHidden = false
            branchPopup.isHidden = true
            backButton.isHidden = true
            createButton.isHidden = true

        case .selectBranch(let workspaceId):
            statusLabel.stringValue = "Step 2 of 3: Select branch"
            nameField.isHidden = true
            workspacePopup.isHidden = true
            branchPopup.isHidden = false
            backButton.isHidden = false
            createButton.isHidden = true

            // Fetch branches for this workspace
            Task { @MainActor in
                do {
                    let response = try await UtenaDaemonClient.shared.fetchBranches(workspaceId: workspaceId)
                    self.branches = response.branches
                    self.branchPopup.removeAllItems()
                    self.branchPopup.addItem(withTitle: "+ new branch...")
                    for b in response.branches {
                        self.branchPopup.addItem(withTitle: b.name)
                    }
                    if let current = response.currentBranch {
                        if let idx = self.branchPopup.itemTitles.firstIndex(of: current) {
                            self.branchPopup.selectItem(at: idx)
                        }
                    }
                } catch {
                    self.branchPopup.removeAllItems()
                    self.branchPopup.addItem(withTitle: "Error loading branches")
                    DebugLog.log("picker", "fetchBranches failed: \(error)")
                }
            }

        case .enterName:
            statusLabel.stringValue = "Step 3 of 3: Enter session name"
            nameField.isHidden = false
            workspacePopup.isHidden = true
            branchPopup.isHidden = true
            backButton.isHidden = false
            createButton.isHidden = false
            nameField.becomeFirstResponder()
        }
    }

    @objc private func workspaceSelected() {
        let idx = workspacePopup.indexOfSelectedItem
        guard idx > 0, idx - 1 < workspaces.count else {
            return
        }
        state = .selectBranch(workspaceId: workspaces[idx - 1].id)
    }

    @objc private func goBack() {
        switch state {
        case .selectWorkspace:
            return
        case .selectBranch:
            state = .selectWorkspace
            workspacePopup.selectItem(at: 0)
        case .enterName(let workspaceId, _):
            state = .selectBranch(workspaceId: workspaceId)
            branchPopup.selectItem(at: 0)
        }
    }

    @objc private func create() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            nameField.shake()
            return
        }

        guard case .enterName(let workspaceId, let branch) = state else { return }
        onCommit?(name, workspaceId, branch)
    }

    @objc private func branchSelected() {
        guard case .selectBranch(let workspaceId) = state else { return }
        let idx = branchPopup.indexOfSelectedItem

        if idx == 0 {
            // "+ new branch..." selected
            let alert = NSAlert()
            alert.messageText = "Enter branch name"
            alert.informativeText = "Create or checkout a new branch"
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            textField.placeholderString = "Branch name"
            alert.accessoryView = textField
            alert.beginSheetModal(for: window!) { response in
                if response == .alertFirstButtonReturn {
                    let branchName = textField.stringValue.trimmingCharacters(in: .whitespaces)
                    if !branchName.isEmpty {
                        self.state = .enterName(workspaceId: workspaceId, branch: branchName)
                    }
                }
            }
        } else if idx > 0 && idx - 1 < branches.count {
            state = .enterName(workspaceId: workspaceId, branch: branches[idx - 1].name)
        }
    }
}

// MARK: - Shake animation helper

private extension NSView {
    func shake() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.duration = 0.3
        a.values = [-8, 8, -6, 6, -4, 4, 0]
        layer?.add(a, forKey: "shake")
    }
}
