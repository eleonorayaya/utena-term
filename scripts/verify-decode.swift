// Standalone verification: decode saved sessions.json with the same logic
// the daemon client uses, and print a short summary of each session.
//
// Usage: swift scripts/verify-decode.swift <path-to-sessions.json>

import Foundation

// MARK: - Models (mirror Sources/UtenaTerm/Daemon/Session.swift)

struct SessionsResponse: Codable { let sessions: [Session] }

struct Session: Codable {
    let id: UInt
    let name: String
    let status: String
    let isAttached: Bool
    let lastUsedAt: Date
    let workspace: Workspace?
    let gitBranch: Branch?
    let tmuxSession: TmuxSessionInfo?
    let claudeSessions: [ClaudeSession]

    private enum CodingKeys: String, CodingKey {
        case id, name, status, isAttached, lastUsedAt
        case workspace, gitBranch, tmuxSession, claudeSessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        isAttached = try c.decode(Bool.self, forKey: .isAttached)
        lastUsedAt = try c.decode(Date.self, forKey: .lastUsedAt)
        workspace = try c.decodeIfPresent(Workspace.self, forKey: .workspace)
        gitBranch = try c.decodeIfPresent(Branch.self, forKey: .gitBranch)
        tmuxSession = try c.decodeIfPresent(TmuxSessionInfo.self, forKey: .tmuxSession)
        claudeSessions = try c.decodeIfPresent([ClaudeSession].self, forKey: .claudeSessions) ?? []
    }
}

struct Workspace: Codable {
    let id: UInt
    let name: String
    let path: String
    let isGitRepo: Bool
}

struct Branch: Codable {
    let id: UInt
    let name: String
    let isDirty: Bool
    let existsLocal: Bool
    let existsRemote: Bool
}

struct TmuxSessionInfo: Codable {
    let id: UInt
    let name: String
    let startDir: String
    let isAlive: Bool
    let windows: [TmuxWindowInfo]

    private enum CodingKeys: String, CodingKey {
        case id, name, startDir, isAlive, windows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        startDir = try c.decode(String.self, forKey: .startDir)
        isAlive = try c.decode(Bool.self, forKey: .isAlive)
        windows = try c.decodeIfPresent([TmuxWindowInfo].self, forKey: .windows) ?? []
    }
}

struct TmuxWindowInfo: Codable {
    let index: Int
    let name: String
    let active: Bool
}

struct ClaudeSession: Codable {
    let id: UInt
    let claudeSessionId: String
    let sessionId: UInt
    let status: String
    let cwd: String
}

// MARK: - Decoder (mirror UtenaDaemonClient.decoder)

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { return nil }
}

private func convertKey(_ str: String) -> String {
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

let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .custom { path in
        AnyKey(stringValue: convertKey(path.last!.stringValue))
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

// MARK: - Run

let path = CommandLine.arguments.dropFirst().first ?? "sessions.json"
let data = try Data(contentsOf: URL(fileURLWithPath: path))
let response = try decoder.decode(SessionsResponse.self, from: data)

print("Decoded \(response.sessions.count) sessions:")
for s in response.sessions.prefix(5) {
    let branch = s.gitBranch?.name ?? "—"
    let tmux = s.tmuxSession?.name ?? "—"
    let claudeStatuses = s.claudeSessions.map(\.status).joined(separator: ",")
    print("  #\(s.id) \(s.name) [\(s.status)] branch=\(branch) tmux=\(tmux) claude=[\(claudeStatuses)] attached=\(s.isAttached)")
}
if response.sessions.count > 5 {
    print("  … and \(response.sessions.count - 5) more")
}
