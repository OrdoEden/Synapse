import Alamofire
import Foundation
import os

/// Stateless protocol gateway. Domain prompts, ranking rules and contact history belong to the caller.
public final class SynapseGateway: Sendable {
    public static let shared = SynapseGateway()
    private let session: Session
    private let log = Logger(subsystem: "Synapse", category: "gateway")

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpAdditionalHeaders = nil
        configuration.httpShouldSetCookies = false
        session = Session(configuration: configuration, interceptor: SynapseBusyRetrier(), redirectHandler: SynapseRedirectHandler())
    }

    // Package tests can inject an ephemeral URLProtocol-backed session without real network access.
    internal init(session: Session) { self.session = session }

    public func decide(state: SynapseJSONValue, questions: [String: SynapseJSONValue], using route: SynapseModelRoute) async throws -> SynapseDecisionsResponse {
        try require(.jevDecisions, route: route)
        guard !questions.isEmpty else { throw SynapseError(detail: "判断请求至少需要一道题目") }
        return try await post(SynapseJSONValue.object([
            "model": .string(route.model), "state": state, "questions": .object(questions)
        ]), route: route)
    }

    public func complete(messages: [SynapseChatMessage], temperature: Double? = nil, using route: SynapseModelRoute) async throws -> SynapseChatCompletionResponse {
        try require(.chatCompletions, route: route)
        guard !messages.isEmpty else { throw SynapseError(detail: "对话请求至少需要一条消息") }
        if let temperature, !temperature.isFinite { throw SynapseError(detail: "temperature 必须是有限数值") }
        let body = ChatRequest(model: route.model, messages: messages, temperature: temperature)
        return try await post(body, route: route)
    }

    private struct ChatRequest: Encodable, Sendable {
        let model: String
        let messages: [SynapseChatMessage]
        let temperature: Double?
    }

    private func require(_ apiProtocol: SynapseAPIProtocol, route: SynapseModelRoute) throws {
        guard route.apiProtocol == apiProtocol else { throw SynapseError(detail: "所选路线与请求协议不匹配") }
    }

    internal static func validatedURL(for route: SynapseModelRoute) throws -> URL {
        guard let url = URL(string: route.endpoint),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw SynapseError(detail: "接口地址必须是有效的 HTTPS 地址，且不能包含用户凭据或片段")
        }
        guard !route.model.isEmpty else { throw SynapseError(detail: "尚未配置模型") }
        guard !route.apiKey.isEmpty else { throw SynapseError(detail: "尚未配置该路线的 API Key") }
        guard route.apiKey.rangeOfCharacter(from: .newlines) == nil else { throw SynapseError(detail: "API Key 不能包含换行") }
        return url
    }

    private func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ body: Body, route: SynapseModelRoute) async throws -> Response {
        try Task.checkCancellation()
        let url = try Self.validatedURL(for: route)
        var headers: HTTPHeaders = ["Authorization": "Bearer \(route.apiKey)", "Content-Type": "application/json"]
        let host = url.host?.lowercased() ?? ""
        if host == "openrouter.ai" || host.hasSuffix(".openrouter.ai") {
            headers.add(name: "X-Title", value: "Synapse")
        }
        let started = Date()
        let response = await session.request(url, method: .post, parameters: body, encoder: .json, headers: headers)
            .validate()
            .serializingDecodable(Response.self, automaticallyCancelling: true, decoder: JSONDecoder())
            .response
        try Task.checkCancellation()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let status = response.response?.statusCode
        switch response.result {
        case .success(let value):
            log.info("request ok status=\(status ?? 0) \(elapsed)ms")
            return value
        case .failure(let error):
            if error.isExplicitlyCancelledError || (error.underlyingError as? URLError)?.code == .cancelled { throw CancellationError() }
            log.warning("request failed status=\(status ?? 0) \(elapsed)ms")
            throw Self.describe(error, status: status)
        }
    }

    /// Neither server body nor localized transport errors are safe UI text: both may echo secrets or chats.
    internal static func describe(_ error: AFError, status: Int?) -> SynapseError {
        if let status, !(200..<300).contains(status) {
            let hint: String
            switch status {
            case 300..<400: hint = "接口重定向被拒绝，请填写最终接口地址"
            case 401, 403: hint = "密钥无效或无权限"
            case 404: hint = "接口地址或模型不存在"
            case 429: hint = "请求过于频繁"
            case 500...599: hint = "模型服务暂时不可用"
            default: hint = "接口拒绝请求，请检查模型与请求参数"
            }
            return SynapseError(status: status, detail: hint)
        }
        if case .responseSerializationFailed = error { return SynapseError(status: status, detail: "响应格式不符合预期，请检查接口协议") }
        if let urlError = error.underlyingError as? URLError {
            let hint: String
            switch urlError.code {
            case .timedOut: hint = "网络超时，请检查连接"
            case .cannotFindHost, .cannotConnectToHost: hint = "无法连接该地址，请检查接口地址"
            case .notConnectedToInternet: hint = "设备当前没有网络"
            case .secureConnectionFailed, .serverCertificateUntrusted: hint = "HTTPS 证书校验失败"
            default: hint = "网络请求失败，请检查连接"
            }
            return SynapseError(status: status, detail: hint)
        }
        return SynapseError(status: status, detail: "请求未完成，请检查配置后重试")
    }
}

internal struct SynapseBusyRetrier: RequestInterceptor {
    func retry(_ request: Request, for session: Session, dueTo error: Error, completion: @escaping @Sendable (RetryResult) -> Void) {
        guard !request.isCancelled, let status = request.response?.statusCode,
              [429, 503, 529].contains(status), request.retryCount < 2 else { completion(.doNotRetry); return }
        let advised = request.response?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let fallback = pow(2, Double(request.retryCount + 1))
        let delay = advised.flatMap { $0.isFinite ? max(0, min($0, 10)) : nil } ?? fallback
        completion(.retryWithDelay(delay))
    }
}

/// Reject cross-origin redirects entirely: stripping Authorization alone still forwards the chat body.
internal struct SynapseRedirectHandler: RedirectHandler {
    func task(_ task: URLSessionTask, willBeRedirectedTo request: URLRequest, for response: HTTPURLResponse, completion: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url?.absoluteString,
              let target = request.url, target.user == nil, target.password == nil,
              SynapseModelRoute.hasSameOrigin(original, target.absoluteString),
              request.httpMethod == task.originalRequest?.httpMethod else { completion(nil); return }
        completion(request)
    }
}
