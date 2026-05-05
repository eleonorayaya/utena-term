import Foundation

actor UtenaDaemonClient {
    static let shared = UtenaDaemonClient()

    private let baseURL = URL(string: "http://localhost:3333")!
    private static let pollInterval: UInt64 = 500_000_000 // 500ms

    let sessions: AsyncStream<[Session]>
    private let continuation: AsyncStream<[Session]>.Continuation
    private var pollingTask: Task<Void, Never>?

    init() {
        var cont: AsyncStream<[Session]>.Continuation!
        sessions = AsyncStream { cont = $0 }
        continuation = cont
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

    private static func fetchSessions(baseURL: URL) async throws -> [Session] {
        let url = baseURL.appendingPathComponent("sessions")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(SessionsResponse.self, from: data).sessions
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            let key = path.last!
            return AnyKey(stringValue: convertKey(key.stringValue))
        }
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(str)"
            )
        }
        return d
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
