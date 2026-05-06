import Foundation

extension Notification.Name {
    /// Posted on the main queue after each successful daemon poll.
    /// `userInfo["sessions"]` contains the latest `[Session]` snapshot.
    static let utenaSessionsDidUpdate = Notification.Name("utenaSessionsDidUpdate")
}

actor UtenaDaemonClient {
    static let shared = UtenaDaemonClient()

    private let baseURL = URL(string: "http://localhost:3333")!
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

    func createSession(name: String, workspaceId: UInt) async throws -> Session {
        let url = baseURL.appendingPathComponent("sessions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(CreateSessionRequest(name: name, workspaceId: workspaceId))
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

    private static let encoder = JSONEncoder()

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
