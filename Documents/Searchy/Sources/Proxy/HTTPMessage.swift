import Foundation

nonisolated struct HTTPHeader: Hashable, Sendable {
    var name: String
    var value: String
}

/// Placeholder shown in the raw editor in place of a body that isn't valid text.
nonisolated let binaryBodyMarker = "[binary body kept as-is: "

nonisolated protocol HTTPMessageLike {
    var headers: [HTTPHeader] { get set }
    var body: Data { get set }
}

nonisolated extension HTTPMessageLike {
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    mutating func setHeader(_ name: String, _ value: String) {
        if let i = headers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            headers[i].value = value
        } else {
            headers.append(HTTPHeader(name: name, value: value))
        }
    }

    mutating func removeHeader(_ name: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var contentType: String { header("Content-Type") ?? "" }

    var bodyText: String? { body.isEmpty ? "" : String(data: body, encoding: .utf8) }

    fileprivate func rawBody() -> String {
        if let t = bodyText { return t }
        return "\(binaryBodyMarker)\(body.count) bytes]"
    }

    fileprivate var headerBlock: String { headers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n") }
}

nonisolated struct HTTPRequestMessage: HTTPMessageLike, Sendable {
    var method: String
    var target: String
    var version = "HTTP/1.1"
    var headers: [HTTPHeader]
    var body = Data()

    /// Editable text form, like Burp's "Raw" tab.
    var rawText: String {
        var s = "\(method) \(target) \(version)\r\n"
        if !headers.isEmpty { s += headerBlock + "\r\n" }
        s += "\r\n" + rawBody()
        return s
    }

    /// Bytes as they go on the wire (origin form).
    func wireData() -> Data {
        var d = Data("\(method) \(target) \(version)\r\n".utf8)
        for h in headers { d.append(Data("\(h.name): \(h.value)\r\n".utf8)) }
        d.append(Data("\r\n".utf8))
        d.append(body)
        return d
    }

    static func parse(rawText: String, originalBody: Data = Data()) -> HTTPRequestMessage? {
        guard let (start, headers, bodyText) = splitRaw(rawText) else { return nil }
        let parts = start.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        var m = HTTPRequestMessage(method: parts[0].uppercased(), target: parts[1], version: parts.count > 2 ? parts[2] : "HTTP/1.1", headers: headers)
        m.body = bodyText.hasPrefix(binaryBodyMarker) ? originalBody : Data(bodyText.utf8)
        if m.header("Content-Length") != nil || !m.body.isEmpty { m.setHeader("Content-Length", String(m.body.count)) }
        return m
    }
}

nonisolated struct HTTPResponseMessage: HTTPMessageLike, Sendable {
    var version = "HTTP/1.1"
    var status: Int
    var reason: String
    var headers: [HTTPHeader]
    var body = Data()

    var rawText: String {
        var s = "\(version) \(status) \(reason)\r\n"
        if !headers.isEmpty { s += headerBlock + "\r\n" }
        s += "\r\n" + rawBody()
        return s
    }

    static func parse(rawText: String, originalBody: Data = Data()) -> HTTPResponseMessage? {
        guard let (start, headers, bodyText) = splitRaw(rawText) else { return nil }
        let parts = start.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var m = HTTPResponseMessage(version: parts[0], status: status, reason: parts.count > 2 ? parts[2] : "", headers: headers)
        m.body = bodyText.hasPrefix(binaryBodyMarker) ? originalBody : Data(bodyText.utf8)
        return m
    }
}

/// Splits "start line / headers / blank line / body", tolerating bare \n line endings from the editor.
private nonisolated func splitRaw(_ raw: String) -> (String, [HTTPHeader], String)? {
    let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
    let halves = text.components(separatedBy: "\n\n")
    let head = halves[0]
    let body = halves.dropFirst().joined(separator: "\n\n")
    var lines = head.components(separatedBy: "\n")
    guard !lines.isEmpty, !lines[0].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let start = lines.removeFirst()
    var headers: [HTTPHeader] = []
    for line in lines where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers.append(HTTPHeader(name: String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                  value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
    }
    return (start, headers, body)
}

// MARK: - Wire parsing

nonisolated enum HTTPWire {
    static let crlfcrlf = Data("\r\n\r\n".utf8)

    /// Returns the index just past the header terminator, if the buffer contains a full head.
    static func headEnd(in data: Data) -> Int? {
        data.range(of: crlfcrlf).map { $0.upperBound }
    }

    static func parseHead(_ head: Data) -> (start: String, headers: [HTTPHeader])? {
        guard let text = String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let start = lines.removeFirst()
        let headers = lines.compactMap { line -> HTTPHeader? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return HTTPHeader(name: String(line[..<colon]),
                              value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return (start, headers)
    }

    /// Decodes a chunked body that has been fully buffered; returns nil if incomplete.
    static func decodeChunked(_ data: Data) -> (body: Data, consumed: Int)? {
        var out = Data()
        var i = data.startIndex
        while true {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: i..<data.endIndex) else { return nil }
            let sizeText = String(data: data[i..<lineEnd.lowerBound], encoding: .ascii)?
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else { return nil }
            i = lineEnd.upperBound
            if size == 0 {
                // Optional trailers, then the final CRLF.
                if let end = data.range(of: Data("\r\n".utf8), in: i..<data.endIndex) {
                    if end.lowerBound == i { return (out, end.upperBound - data.startIndex) }
                    guard let tail = data.range(of: HTTPWire.crlfcrlf, in: (i - 2)..<data.endIndex) else { return nil }
                    return (out, tail.upperBound - data.startIndex)
                }
                return nil
            }
            guard data.distance(from: i, to: data.endIndex) >= size + 2 else { return nil }
            out.append(data[i..<data.index(i, offsetBy: size)])
            i = data.index(i, offsetBy: size + 2)
        }
    }

    static func reasonPhrase(_ status: Int) -> String { HTTPURLResponse.localizedString(forStatusCode: status).capitalized }
}
