import Foundation
import Network
import DiMyMintHTTP

enum LocalHTTPServerError: Error {
    case invalidBindHost(String)
    case unsupportedMethod(String)
    case malformedRequest
}

struct LocalHTTPRequest: Sendable {
    let method: MintHTTPMethod
    let path: String
    let headers: [String: String]
    let body: Data
}

struct LocalHTTPResponse: Sendable {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: Data

    static func json(statusCode: Int = 200, body: Data) -> Self {
        Self(
            statusCode: statusCode,
            reasonPhrase: statusCode == 200 ? "OK" : "Error",
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(body.count)"
            ],
            body: body
        )
    }

    static func error(statusCode: Int, message: String) -> Self {
        let body = Data("{\"error\":\"\(message)\"}".utf8)
        return Self(
            statusCode: statusCode,
            reasonPhrase: "Error",
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(body.count)"
            ],
            body: body
        )
    }

    func encoded() -> Data {
        var lines = ["HTTP/1.1 \(statusCode) \(reasonPhrase)"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        lines.append("")
        let headerData = Data(lines.joined(separator: "\r\n").utf8) + Data("\r\n".utf8)
        return headerData + body
    }
}

final class LocalHTTPServer {
    private let configuration: DiMyMintServerConfiguration
    private let router: MintHTTPRouter
    private var listener: NWListener?

    init(configuration: DiMyMintServerConfiguration, router: MintHTTPRouter) {
        self.configuration = configuration
        self.router = router
    }

    func start() async throws {
        let host = NWEndpoint.Host(configuration.host)
        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .http
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .global(qos: .userInitiated))
            self.receiveRequest(on: connection)
        }

        listener.start(queue: .global(qos: .userInitiated))
        print("DiMyMintServer listening on http://\(host):\(configuration.port)")
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.respond(LocalHTTPResponse.error(statusCode: 500, message: "receive_failed:\(error)"), on: connection)
                return
            }
            guard let data, !data.isEmpty else {
                self.respond(LocalHTTPResponse.error(statusCode: 400, message: "empty_request"), on: connection)
                return
            }

            Task {
                let response: LocalHTTPResponse
                do {
                    let request = try self.parseRequest(data)
                    response = try await self.dispatch(request)
                } catch LocalHTTPServerError.unsupportedMethod(let method) {
                    response = .error(statusCode: 405, message: "unsupported_method:\(method)")
                } catch {
                    response = .error(statusCode: 400, message: "\(error)")
                }
                self.respond(response, on: connection, complete: isComplete)
            }
        }
    }

    private func dispatch(_ request: LocalHTTPRequest) async throws -> LocalHTTPResponse {
        guard let resolved = await router.resolve(method: request.method, path: request.path) else {
            return .error(statusCode: 404, message: "route_not_found")
        }

        let context = MintHTTPRequestContext(
            body: request.body,
            headers: request.headers,
            pathParameters: resolved.pathParameters
        )

        do {
            let data = try await router.handle(route: resolved.route, context: context)
            return .json(body: data)
        } catch {
            return .error(statusCode: 400, message: "\(error)")
        }
    }

    private func respond(_ response: LocalHTTPResponse, on connection: NWConnection, complete: Bool = true) {
        connection.send(content: response.encoded(), completion: .contentProcessed { _ in
            if complete {
                connection.cancel()
            }
        })
    }

    private func parseRequest(_ data: Data) throws -> LocalHTTPRequest {
        guard let requestText = String(data: data, encoding: .utf8),
              let separatorRange = requestText.range(of: "\r\n\r\n") else {
            throw LocalHTTPServerError.malformedRequest
        }

        let headerText = String(requestText[..<separatorRange.lowerBound])
        let bodyText = String(requestText[separatorRange.upperBound...])
        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            throw LocalHTTPServerError.malformedRequest
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            throw LocalHTTPServerError.malformedRequest
        }

        let methodString = String(requestParts[0]).uppercased()
        guard let method = MintHTTPMethod(rawValue: methodString) else {
            throw LocalHTTPServerError.unsupportedMethod(methodString)
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return LocalHTTPRequest(
            method: method,
            path: String(requestParts[1]),
            headers: headers,
            body: Data(bodyText.utf8)
        )
    }
}
