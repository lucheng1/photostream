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
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            handleHeaderBuffer(buffer, headerEnd: range, on: connection)
            return
        }
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
                self.handleHeaderBuffer(buf, headerEnd: range, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            if buf.count > 1024 * 1024 {
                self.finish(
                    HTTPResponse(status: 413, body: Data("too large".utf8)),
                    on: connection,
                    keepAlive: false,
                    leftover: Data()
                )
                return
            }
            self.receiveHeader(on: connection, buffer: buf)
        }
    }

    private func handleHeaderBuffer(
        _ buf: Data,
        headerEnd range: Range<Data.Index>,
        on connection: NWConnection
    ) {
        let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
        let remainder = buf.subdata(in: range.upperBound..<buf.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8),
              var request = HTTPRequest.parse(headerText: headerText, body: Data())
        else {
            finish(
                HTTPResponse(status: 400, body: Data("bad request".utf8)),
                on: connection,
                keepAlive: false,
                leftover: Data()
            )
            return
        }

        let contentLength = request.contentLength ?? 0
        if contentLength > 0 {
            if remainder.count < contentLength {
                receiveBody(
                    on: connection,
                    request: request,
                    body: remainder,
                    expected: contentLength,
                    keepAliveHint: request.wantsKeepAlive
                )
                return
            }
            request.body = remainder.prefix(contentLength)
            let leftover = remainder.count > contentLength
                ? Data(remainder.dropFirst(contentLength))
                : Data()
            dispatch(request, on: connection, leftover: leftover)
            return
        }

        // No body (typical GET/HEAD). Remainder is the start of the next pipelined request.
        dispatch(request, on: connection, leftover: remainder)
    }

    private func receiveBody(
        on connection: NWConnection,
        request: HTTPRequest,
        body: Data,
        expected: Int,
        keepAliveHint: Bool
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, expected - body.count)) { [weak self] data, _, isComplete, error in
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
                let leftover = buf.count > expected ? Data(buf.dropFirst(expected)) : Data()
                self.dispatch(full, on: connection, leftover: leftover)
                return
            }
            self.receiveBody(
                on: connection,
                request: request,
                body: buf,
                expected: expected,
                keepAliveHint: keepAliveHint
            )
        }
    }

    private func dispatch(_ request: HTTPRequest, on connection: NWConnection, leftover: Data) {
        Task {
            let response = await self.handler(request)
            let keepAlive = request.wantsKeepAlive
            self.finish(response, on: connection, keepAlive: keepAlive, leftover: leftover)
        }
    }

    private func finish(
        _ response: HTTPResponse,
        on connection: NWConnection,
        keepAlive: Bool,
        leftover: Data
    ) {
        connection.send(
            content: response.serialize(keepAlive: keepAlive),
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                if keepAlive {
                    self.receiveHeader(on: connection, buffer: leftover)
                } else {
                    connection.cancel()
                }
            }
        )
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
            ?? query["token"]
    }

    var rangeHeader: String? {
        headers["range"]
    }

    /// HTTP/1.1 defaults to keep-alive unless the client asks to close.
    var wantsKeepAlive: Bool {
        let value = headers["connection"]?.lowercased() ?? "keep-alive"
        return !value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("close")
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
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-store",
            ],
            body: data
        )
    }

    func serialize(keepAlive: Bool = false) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 416: reason = "Range Not Satisfiable"
        case 500: reason = "Internal Server Error"
        default: reason = "OK"
        }
        var headerMap = headers
        if headerMap["Content-Length"] == nil {
            headerMap["Content-Length"] = String(body.count)
        }
        if keepAlive {
            headerMap["Connection"] = "keep-alive"
            headerMap["Keep-Alive"] = "timeout=60, max=1000"
        } else {
            headerMap["Connection"] = "close"
        }
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
