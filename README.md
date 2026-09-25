# Synapse

独立 Swift Package，单模块负责 BYOK 凭据、服务商/模型路由、Jev Decisions 与 Chat Completions 协议转发。依赖 Alamofire **5.11.1**；最低 iOS 15 / macOS 12。与 Visyn、SeeU、Realm 和宿主业务无依赖。

Synapse 自身使用 Swift 5.9 包清单；当前 Alamofire 5.11.1 依赖的清单要求 Swift 6.2，因此完整依赖图需要 Swift 6.2 工具链。这沿用主工程已锁定的 Alamofire 版本。

Synapse manifest 使用 Swift tools 5.9；现有锁定的 Alamofire 5.11.1 自身 manifest 要求 Swift tools 6.2，因此完整依赖图需要 Swift 6.2 工具链。这是当前工程既有依赖要求，本次未升级 Alamofire。

```swift
import Synapse

// 在 MainActor 中读取配置；一轮业务只生成一次快照。
let credentials = SynapseCredentialStore(namespace: "myapp.models")
let route = SynapseModelRoute(
    provider: .openRouter,
    apiProtocol: .jevDecisions,
    endpoint: SynapseProvider.openRouter.decisionsEndpoint(baseURL: "https://openrouter.ai/api"),
    model: "typesafe/jev-1.13",
    apiKey: credentials.key(for: "judge")
)
let response = try await SynapseGateway.shared.decide(
    state: ["text": "需要判断的内容"],
    questions: ["is_question": ["type": "noul", "instructions": "Is the text a question?",
                                "criteria": ["true": "A question", "false": "Not a question"]]],
    using: route
)
```

## 边界与协议

- `decide(state:questions:using:)` 编码 `model/state/questions`，保留响应中的 `choice/confidence/noul/score/probabilities/legend`。题目内容、情绪解释和排序规则由 App 构造。
- `complete(messages:temperature:using:)` 编码非流式 Chat Completions；消息 content 支持 JSON 文本或多模态数组，响应目前读取字符串正文。不包含流式、工具调用或任意厂商参数；需要这些能力时显式扩展契约。
- OpenRouter 自动追加 `/alpha/decisions`，TypeSafe 追加 `/v1/systemone`；custom 判断路线接受完整 POST 地址。聊天路线在 base URL 后追加 `/chat/completions`。
- `SynapseModelRoute` 是 `Sendable` 不可变快照；凭据只在模块内部可读，不提供 Codable 导出。业务在启动时冻结生成/排序的各路线，再复用同一快照。不要打印或反射快照。

## 凭据与兼容

`SynapseCredentialStore` 明确使用 **UserDefaults**，值是沙盒 plist 中的明文，会受设备备份影响；它不宣称提供 Keychain 加密。保留现有用户指定策略，本次不迁移到 Keychain。

库默认 namespace 继续使用 `cortex.secret`，保证从旧名称升级后仍可读取已有密钥。

宿主传入 namespace 和 route ID。当前 App 使用 namespace `jarvis.secret` 和 `judge/reply/vision`，因此兼容已有配置，无数据库迁移。App 的配置桥在切换判断服务商或请求 origin 时清空对应密钥；同 origin 路径/模型修改保留。没有跨路线密钥回退。

## 网络行为

- 只接受带主机的 HTTPS 地址，拒绝 URL 用户凭据和片段；请求前检查模型与密钥。
- 拒绝跨 origin 重定向，避免聊天正文与凭据被转发；同 origin 也不接受把 POST 改为 GET 的重定向。
- 不回显服务端错误 body、URL 或原始网络错误；日志仅状态和耗时。
- 请求超时 30 秒，资源超时 90 秒；传播任务取消。保留既有 429/503/529 最多两次重试策略，数值 Retry-After 限制为 0...10 秒；其他状态与网络超时不自动重试。忙碌响应不保证上游未处理请求，调用方仍需了解服务商计费语义。

## 验证

`Tests/SynapseTests` 覆盖异构协议 JSON、Jev 字段保留、旧 key namespace、路由隔离/冻结、端点与 origin、重定向拒绝、错误脱敏。按照项目 iOS 工作约定，本次仅编写并静态检查测试，未构建、运行测试、解析依赖或请求真实模型。

请在 Xcode 打开 Package 后运行测试，并在 App 真机确认现有设置读取、服务商/域名切换、取消请求、慢网络与生成后排序流程。Realm、联系人、人设和情绪分析继续归宿主业务层。
