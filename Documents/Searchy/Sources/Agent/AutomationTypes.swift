import Foundation

// MARK: - JSON

/// A Sendable JSON value, used for tool arguments/schemas and MCP messages.
nonisolated enum JSONValue: Sendable, Equatable, Codable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                            ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }

    /// From the output of `JSONSerialization` (or any Foundation property-list-ish value).
    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let v as Bool where type(of: v) == Bool.self && !(value is NSNumber && CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID()):
            self = .bool(v)
        case let v as NSNumber:
            self = CFGetTypeID(v) == CFBooleanGetTypeID() ? .bool(v.boolValue) : .number(v.doubleValue)
        case let v as String: self = .string(v)
        case let v as [Any?]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any?]: self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as JSONValue: self = v
        default: self = .string("\(value!)")
        }
    }

    /// For `JSONSerialization`.
    var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(\.foundationObject)
        case .object(let o): o.mapValues(\.foundationObject)
        }
    }

    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: obj)
    }

    static func parse(data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: obj)
    }

    func encoded(pretty: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.sortedKeys, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: foundationObject, options: options) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int? { doubleValue.map { Int($0) } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Tools (what an AI can do in the browser)

/// One capability exposed to an AI: Claude Code over MCP, the in-browser assistant, or a local model.
nonisolated struct ToolSpec: Sendable, Identifiable {
    var name: String
    var description: String
    /// JSON Schema (`{"type":"object","properties":{…},"required":[…]}`).
    var inputSchema: JSONValue
    /// True when the tool only observes (never changes a page).
    var readOnly = false
    var id: String { name }
}

nonisolated enum ToolContent: Sendable {
    case text(String)
    case image(png: Data)
}

nonisolated struct ToolResult: Sendable {
    var content: [ToolContent]
    var isError = false

    static func text(_ s: String) -> ToolResult { ToolResult(content: [.text(s)]) }
    static func error(_ s: String) -> ToolResult { ToolResult(content: [.text(s)], isError: true) }
    static func image(_ png: Data, caption: String? = nil) -> ToolResult {
        ToolResult(content: (caption.map { [ToolContent.text($0)] } ?? []) + [.image(png: png)])
    }

    /// All text parts joined, for logs and for models that can't see images.
    var plainText: String {
        content.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
}

/// Runs a tool by name. Implemented once (`BrowserAutomation`) and shared by every AI front end.
typealias ToolExecutor = @Sendable (_ name: String, _ arguments: JSONValue) async -> ToolResult

// MARK: - Agent runtime (the in-browser assistant)

nonisolated enum AgentEvent: Sendable {
    case status(String)                                              // "Thinking…", "Reading the page…"
    case textDelta(String)                                           // streamed assistant text
    case text(String)                                                // a complete assistant message
    case toolCall(id: String, name: String, arguments: JSONValue)
    case toolResult(id: String, name: String, summary: String, isError: Bool)
    case finished(String?)
    case failed(String)
}

nonisolated struct ChatTurn: Sendable {
    enum Role: String, Sendable { case user, assistant }
    var role: Role
    var text: String
}

nonisolated struct AgentRequest: Sendable {
    var goal: String
    var history: [ChatTurn] = []
    var currentURL: String?
    var currentTitle: String?
    /// Models that can't see images shouldn't be offered the screenshot tool.
    var allowScreenshots = true
    var maxSteps = 25
}

/// A "brain" that decides which tools to call. Implementations: Apple Intelligence (on-device / Private Cloud Compute),
/// Claude Code (the `claude` CLI), the Claude API, and any OpenAI-compatible server (Ollama, LM Studio, …).
@MainActor
protocol AgentBrain: AnyObject {
    var id: String { get }
    var title: String { get }
    /// nil when ready, otherwise why it can't run (shown in the UI).
    var unavailableReason: String? { get }
    func run(_ request: AgentRequest, tools: [ToolSpec], execute: @escaping ToolExecutor,
             emit: @escaping @MainActor (AgentEvent) -> Void) async throws
}
