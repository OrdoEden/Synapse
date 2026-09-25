import Foundation

public enum SynapseAPIProtocol: String, Sendable {
    case jevDecisions
    case chatCompletions
}

public enum SynapseProvider: String, CaseIterable, Sendable {
    case openRouter = "openrouter"
    case typeSafe = "typesafe"
    case custom

    public var defaultDecisionsBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api"
        case .typeSafe: return "https://api.typesafe.ai"
        case .custom: return ""
        }
    }

    public var defaultDecisionsModel: String {
        switch self {
        case .openRouter: return "typesafe/jev-1.13"
        case .typeSafe: return "jev-latest"
        case .custom: return ""
        }
    }

    /// Custom accepts a complete POST URL; the other providers accept a base URL.
    public func decisionsEndpoint(baseURL: String) -> String {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .custom { return base }
        let suffix = self == .typeSafe ? "/v1/systemone" : "/alpha/decisions"
        return Self.withoutTrailingSlashes(base) + suffix
    }

    public static func chatEndpoint(baseURL: String) -> String {
        withoutTrailingSlashes(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) + "/chat/completions"
    }

    private static func withoutTrailingSlashes(_ string: String) -> String {
        var result = string
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// Immutable request configuration. Never encode or log a route: it owns a credential snapshot.
public struct SynapseModelRoute: Sendable, Equatable {
    public let provider: SynapseProvider
    public let apiProtocol: SynapseAPIProtocol
    public let endpoint: String
    public let model: String
    internal let apiKey: String

    public init(provider: SynapseProvider, apiProtocol: SynapseAPIProtocol, endpoint: String, model: String, apiKey: String) {
        self.provider = provider
        self.apiProtocol = apiProtocol
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool { !endpoint.isEmpty && !model.isEmpty && !apiKey.isEmpty }

    /// Default ports are equivalent; path changes do not change credential ownership.
    public static func hasSameOrigin(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = URL(string: lhs), let right = URL(string: rhs),
              let leftScheme = left.scheme?.lowercased(), let rightScheme = right.scheme?.lowercased(),
              let leftHost = left.host?.lowercased(), let rightHost = right.host?.lowercased() else { return false }
        func port(_ url: URL, _ scheme: String) -> Int? { url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) }
        return leftScheme == rightScheme && leftHost == rightHost && port(left, leftScheme) == port(right, rightScheme)
    }
}

/// UserDefaults storage deliberately preserves the host application's existing BYOK policy.
/// Values are plaintext in the sandbox. This is not a Keychain-backed vault.
@MainActor
public struct SynapseCredentialStore {
    private let defaults: UserDefaults
    private let namespace: String

    /// Keep the legacy default namespace so renaming the package preserves existing credentials.
    public init(defaults: UserDefaults = .standard, namespace: String = "cortex.secret") {
        self.defaults = defaults
        self.namespace = namespace
    }

    public func key(for id: String) -> String { defaults.string(forKey: storageKey(id)) ?? "" }

    public func setKey(_ key: String, for id: String) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { defaults.removeObject(forKey: storageKey(id)) }
        else { defaults.set(value, forKey: storageKey(id)) }
    }

    private func storageKey(_ id: String) -> String { "\(namespace).\(id)" }
}
