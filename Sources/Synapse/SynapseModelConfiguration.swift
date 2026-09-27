import Foundation

/// Persisted settings for one host-defined model purpose. Does not own application features or prompts.
@MainActor
public final class SynapseModelConfiguration {
    public let id: String
    public let apiProtocol: SynapseAPIProtocol

    private let defaults: UserDefaults
    private let namespace: String
    private let credentials: SynapseCredentialStore
    private let defaultProvider: SynapseProvider
    private let defaultBaseURL: String?
    private let defaultModel: String?

    /// Defaults to `Synapse.<id>.provider/baseURL/model` and `Synapse.secret.<id>`.
    /// Initialization only reads existing settings; it does not rewrite or migrate them.
    /// Nil base/model defaults use the provider's defaults for Jev, and empty strings for Chat Completions.
    public init(
        id: String,
        apiProtocol: SynapseAPIProtocol,
        defaults: UserDefaults = .standard,
        namespace: String = "Synapse",
        defaultProvider: SynapseProvider = .custom,
        defaultBaseURL: String? = nil,
        defaultModel: String? = nil
    ) {
        self.id = id
        self.apiProtocol = apiProtocol
        self.defaults = defaults
        self.namespace = namespace
        self.credentials = SynapseCredentialStore(defaults: defaults, namespace: "\(namespace).secret")
        self.defaultProvider = defaultProvider
        self.defaultBaseURL = defaultBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultModel = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var provider: SynapseProvider {
        defaults.string(forKey: storageKey("provider")).flatMap(SynapseProvider.init(rawValue:)) ?? defaultProvider
    }

    public var baseURL: String {
        get {
            trimmedString("baseURL") ?? defaultBaseURL
                ?? (apiProtocol == .jevDecisions ? provider.defaultDecisionsBaseURL : "")
        }
        set {
            let previous = endpoint
            setTrimmed(newValue, field: "baseURL")
            clearCredentialIfOriginChanged(from: previous)
        }
    }

    public var model: String {
        get {
            trimmedString("model") ?? defaultModel
                ?? (apiProtocol == .jevDecisions ? provider.defaultDecisionsModel : "")
        }
        set { setTrimmed(newValue, field: "model") }
    }

    /// Uses the configuration namespace's credential store. Never log this value.
    public var apiKey: String {
        get { credentials.key(for: id) }
        set { credentials.setKey(newValue, for: id) }
    }

    public var endpoint: String {
        guard !baseURL.isEmpty else { return "" }
        switch apiProtocol {
        case .jevDecisions: return provider.decisionsEndpoint(baseURL: baseURL)
        case .chatCompletions: return SynapseProvider.chatEndpoint(baseURL: baseURL)
        }
    }

    /// Checks required values only. Request URL validation and connectivity are handled by the gateway.
    public var isConfigured: Bool { snapshot().isConfigured }

    /// Resets address/model overrides, even when reselecting the current provider.
    /// Changing provider always invalidates the credential; resetting to a different origin does too.
    public func applyProvider(_ provider: SynapseProvider) {
        let previous = endpoint
        if provider != self.provider { apiKey = "" }
        defaults.set(provider.rawValue, forKey: storageKey("provider"))
        defaults.removeObject(forKey: storageKey("baseURL"))
        defaults.removeObject(forKey: storageKey("model"))
        clearCredentialIfOriginChanged(from: previous)
    }

    /// Saves an edited form without rebinding its unchanged old key to a new origin.
    /// A different submitted key is accepted; callers should refresh their key field after saving.
    public func save(baseURL: String, model: String, apiKey: String) {
        let previousKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.model = model
        let submittedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !previousKey.isEmpty, self.apiKey.isEmpty, submittedKey == previousKey { return }
        self.apiKey = submittedKey
    }

    /// Capture once at the start of a business operation and reuse for its in-flight requests.
    public func snapshot() -> SynapseModelRoute {
        SynapseModelRoute(provider: provider, apiProtocol: apiProtocol,
                          endpoint: endpoint, model: model, apiKey: apiKey)
    }

    private func clearCredentialIfOriginChanged(from previous: String) {
        let current = endpoint
        if previous != current && !SynapseModelRoute.hasSameOrigin(previous, current) {
            apiKey = ""
        }
    }

    private func storageKey(_ field: String) -> String { "\(namespace).\(id).\(field)" }

    private func trimmedString(_ field: String) -> String? {
        guard let raw = defaults.string(forKey: storageKey(field)) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func setTrimmed(_ value: String, field: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { defaults.removeObject(forKey: storageKey(field)) }
        else { defaults.set(value, forKey: storageKey(field)) }
    }
}
