import Foundation

enum FollowUpError: Error {
    case unavailable
    case denied
    case incomplete
    case credentials
    case saveFailed

    var message: String {
        switch self {
        case .unavailable: "This reply is no longer available for follow-up."
        case .denied: "This workspace’s included AI couldn’t start. Check its AI access or allowance."
        case .incomplete: "Aedrova couldn’t finish this reply. Your question is still here."
        case .credentials: "Remove credentials from the question and try again."
        case .saveFailed: "Aedrova replied, but couldn’t save it. Retry saving without another AI request."
        }
    }
}

enum ManagedFollowUp {
    struct Answer: Sendable {
        let id: UUID
        let body: String
        let sourceChannels: [UUID]
    }

    struct Grant: Decodable {
        let id: String
        let token: String
        let model: String
        let baseUrl: String
        let limits: [String: Int]
    }

    struct Response: Decodable {
        struct Item: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let content: [Content]?
        }
        let status: String
        let output: [Item]

        var answer: String {
            output.filter { $0.type == "message" }
                .flatMap { $0.content ?? [] }
                .compactMap { $0.type == "output_text" ? $0.text : nil }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func containsCredentials(_ value: String) -> Bool {
        value.range(of: #"(sb_secret_|sk-(proj-|ant-)|[sr]k_(live|test)_|whsec_|gh[pousr]_)[A-Za-z0-9_-]{20,}|-----BEGIN .*PRIVATE KEY-----"#,
                    options: .regularExpression) != nil
    }

    static func request(_ origin: URL, path: String, token: String, body: [String: Any],
                        using session: URLSession) async throws -> Data {
        var request = URLRequest(url: origin.appending(path: path), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FollowUpError.incomplete }
        if http.statusCode == 429 { throw WorkspaceError.rateLimited(60) }
        guard http.statusCode == 200 else { throw FollowUpError.denied }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512 * 1024 else { throw FollowUpError.incomplete }
            data.append(byte)
        }
        return data
    }

    static func validGrant(_ grant: Grant, origin: URL) -> Bool {
        grant.id.range(of: #"^[A-Za-z0-9_-]{20,100}$"#, options: .regularExpression) != nil
            && grant.token.range(of: #"^[A-Za-z0-9_-]{32,150}$"#, options: .regularExpression) != nil
            && grant.model.range(of: #"^[A-Za-z0-9._:-]{1,100}$"#, options: .regularExpression) != nil
            && grant.baseUrl == origin.absoluteString + "/gateway/codex/v1"
    }
}
