import Foundation
import XCTest
@testable import Synapse

final class SynapseModelConfigurationTests: XCTestCase {
    @MainActor
    func testDefaultNamespaceReadsStoredValuesWithoutRewriting() throws {
        try withDefaults { defaults in
            let stored = [
                "Synapse.judge.provider": "typesafe",
                "Synapse.judge.baseURL": " https://example.test/api ",
                "Synapse.judge.model": " fixture-stored-model ",
                "Synapse.secret.judge": "fixture-stored-key",
                "Galchat.relationship": "fixture-relationship"
            ]
            for (key, value) in stored { defaults.set(value, forKey: key) }
            let configuration = SynapseModelConfiguration(
                id: "judge", apiProtocol: .jevDecisions, defaults: defaults,
                defaultProvider: .openRouter
            )
            XCTAssertEqual(configuration.provider, .typeSafe)
            XCTAssertEqual(configuration.baseURL, "https://example.test/api")
            XCTAssertEqual(configuration.model, "fixture-stored-model")
            XCTAssertEqual(configuration.apiKey, "fixture-stored-key")
            XCTAssertEqual(configuration.snapshot().endpoint, "https://example.test/api/v1/systemone")
            for (key, value) in stored { XCTAssertEqual(defaults.string(forKey: key), value) }
        }
    }

    @MainActor
    func testProviderChangesResetOverridesAndInvalidateCredential() throws {
        try withDefaults { defaults in
            let configuration = SynapseModelConfiguration(
                id: "judge", apiProtocol: .jevDecisions, defaults: defaults,
                namespace: "Synapse", defaultProvider: .openRouter
            )
            XCTAssertEqual(configuration.baseURL, SynapseProvider.openRouter.defaultDecisionsBaseURL)
            XCTAssertEqual(configuration.model, SynapseProvider.openRouter.defaultDecisionsModel)
            configuration.baseURL = "https://override.test"
            configuration.model = "fixture-override"
            configuration.apiKey = "fixture-old"
            configuration.applyProvider(.typeSafe)
            XCTAssertEqual(configuration.provider, .typeSafe)
            XCTAssertEqual(configuration.baseURL, SynapseProvider.typeSafe.defaultDecisionsBaseURL)
            XCTAssertEqual(configuration.model, SynapseProvider.typeSafe.defaultDecisionsModel)
            XCTAssertEqual(configuration.apiKey, "")
            XCTAssertNil(defaults.object(forKey: "Synapse.judge.baseURL"))
            XCTAssertNil(defaults.object(forKey: "Synapse.judge.model"))

            // Even reselecting the current provider restores its defaults.
            configuration.baseURL = "https://api.typesafe.ai/alternate"
            configuration.model = "fixture-override"
            configuration.apiKey = "fixture-current"
            configuration.applyProvider(.typeSafe)
            XCTAssertEqual(configuration.baseURL, SynapseProvider.typeSafe.defaultDecisionsBaseURL)
            XCTAssertEqual(configuration.model, SynapseProvider.typeSafe.defaultDecisionsModel)
            XCTAssertEqual(configuration.apiKey, "fixture-current")

            configuration.baseURL = "https://override.test"
            configuration.apiKey = "fixture-other-origin"
            configuration.applyProvider(.typeSafe)
            XCTAssertEqual(configuration.apiKey, "")

            let sharedOrigin = SynapseModelConfiguration(
                id: "shared", apiProtocol: .jevDecisions, defaults: defaults,
                namespace: "Synapse", defaultProvider: .openRouter,
                defaultBaseURL: "https://shared.test"
            )
            sharedOrigin.apiKey = "fixture-shared"
            let previousEndpoint = sharedOrigin.endpoint
            sharedOrigin.applyProvider(.typeSafe)
            XCTAssertTrue(SynapseModelRoute.hasSameOrigin(previousEndpoint, sharedOrigin.endpoint))
            XCTAssertEqual(sharedOrigin.apiKey, "")
        }
    }

    @MainActor
    func testOriginChangesClearOnlyTheAffectedCredential() throws {
        try withDefaults { defaults in
            let configuration = chatConfiguration(defaults)
            let other = chatConfiguration(defaults, id: "vision")
            other.apiKey = "fixture-other"
            for destination in ["https://other.test/v1", "http://example.test/v1", "https://example.test:444/v1"] {
                configuration.baseURL = "https://example.test/v1"
                configuration.apiKey = "fixture-old"
                configuration.baseURL = destination
                XCTAssertEqual(configuration.apiKey, "", destination)
                XCTAssertEqual(other.apiKey, "fixture-other")
            }
        }
    }

    @MainActor
    func testSameOriginPathModelAndDefaultPortKeepCredential() throws {
        try withDefaults { defaults in
            let configuration = chatConfiguration(defaults)
            configuration.apiKey = "fixture-old"
            configuration.baseURL = "https://EXAMPLE.test:443/alternate/"
            configuration.model = "fixture-new-model"
            XCTAssertEqual(configuration.apiKey, "fixture-old")
            XCTAssertEqual(configuration.endpoint, "https://EXAMPLE.test:443/alternate/chat/completions")
            configuration.baseURL = "http://example.test/v1"
            configuration.apiKey = "fixture-http"
            configuration.baseURL = "http://example.test:80/alternate"
            XCTAssertEqual(configuration.apiKey, "fixture-http")
        }
    }

    @MainActor
    func testSnapshotRemainsUnchangedAfterConfigurationEdits() throws {
        try withDefaults { defaults in
            let configuration = chatConfiguration(defaults)
            configuration.apiKey = "fixture-old"
            let snapshot = configuration.snapshot()
            configuration.save(baseURL: "https://other.test/v2", model: "fixture-new-model", apiKey: "fixture-new")
            XCTAssertEqual(snapshot.provider, .custom)
            XCTAssertEqual(snapshot.apiProtocol, .chatCompletions)
            XCTAssertEqual(snapshot.endpoint, "https://example.test/v1/chat/completions")
            XCTAssertEqual(snapshot.model, "fixture-model")
            XCTAssertEqual(snapshot.apiKey, "fixture-old")
            XCTAssertTrue(snapshot.isConfigured)
            XCTAssertEqual(configuration.snapshot().apiKey, "fixture-new")
        }
    }

    @MainActor
    func testFormSaveDoesNotRestoreStaleKeyButAcceptsReplacement() throws {
        try withDefaults { defaults in
            let configuration = chatConfiguration(defaults)
            configuration.apiKey = "fixture-old"
            configuration.save(baseURL: "https://other.test/v1", model: "fixture-model", apiKey: " fixture-old \n")
            XCTAssertEqual(configuration.apiKey, "")
            XCTAssertFalse(configuration.isConfigured)

            configuration.baseURL = "https://example.test/v1"
            configuration.apiKey = "fixture-old"
            configuration.save(baseURL: "https://other.test/v1", model: "fixture-model", apiKey: " fixture-new \n")
            XCTAssertEqual(configuration.apiKey, "fixture-new")
            XCTAssertTrue(configuration.isConfigured)

            configuration.save(baseURL: "https://other.test:443/alternate", model: "fixture-model", apiKey: "fixture-new")
            XCTAssertEqual(configuration.apiKey, "fixture-new")
        }
    }

    @MainActor
    func testBlankOverridesFallBackAndIncompleteConfigurationIsNotReady() throws {
        try withDefaults { defaults in
            let configuration = chatConfiguration(defaults)
            configuration.baseURL = "https://example.test/alternate"
            configuration.model = "fixture-override"
            configuration.apiKey = "fixture-key"
            configuration.baseURL = " \n "
            configuration.model = " \n "
            XCTAssertEqual(configuration.baseURL, "https://example.test/v1")
            XCTAssertEqual(configuration.model, "fixture-model")
            XCTAssertNil(defaults.object(forKey: "Synapse.reply.baseURL"))
            XCTAssertNil(defaults.object(forKey: "Synapse.reply.model"))
            XCTAssertTrue(configuration.isConfigured)
            configuration.apiKey = " \n "
            XCTAssertFalse(configuration.isConfigured)
            XCTAssertNil(defaults.object(forKey: "Synapse.secret.reply"))

            let empty = SynapseModelConfiguration(
                id: "empty", apiProtocol: .chatCompletions, defaults: defaults, namespace: "Synapse"
            )
            empty.apiKey = "fixture-key"
            XCTAssertEqual(empty.baseURL, "")
            XCTAssertEqual(empty.model, "")
            XCTAssertFalse(empty.isConfigured)
            empty.model = "fixture-model"
            XCTAssertFalse(empty.isConfigured)
            XCTAssertFalse(empty.snapshot().isConfigured)
            empty.baseURL = "https://example.test/v1"
            XCTAssertEqual(empty.apiKey, "")
            empty.apiKey = "fixture-key"
            XCTAssertTrue(empty.isConfigured)
            empty.model = ""
            XCTAssertFalse(empty.isConfigured)
            XCTAssertFalse(empty.snapshot().isConfigured)
        }
    }

    @MainActor
    func testArbitraryBusinessIDsAndNamespacesRemainIsolated() throws {
        try withDefaults { defaults in
            let configuration = chatConfiguration(defaults, id: "summarizer", namespace: "Galchat")
            configuration.save(baseURL: "https://summary.test/v1", model: "fixture-summary", apiKey: "fixture-summary-key")
            let reloaded = chatConfiguration(defaults, id: "summarizer", namespace: "Galchat")
            XCTAssertEqual(reloaded.snapshot(), configuration.snapshot())
            XCTAssertEqual(defaults.string(forKey: "Galchat.summarizer.baseURL"), "https://summary.test/v1")
            XCTAssertEqual(defaults.string(forKey: "Galchat.secret.summarizer"), "fixture-summary-key")
            XCTAssertEqual(chatConfiguration(defaults, id: "summarizer", namespace: "Synapse").apiKey, "")
            XCTAssertEqual(chatConfiguration(defaults, id: "translator", namespace: "Galchat").apiKey, "")
        }
    }

    @MainActor
    private func chatConfiguration(_ defaults: UserDefaults, id: String = "reply", namespace: String = "Synapse") -> SynapseModelConfiguration {
        SynapseModelConfiguration(
            id: id, apiProtocol: .chatCompletions, defaults: defaults, namespace: namespace,
            defaultBaseURL: "https://example.test/v1", defaultModel: "fixture-model"
        )
    }

    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SynapseModelConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
