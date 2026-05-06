import Foundation

struct SessionsResponse: Codable, Equatable {
    let sessions: [Session]
}

struct Session: Codable, Identifiable, Equatable {
    let id: UInt
    let name: String
    let status: SessionStatus
    let isAttached: Bool
    let lastUsedAt: Date
    let workspace: Workspace?
    let gitBranch: GitBranch?
    let tmuxSession: TmuxSessionInfo?
    let claudeSessions: [ClaudeSession]
    let statusError: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, status, isAttached, lastUsedAt
        case workspace, gitBranch, tmuxSession, claudeSessions, statusError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(SessionStatus.self, forKey: .status)
        isAttached = try c.decode(Bool.self, forKey: .isAttached)
        lastUsedAt = try c.decode(Date.self, forKey: .lastUsedAt)
        workspace = try c.decodeIfPresent(Workspace.self, forKey: .workspace)
        gitBranch = try c.decodeIfPresent(GitBranch.self, forKey: .gitBranch)
        tmuxSession = try c.decodeIfPresent(TmuxSessionInfo.self, forKey: .tmuxSession)
        claudeSessions = try c.decodeIfPresent([ClaudeSession].self, forKey: .claudeSessions) ?? []
        statusError = try c.decodeIfPresent(String.self, forKey: .statusError)
    }

    // Derived — not on the wire
    var workspacePath: String? { workspace?.path }
    var branchName: String? { gitBranch?.name }
    var isBranchDirty: Bool { gitBranch?.isDirty ?? false }
    var tmuxSessionName: String? { tmuxSession?.name }
    var windows: [TmuxWindowInfo] { tmuxSession?.windows ?? [] }
    var needsAttention: Bool { claudeSessions.contains { $0.status == .needsAttention } }
    var isClaudeWorking: Bool { claudeSessions.contains { $0.status == .working } }

    /// Highest-priority Claude session status in this priority order:
    /// needs_attention > working > ready_for_review > done > idle
    var aggregatedClaudeStatus: ClaudeSessionStatus? {
        let priority: [ClaudeSessionStatus: Int] = [
            .needsAttention: 0,
            .working: 1,
            .readyForReview: 2,
            .done: 3,
            .idle: 4,
        ]
        return claudeSessions
            .min { lhs, rhs in
                (priority[lhs.status] ?? 99) < (priority[rhs.status] ?? 99)
            }
            .map { $0.status }
    }
}

enum SessionStatus: String, Codable {
    case creating, active, broken, deleted, pending, inactive, archived, completed
}

struct Workspace: Codable, Equatable {
    let id: UInt
    let name: String
    let path: String
    let isGitRepo: Bool
}

struct GitBranch: Codable, Equatable {
    let id: UInt
    let name: String
    let isDirty: Bool
    let existsLocal: Bool
    let existsRemote: Bool
}

struct TmuxSessionInfo: Codable, Equatable {
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

struct TmuxWindowInfo: Codable, Equatable {
    let index: Int
    let name: String
    let active: Bool
}

struct ClaudeSession: Codable, Equatable {
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

struct WorkspacesResponse: Codable, Equatable {
    let workspaces: [Workspace]
}
