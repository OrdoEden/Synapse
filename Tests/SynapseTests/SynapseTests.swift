import Alamofire
import Foundation
import XCTest
@testable import Synapse

final class SynapseTests: XCTestCase {
    func testProviderEndpointsKeepExistingContracts() {
        XCTAssertEqual(SynapseProvider.openRouter.decisionsEndpoint(baseURL: " https://example.test/api/// "), "https://example.test/api/alpha/decisions")
        XCTAssertEqual(SynapseProvider.typeSafe.decisionsEndpoint(baseURL: "https://example.test"), "https://example.test/v1/systemone")
        XCTAssertEqual(SynapseProvider.custom.decisionsEndpoint(baseURL: " https://example.test/exact "), "https://example.test/exact")
        XCTAssertEqual(SynapseProvider.chatEndpoint(baseURL: "https://example.test/v1/"), "https://example.test/v1/chat/completions")
    }

    func testJSONPreservesHeterogeneousCriteria() throws {
        let value: SynapseJSONValue = [
            "choice": ["criteria": ["yes": "Yes", "no": "No"]],
            "score": ["criteria": ["Low", "High"]],
            "flag": .bool(true), "number": .number(0.75), "optional": .null
        ]
        XCTAssertEqual(try JSONDecoder().decode(SynapseJSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testDecisionsKeepNoulScoreLegendAndProbabilities() throws {
        let data = Data(#"{"answers":{"test":{"choice":"yes","confidence":0.8,"noul":0.7,"score":4,"probabilities":{"yes":0.8},"legend":{"0":"low","9":"high"}}}}"#.utf8)
        let answer = try XCTUnwrap(JSONDecoder().decode(SynapseDecisionsResponse.self, from: data).answers["test"])
        XCTAssertEqual(answer.noul, 0.7)
        XCTAssertEqual(answer.score, 4)
        XCTAssertEqual(answer.probabilities?["yes"], 0.8)
        XCTAssertEqual(answer.legend?["9"], "high")
    }

    @MainActor
    func testCredentialNamespaceAndFrozenRoute() throws {
        let suite = "SynapseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fixture-old", forKey: "Synapse.secret.judge")
        let store = SynapseCredentialStore(defaults: defaults)
        let route = makeRoute(apiKey: store.key(for: "judge"))
        XCTAssertTrue(route.isConfigured)
        XCTAssertEqual(store.key(for: "reply"), "")
        store.setKey("fixture-new", for: "judge")
        XCTAssertEqual(route.apiKey, "fixture-old")
        store.setKey(" \n ", for: "judge")
        XCTAssertNil(defaults.object(forKey: "Synapse.secret.judge"))
    }

    func testOriginComparisonDoesNotConfuseHostSuffixOrDefaultPort() {
        XCTAssertTrue(SynapseModelRoute.hasSameOrigin("https://example.test/a", "https://example.test:443/b"))
        XCTAssertFalse(SynapseModelRoute.hasSameOrigin("https://example.test", "https://notexample.test"))
        XCTAssertFalse(SynapseModelRoute.hasSameOrigin("https://example.test", "http://example.test"))
        XCTAssertFalse(SynapseModelRoute.hasSameOrigin("https://example.test", "https://example.test:444"))
    }

    func testRequestValidationRejectsUnsafeTargets() throws {
        for endpoint in ["http://example.test", "https:///", "https://user:password@example.test", "https://example.test/#fragment"] {
            XCTAssertThrowsError(try SynapseGateway.validatedURL(for: makeRoute(endpoint: endpoint)))
        }
        XCTAssertThrowsError(try SynapseGateway.validatedURL(for: makeRoute(apiKey: "")))
        XCTAssertNoThrow(try SynapseGateway.validatedURL(for: makeRoute()))
    }

    func testCrossOriginRedirectDoesNotForwardBodyOrKey() throws {
        var original = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/decisions")))
        original.httpMethod = "POST"
        original.httpBody = Data("private-chat-fixture".utf8)
        original.setValue("Bearer fixture-key", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original) // Never resumed; no network request.
        var redirect = original
        redirect.url = URL(string: "https://elsewhere.test/decisions")
        let response = try XCTUnwrap(HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil))
        var invoked = false
        SynapseRedirectHandler().task(task, willBeRedirectedTo: redirect, for: response) { request in
            invoked = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(invoked)
    }

    func testTransportErrorDoesNotExposeUnderlyingDescription() {
        let underlying = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-chat-and-key"])
        let error = SynapseGateway.describe(.sessionTaskFailed(error: underlying), status: nil)
        XCTAssertFalse(error.localizedDescription.contains("private-chat-and-key"))
        let rejected = SynapseGateway.describe(.responseValidationFailed(reason: .unacceptableStatusCode(code: 401)), status: 401)
        XCTAssertEqual(rejected.status, 401)
        XCTAssertEqual(rejected.detail, "密钥无效或无权限")
    }

    private func makeRoute(endpoint: String = "https://example.test/decisions", apiKey: String = "fixture-key") -> SynapseModelRoute {
        SynapseModelRoute(provider: .custom, apiProtocol: .jevDecisions, endpoint: endpoint, model: "fixture-model", apiKey: apiKey)
    }
}
