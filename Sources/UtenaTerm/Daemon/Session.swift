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
