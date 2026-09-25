import Foundation

/// JSON payloads preserve Jev's heterogeneous choice/noul/score criteria.
public enum SynapseJSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([SynapseJSONValue]), object([String: SynapseJSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([SynapseJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: SynapseJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension SynapseJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension SynapseJSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: SynapseJSONValue...) { self = .array(elements) }
}
extension SynapseJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, SynapseJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public struct SynapseDecisionsResponse: Decodable, Sendable {
    public let answers: [String: Answer]

    public struct Answer: Decodable, Sendable {
        public let choice: String?
        public let confidence: Double?
        public let noul: Double?
        public let score: Double?
        public let probabilities: [String: Double]?
        public let legend: [String: String]?
    }
}

public struct SynapseChatMessage: Encodable, Sendable {
    public let role: String
    public let content: SynapseJSONValue

    /// JSON content supports both text and provider-supported multimodal content arrays.
    public init(role: String, content: SynapseJSONValue) {
        self.role = role
        self.content = content
    }
}

public struct SynapseChatCompletionResponse: Decodable, Sendable {
    public let choices: [Choice]
    public struct Choice: Decodable, Sendable {
        public let message: Message
    }
    public struct Message: Decodable, Sendable {
        public let content: String?
    }
    public var firstContent: String { choices.first?.message.content ?? "" }
}

public struct SynapseError: LocalizedError, Sendable {
    public let status: Int?
    public let detail: String
    public var errorDescription: String? {
        status.map { "HTTP \($0)：\(detail)" } ?? detail
    }

    internal init(status: Int? = nil, detail: String) {
        self.status = status
        self.detail = detail
    }
}
