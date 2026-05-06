import AppKit

protocol SessionChromeDelegate: AnyObject {
    var sessionName: String { get }
    var orderedWindowIDs: [String] { get }
    var activeWindowID: String? { get }
    func selectWindow(id: String)
}

final class SessionChrome: NSView {
    let windowTabRow = WindowTabRow()
    let statusline = Statusline()

    weak var delegate: SessionChromeDelegate?
    private var sessionsObserver: NSObjectProtocol?

    /// Top inset reserved for the macOS title-bar / traffic-light controls.
    /// Set to ~28pt when the parent window uses `.fullSizeContentView` so
    /// pane content doesn't render under the buttons; 0 with a normal title
    /// bar.
    init(contentView: NSView, topInset: CGFloat = 0) {
        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        windowTabRow.translatesAutoresizingMaskIntoConstraints = false
        statusline.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentView)
        addSubview(windowTabRow)
        addSubview(statusline)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: windowTabRow.topAnchor),

            windowTabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            windowTabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            windowTabRow.bottomAnchor.constraint(equalTo: statusline.topAnchor),
            windowTabRow.heightAnchor.constraint(equalToConstant: 22),

            statusline.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusline.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusline.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusline.heightAnchor.constraint(equalToConstant: 26),
        ])

        windowTabRow.onSelectWindow = { [weak self] id in
            self?.delegate?.selectWindow(id: id)
        }

        sessionsObserver = NotificationCenter.default.addObserver(
            forName: .utenaSessionsDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessions = note.userInfo?["sessions"] as? [Session] else { return }
            self?.update(from: sessions)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let sessionsObserver { NotificationCenter.default.removeObserver(sessionsObserver) }
    }

    func windowsDidChange() {
        guard let d = delegate else { return }
        windowTabRow.windowIDs = d.orderedWindowIDs
        windowTabRow.activeID = d.activeWindowID
    }

    func sessionDidChange(to name: String) {
        statusline.sessionName = name
        windowsDidChange()
    }

    private func update(from sessions: [Session]) {
        let name = statusline.sessionName
        let current = sessions.first { $0.name == name || $0.tmuxSession?.name == name }
        statusline.branchName = current?.branchName
        statusline.attentionNames = sessions
            .filter { $0.needsAttention && $0.name != name && $0.tmuxSession?.name != name }
            .map { $0.name }
    }
}
