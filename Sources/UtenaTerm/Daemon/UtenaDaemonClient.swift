import Foundation

extension Notification.Name {
    /// Posted on the main queue after each successful daemon poll.
    /// `userInfo["sessions"]` contains the latest `[Session]` snapshot.
    static let utenaSessionsDidUpdate = Notification.Name("utenaSessionsDidUpdate")
}

// MARK: - Branch list response

// Note: Branch is defined in Session.swift. We redeclare it here for decoding
// the branch list response since it doesn't include the 'id' field.
//
// The daemon currently returns branches as plain strings (just the name).
// Decode from either form so we tolerate the structured shape too if the
// daemon ever switches to it.
struct BranchInfo: Decodable, Equatable {
    let name: String
    let existsLocal: Bool
    let existsRemote: Bool
    let isDirty: Bool

    init(name: String, existsLocal: Bool = false, existsRemote: Bool = false, isDirty: Bool = false) {
        self.name = name
        self.existsLocal = existsLocal
        self.existsRemote = existsRemote
        self.isDirty = isDirty
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let s = try? single.decode(String.self) {
            self.init(name: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            existsLocal: try c.decodeIfPresent(Bool.self, forKey: .existsLocal) ?? false,
            existsRemote: try c.decodeIfPresent(Bool.self, forKey: .existsRemote) ?? false,
            isDirty: try c.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        )
    }

    enum CodingKeys: String, CodingKey {
        case name
        case existsLocal = "exists_local"
        case existsRemote = "exists_remote"
        case isDirty = "is_dirty"
    }
}

struct BranchListResponse: Decodable {
    let branches: [BranchInfo]
    let currentBranch: String?

    enum CodingKeys: String, CodingKey {
        case branches
        case currentBranch = "current_branch"
    }
}

// MARK: - Create-session input

/// All parameters needed to create a new session. Single source of truth for
/// the picker → launcher/tmux → daemon-client chain (otherwise this 5-tuple
/// shows up in three Outcome.create / TmuxLaunch.create / createSession
/// signatures).
struct CreateSessionInput: Equatable {
    let name: String
    let workspaceId: UInt
    let branch: String?
    let baseBranch: String?
    let createWorktree: Bool
}

// MARK: - Client

actor UtenaDaemonClient {
    static let shared = UtenaDaemonClient()

    let baseURL = URL(string: "http://localhost:3333")!
    private static let pollInterval: UInt64 = 500_000_000 // 500ms

    private(set) var cachedSessions: [Session] = []
    private var pollingTask: Task<Void, Never>?

    init() {}

    func start() {
        pollingTask?.cancel()
        let baseURL = self.baseURL
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await Self.fetchSessions(baseURL: baseURL)
                    await self?.publish(result)
                } catch {
                    // Daemon may not be running yet; keep polling silently.
                }
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func publish(_ sessions: [Session]) {
        guard sessions != cachedSessions else { return }
        cachedSessions = sessions
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .utenaSessionsDidUpdate,
                object: nil,
                userInfo: ["sessions": sessions]
            )
        }
    }

    func fetchOnce() async throws -> [Session] {
        try await Self.fetchSessions(baseURL: baseURL)
    }

    func fetchWorkspaces() async throws -> [Workspace] {
        try await get("workspaces", as: WorkspacesResponse.self).workspaces
    }

    func addWorkspace(path: String, asRoot: Bool = false) async throws -> Workspace {
        let url = baseURL.appendingPathComponent("workspaces")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["path": path, "as_root": asRoot] as [String: Any]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(Workspace.self, from: data)
    }

    func deleteWorkspace(id: UInt) async throws {
        let url = baseURL.appendingPathComponent("workspaces/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func setWorkspaceHidden(id: UInt, hidden: Bool) async throws {
        let url = baseURL.appendingPathComponent("workspaces/\(id)/hidden")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["hidden": hidden])
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func fetchBranches(workspaceId: UInt) async throws -> BranchListResponse {
        try await get("workspaces/\(workspaceId)/branches", as: BranchListResponse.self)
    }

    func createSession(_ input: CreateSessionInput) async throws -> Session {
        let url = baseURL.appendingPathComponent("sessions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(CreateSessionRequest(input: input))
        let (data, _) = try await URLSession.shared.data(for: req)
        var created = try Self.decoder.decode(Session.self, from: data)
        for _ in 0 ..< 20 {
            if created.status == .active { return created }
            try await Task.sleep(nanoseconds: 500_000_000)
            let sessions = try await Self.fetchSessions(baseURL: baseURL)
            if let updated = sessions.first(where: { $0.id == created.id }) { created = updated }
        }
        return created
    }

    func deleteSession(id: UInt) async throws {
        let url = baseURL.appendingPathComponent("sessions/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func repairSession(id: UInt) async throws {
        let url = baseURL.appendingPathComponent("sessions/\(id)/repair")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func archiveSession(id: UInt) async throws {
        let url = baseURL.appendingPathComponent("sessions/\(id)/archive")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        let (data, _) = try await URLSession.shared.data(from: url)
        return try Self.decoder.decode(T.self, from: data)
    }

    private static func fetchSessions(baseURL: URL) async throws -> [Session] {
        let url = baseURL.appendingPathComponent("sessions")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(SessionsResponse.self, from: data).sessions
    }

    static let encoder = JSONEncoder()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            AnyKey(stringValue: convertKey(path.last!.stringValue))
        }
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = iso8601Fractional.date(from: str) { return date }
            if let date = iso8601Plain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(str)"
            )
        }
        return d
    }()

    // ISO8601DateFormatter is heavy to construct (and we parse ~1400 dates per
    // tick), so cache one per format-options shape. Both are read-only after
    // setup and ISO8601DateFormatter.date(from:) is documented thread-safe.
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Convert utena daemon JSON keys to Swift camelCase. The daemon mixes
    /// GORM's embedded-Model PascalCase fields (`ID`, `CreatedAt`, …) with
    /// snake_case for everything else, so neither built-in strategy alone
    /// covers the full response.
    private static func convertKey(_ str: String) -> String {
        switch str {
        case "ID": return "id"
        case "CreatedAt": return "createdAt"
        case "UpdatedAt": return "updatedAt"
        case "DeletedAt": return "deletedAt"
        default: break
        }
        guard str.contains("_") else { return str }
        let parts = str.split(separator: "_")
        let head = String(parts[0])
        let tail = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return head + tail
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { return nil }
}

private struct CreateSessionRequest: Encodable {
    let input: CreateSessionInput

    enum CodingKeys: String, CodingKey {
        case name
        case workspaceId = "workspace_id"
        case branch
        case baseBranch = "base_branch"
        case createWorktree = "create_worktree"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input.name, forKey: .name)
        try container.encode(input.workspaceId, forKey: .workspaceId)
        try container.encodeIfPresent(input.branch, forKey: .branch)
        try container.encodeIfPresent(input.baseBranch, forKey: .baseBranch)
        try container.encode(input.createWorktree, forKey: .createWorktree)
    }
}
