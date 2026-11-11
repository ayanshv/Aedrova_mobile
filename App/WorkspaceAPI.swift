import AuthenticationServices
import CryptoKit
import Foundation

struct Workspace: Decodable, Identifiable {
    let id: UUID
    let name: String
}

struct Conversation: Decodable, Identifiable {
    let id: UUID
    let name: String
    let kind: String
    let dmLow: UUID?
    let dmHigh: UUID?

    var isDirect: Bool { kind == "dm" || kind == "group_dm" }

    func title(user: UUID, people: [UUID: String]) -> String {
        guard kind == "dm" else { return name }
        return (dmLow == user ? dmHigh : dmLow).flatMap { people[$0] } ?? "Direct conversation"
    }
}

struct Person: Decodable {
    let workspaceId: UUID
    let userId: UUID
    let displayName: String
}

struct Message: Decodable, Identifiable {
    let id: UUID
    let senderId: UUID
    let body: String
    let createdAt: String
    let unsentAt: String?
}

struct AgentReply: Decodable, Identifiable {
    let id: UUID
    let agentName: String
    let body: String
    let createdAt: String
}

enum WorkspaceError: Error {
    case configuration, signIn, response, status(Int)

    var message: String {
        switch self {
        case .configuration: "Staging configuration is unavailable."
        case .signIn, .status(401): "Your session ended. Sign in again."
        case .status(403): "You don’t have access to this conversation."
        case .status(429): "Too many requests. Try again in a moment."
        default: "Couldn’t reach Aedrova. Try again."
        }
    }
}

actor WorkspaceAPI {
    struct Configuration: Decodable {
        let url: URL
        let key: String

        static func staging() -> Self? {
            #if DEBUG
            guard let file = Bundle.main.url(forResource: "Staging", withExtension: "json"),
                  let data = try? Data(contentsOf: file),
                  let config = try? JSONDecoder().decode(Self.self, from: data),
                  config.url.absoluteString == "https://scvmvqlzcqhwrrsiahpj.supabase.co",
                  config.key.hasPrefix("sb_publishable_") else { return nil }
            return config
            #else
            return nil
            #endif
        }
    }

    struct Session: Decodable {
        struct User: Decodable { let id: UUID }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: User
    }

    struct OAuthRequest {
        let url: URL
        let verifier: String
    }

    static let callback = URL(string: "com.aedrova.mobile://auth/callback")!
    private let configuration: Configuration?
    private let transport: URLSession
    private var session: Session?
    private var expiry = Date.distantPast
    private var renewal: Task<String, Error>?
    private var sessionGeneration = 0

    init(configuration: Configuration? = Configuration.staging()) {
        self.configuration = configuration
        let options = URLSessionConfiguration.ephemeral
        options.urlCache = nil
        options.timeoutIntervalForRequest = 15
        transport = URLSession(configuration: options, delegate: NoRedirect(), delegateQueue: nil)
    }

    func authorization(provider: String) throws -> OAuthRequest {
        guard let configuration, ["google", "apple"].contains(provider) else {
            throw WorkspaceError.configuration
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkspaceError.response
        }
        let verifier = Self.base64URL(Data(bytes))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: configuration.url.appending(path: "auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "provider", value: provider),
            .init(name: "redirect_to", value: Self.callback.absoluteString),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "s256")
        ]
        guard let url = components.url else { throw WorkspaceError.configuration }
        return OAuthRequest(url: url, verifier: verifier)
    }

    func exchange(_ callback: URL, verifier: String) async throws -> UUID {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == Self.callback.scheme, parts.host == Self.callback.host,
              parts.path == Self.callback.path, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { throw WorkspaceError.signIn }
        let result = try await token(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier])
        sessionGeneration += 1
        store(result)
        return result.user.id
    }

    func signOut() async throws {
        let token = session?.accessToken
        sessionGeneration += 1
        renewal?.cancel()
        renewal = nil
        session = nil
        expiry = .distantPast
        guard let token else { return }
        _ = try await request("auth/v1/logout", query: [.init(name: "scope", value: "local")],
                              method: "POST", bearer: token)
    }

    func workspaces() async throws -> [Workspace] {
        try await rpc("list_my_workspaces", body: ["p_archived": false])
    }

    func directory() async throws -> [Person] {
        try await rpc("team_directory", body: [:])
    }

    func conversations(workspace: UUID) async throws -> [Conversation] {
        try await read("channels", query: [
            .init(name: "workspace_id", value: "eq.\(workspace.uuidString)"),
            .init(name: "select", value: "id,name,kind,dm_low,dm_high"),
            .init(name: "order", value: "name.asc,id.asc")
        ])
    }

    func messages(conversation: UUID) async throws -> [Message] {
        try await rpc("message_page", body: ["p_channel": conversation.uuidString, "p_limit": 60])
    }

    func replies(workspace: UUID, conversation: UUID) async throws -> [AgentReply] {
        do {
            return try await read("my_agent_replies", query: [
                .init(name: "workspace_id", value: "eq.\(workspace.uuidString)"),
                .init(name: "channel_id", value: "eq.\(conversation.uuidString)"),
                .init(name: "parent_id", value: "is.null"),
                .init(name: "select", value: "id,agent_name,body,created_at"),
                .init(name: "order", value: "created_at.desc,id.asc"),
                .init(name: "limit", value: "60")
            ])
        } catch WorkspaceError.status(404) {
            return []
        }
    }

    func send(id: UUID, conversation: UUID, body: String) async throws {
        let _: UUID = try await rpc("send_message", body: [
            "p_id": id.uuidString, "p_channel": conversation.uuidString, "p_body": body
        ])
    }

    private func rpc<T: Decodable>(_ name: String, body: [String: Any]) async throws -> T {
        let bearer = try await accessToken()
        let data = try await request("rest/v1/rpc/\(name)", method: "POST",
                                     bearer: bearer, body: JSONSerialization.data(withJSONObject: body))
        return try decode(data)
    }

    private func read<T: Decodable>(_ table: String, query: [URLQueryItem]) async throws -> T {
        let bearer = try await accessToken()
        return try await decode(request("rest/v1/\(table)", query: query, bearer: bearer))
    }

    private func accessToken() async throws -> String {
        guard let session else { throw WorkspaceError.signIn }
        if expiry > Date().addingTimeInterval(30) { return session.accessToken }
        if let renewal { return try await renewal.value }
        let generation = sessionGeneration
        let operation = Task { try await self.renew(session, generation: generation) }
        renewal = operation
        defer { if sessionGeneration == generation { renewal = nil } }
        return try await operation.value
    }

    private func renew(_ previous: Session, generation: Int) async throws -> String {
        let next = try await token(grant: "refresh_token", body: ["refresh_token": previous.refreshToken])
        guard sessionGeneration == generation, next.user.id == previous.user.id else {
            throw WorkspaceError.signIn
        }
        store(next)
        return next.accessToken
    }

    private func token(grant: String, body: [String: String]) async throws -> Session {
        let data = try await request("auth/v1/token", query: [.init(name: "grant_type", value: grant)],
                                     method: "POST", body: JSONEncoder().encode(body))
        return try decode(data)
    }

    private func store(_ value: Session) {
        session = value
        expiry = Date().addingTimeInterval(value.expiresIn)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                         bearer: String? = nil, body: Data? = nil) async throws -> Data {
        guard let configuration else { throw WorkspaceError.configuration }
        var components = URLComponents(url: configuration.url.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(configuration.key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkspaceError.response }
        guard (200..<300).contains(http.statusCode) else { throw WorkspaceError.status(http.statusCode) }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
