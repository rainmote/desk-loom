import Foundation
import Network

final class RPCServer {
    private let listener: NWListener
    private let token: String
    private let queue = DispatchQueue(label: "local.computeruse.rpc")
    private let handler: @MainActor (String, [String: Any]) async throws -> [String: Any]

    init(token: String, handler: @escaping @MainActor (String, [String: Any]) async throws -> [String: Any]) throws {
        self.token = token
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    func start(ready: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port?.rawValue { ready(port) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
            self.queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var accumulated = data
            if let chunk { accumulated.append(chunk) }
            guard accumulated.count <= 1_048_576 else {
                self.send(connection, status: 413, object: ["ok": false, "error": ["code": "request-too-large", "message": "Request exceeds 1 MiB"]]); return
            }
            if let delimiter = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: accumulated[..<delimiter.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                guard lines.first == "POST /rpc HTTP/1.1" else {
                    self.send(connection, status: 404, object: ["ok": false]); return
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                guard headers["authorization"] == "Bearer \(self.token)" else {
                    self.send(connection, status: 401, object: ["ok": false, "error": ["code": "unauthorized", "message": "Local session token required"]]); return
                }
                guard let length = Int(headers["content-length"] ?? ""), length >= 0, length < 1_000_000 else {
                    self.send(connection, status: 400, object: ["ok": false]); return
                }
                let body = accumulated[delimiter.upperBound...]
                if body.count >= length {
                    do {
                        let value = try JSONSerialization.jsonObject(with: Data(body.prefix(length))) as? [String: Any]
                        guard let method = value?["method"] as? String else { throw NSError(domain: "rpc", code: 400) }
                        let params = value?["params"] as? [String: Any] ?? [:]
                        Task { @MainActor in
                            do {
                                let result = try await self.handler(method, params)
                                self.send(connection, status: 200, object: ["ok": true, "result": result])
                            } catch let failure as DesktopFailure {
                                self.send(connection, status: 200, object: ["ok": false, "error": ["code": failure.code, "message": failure.message]])
                            } catch {
                                self.send(connection, status: 200, object: ["ok": false, "error": ["code": "internal-error", "message": error.localizedDescription]])
                            }
                        }
                    } catch { self.send(connection, status: 400, object: ["ok": false]) }
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { self.receive(connection, data: accumulated) }
        }
    }

    private func send(_ connection: NWConnection, status: Int, object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
