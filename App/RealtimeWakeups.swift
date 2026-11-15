import Foundation

enum RealtimeWakeups {
    struct Connection: Sendable {
        let socket: URLSessionWebSocketTask
        let user: UUID
        let token: String
    }

    private actor State {
        private let clock = ContinuousClock()
        private var acknowledged: ContinuousClock.Instant?
        private(set) var joined = false

        func confirmJoin() {
            joined = true
            acknowledged = clock.now
        }

        func confirmHeartbeat() { acknowledged = clock.now }

        func check() throws {
            guard let acknowledged, acknowledged.duration(to: clock.now) < .seconds(25) else {
                throw WorkspaceError.response
            }
        }
    }

    static func listen(_ connection: Connection, renew: @escaping @Sendable () async throws -> String,
                       wake: @escaping @MainActor @Sendable () -> Void) async throws {
        let socket = connection.socket
        let topic = "realtime:user:" + connection.user.uuidString.lowercased()
        let state = State()

        try await withTaskCancellationHandler {
            defer { socket.cancel(with: .goingAway, reason: nil) }
            socket.resume()
            try await send(socket, topic: topic, event: "phx_join", ref: "join", joinRef: "join",
                           payload: [
                            "access_token": connection.token,
                            "config": ["private": true, "broadcast": ["ack": false, "self": false],
                                       "presence": ["enabled": false], "postgres_changes": []]
                           ])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let packet = try await socket.receive()
                        guard case .string(let text) = packet, text.utf8.count <= 8192,
                              let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                              let event = frame["event"] as? String else { continue }
                        let target = frame["topic"] as? String
                        let payload = frame["payload"] as? [String: Any]
                        if target == topic && ["phx_error", "phx_close"].contains(event) {
                            throw WorkspaceError.response
                        }
                        if event == "phx_reply", target == topic, frame["ref"] as? String == "join" {
                            guard payload?["status"] as? String == "ok" else { throw WorkspaceError.response }
                            await state.confirmJoin()
                            await wake()
                        } else if event == "phx_reply", target == "phoenix", payload?["status"] as? String == "ok" {
                            await state.confirmHeartbeat()
                        } else if target == topic, event == "broadcast", payload?["event"] as? String == "refresh",
                                  await state.joined {
                            await wake()
                        }
                    }
                }
                group.addTask {
                    var token = connection.token
                    var ref = 0
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(10))
                        try await state.check()
                        ref += 1
                        try await send(socket, topic: "phoenix", event: "heartbeat", ref: "h\(ref)")
                        let next = try await renew()
                        if next != token {
                            try await send(socket, topic: topic, event: "access_token", ref: "a\(ref)",
                                           joinRef: "join", payload: ["access_token": next])
                            token = next
                        }
                    }
                }
                defer {
                    group.cancelAll()
                    socket.cancel(with: .goingAway, reason: nil)
                }
                try await group.next()
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func send(_ socket: URLSessionWebSocketTask, topic: String, event: String, ref: String,
                             joinRef: String? = nil, payload: [String: Any] = [:]) async throws {
        var frame: [String: Any] = ["topic": topic, "event": event, "ref": ref, "payload": payload]
        frame["join_ref"] = joinRef
        let data = try JSONSerialization.data(withJSONObject: frame)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
