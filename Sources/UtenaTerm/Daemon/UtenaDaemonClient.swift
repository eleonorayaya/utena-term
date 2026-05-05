import Foundation

actor UtenaDaemonClient {
    static let shared = UtenaDaemonClient()

    private let baseURL = URL(string: "http://localhost:3333")!
    private static let pollInterval: UInt64 = 500_000_000 // 500ms

    let sessions: AsyncStream<[Session]>
    private let continuation: AsyncStream<[Session]>.Continuation
    private var pollingTask: Task<Void, Never>?

    init() {
        // Bound the buffer to one snapshot — a slow consumer should see the
        // latest state, not a backlog of stale ~290KB payloads.
        (sessions, continuation) = AsyncStream<[Session]>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start() {
        pollingTask?.cancel()
        let continuation = self.continuation
        let baseURL = self.baseURL
        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    let result = try await Self.fetchSessions(baseURL: baseURL)
                    continuation.yield(result)
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

    func fetchOnce() async throws -> [Session] {
        try await Self.fetchSessions(baseURL: baseURL)
    }

    func fetchWorkspaces() async throws -> [Workspace] {
        let url = baseURL.appendingPathComponent("workspaces")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try Self.decoder.decode(WorkspacesResponse.self, from: data).workspaces
    }

    func createSession(name: String, workspaceId: UInt) async throws -> Session {
        let url = baseURL.appendingPathComponent("sessions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(CreateSessionRequest(name: name, workspaceId: workspaceId))
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

    private static func fetchSessions(baseURL: URL) async throws -> [Session] {
        let url = baseURL.appendingPathComponent("sessions")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(SessionsResponse.self, from: data).sessions
    }

    private static let decoder: JSONDecoder = {
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
    let name: String
    let workspaceId: UInt

    enum CodingKeys: String, CodingKey {
        case name
        case workspaceId = "workspace_id"
    }
}
