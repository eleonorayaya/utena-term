import Foundation

// MARK: - Pull Request Models

struct PullRequest: Decodable, Equatable {
    let number: Int
    let title: String
    let state: String   // "open", "draft", "closed", "merged"
    let htmlURL: String
    let authorLogin: String
    let isAssignedToMe: Bool

    enum CodingKeys: String, CodingKey {
        case number, title, state
        case htmlURL = "html_url"
        case authorLogin = "author_login"
        case isAssignedToMe = "is_assigned_to_me"
    }
}

struct PullRequestListResponse: Decodable {
    let pullRequests: [PullRequest]

    enum CodingKeys: String, CodingKey {
        case pullRequests = "pull_requests"
    }
}

// MARK: - PR Fetch

extension UtenaDaemonClient {
    func fetchPullRequests(workspaceId: UInt, state: String? = nil) async throws -> [PullRequest] {
        var components = URLComponents(string: "\(baseURL)/workspaces/\(workspaceId)/prs")!
        if let state { components.queryItems = [URLQueryItem(name: "state", value: state)] }
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        let resp = try Self.decoder.decode(PullRequestListResponse.self, from: data)
        return resp.pullRequests
    }
}
