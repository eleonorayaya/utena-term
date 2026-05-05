import Foundation

struct SessionsResponse: Codable {
    let sessions: [Session]
}

struct Session: Codable, Identifiable {
    let id: UInt
    let name: String
    let status: SessionStatus
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
        status = try c.decode(SessionStatus.self, forKey: .status)
        isAttached = try c.decode(Bool.self, forKey: .isAttached)
        lastUsedAt = try c.decode(Date.self, forKey: .lastUsedAt)
        workspace = try c.decodeIfPresent(Workspace.self, forKey: .workspace)
        gitBranch = try c.decodeIfPresent(Branch.self, forKey: .gitBranch)
        tmuxSession = try c.decodeIfPresent(TmuxSessionInfo.self, forKey: .tmuxSession)
        claudeSessions = try c.decodeIfPresent([ClaudeSession].self, forKey: .claudeSessions) ?? []
    }

    // Derived — not on the wire
    var workspacePath: String? { workspace?.path }
    var branchName: String? { gitBranch?.name }
    var isBranchDirty: Bool { gitBranch?.isDirty ?? false }
    var tmuxSessionName: String? { tmuxSession?.name }
    var windows: [TmuxWindowInfo] { tmuxSession?.windows ?? [] }
    var needsAttention: Bool { claudeSessions.contains { $0.status == .needsAttention } }
    var isClaudeWorking: Bool { claudeSessions.contains { $0.status == .working } }
}

enum SessionStatus: String, Codable {
    case creating, active, broken, deleted, pending, inactive, archived, completed
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
    let status: ClaudeSessionStatus
    let cwd: String
}

enum ClaudeSessionStatus: String, Codable {
    case idle, working, done
    case needsAttention = "needs_attention"
    case readyForReview = "ready_for_review"
}
