import Foundation
import Network
import PhotoStreamShared

final class HTTPServer: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                fputs("PhotoStream listener failed: \(error)\n", stderr)
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInteractive))
        receiveHeader(on: connection, buffer: Data())
    }

    private func receiveHeader(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                fputs("receive error: \(error)\n", stderr)
                return
            }
            var buf = buffer
            if let data { buf.append(data) }

            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
                let remainder = buf.subdata(in: range.upperBound..<buf.endIndex)
                guard let headerText = String(data: headerData, encoding: .utf8),
                      let request = HTTPRequest.parse(headerText: headerText, body: remainder)
                else {
                    self.respond(HTTPResponse(status: 400, body: Data("bad request".utf8)), on: connection)
                    return
                }

                if let length = request.contentLength, remainder.count < length {
                    self.receiveBody(on: connection, request: request, body: remainder, expected: length)
                    return
                }

                Task {
                    let response = await self.handler(request)
                    self.respond(response, on: connection)
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            if buf.count > 1024 * 1024 {
                self.respond(HTTPResponse(status: 413, body: Data("too large".utf8)), on: connection)
                return
            }
            self.receiveHeader(on: connection, buffer: buf)
        }
    }

    private func receiveBody(on connection: NWConnection, request: HTTPRequest, body: Data, expected: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: expected - body.count) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var buf = body
            if let data { buf.append(data) }
            if buf.count >= expected || isComplete {
                var full = request
                full.body = buf.prefix(expected)
                Task {
                    let response = await self.handler(full)
                    self.respond(response, on: connection)
                }
                return
            }
            self.receiveBody(on: connection, request: request, body: buf, expected: expected)
        }
    }

    private func respond(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var contentLength: Int? {
        headers["content-length"].flatMap(Int.init)
    }

    var token: String? {
        headers[PhotoStreamConstants.authHeader.lowercased()]
            ?? headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
    }

    static func parse(headerText: String, body: Data) -> HTTPRequest? {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let rawURL = String(parts[1])
        let urlParts = rawURL.split(separator: "?", maxSplits: 1).map(String.init)
        let path = urlParts[0]
        var query: [String: String] = [:]
        if urlParts.count > 1 {
            for pair in urlParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                } else if kv.count == 1 {
                    query[kv[0]] = ""
                }
            }
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let idx = line.firstIndex(of: ":") {
                let name = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(string.utf8)
        )
    }

    static func jpeg(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [
                "Content-Type": "image/jpeg",
                "Cache-Control": "no-store",
            ],
            body: data
        )
    }

    static func video(_ data: Data, contentType: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [
                "Content-Type": contentType,
                "Cache-Control": "no-store",
            ],
            body: data
        )
    }

    func serialize() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 500: reason = "Internal Server Error"
        default: reason = "OK"
        }
        var headerMap = headers
        headerMap["Content-Length"] = String(body.count)
        headerMap["Connection"] = "close"
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in headerMap {
            text += "\(k): \(v)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}
