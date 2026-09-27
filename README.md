# Synapse

独立 Swift Package，单模块负责 BYOK 模型配置与凭据存取、服务商切换、请求快照、Jev Decisions 与 Chat Completions 协议转发。依赖 Alamofire **5.11.1**；最低 iOS 15 / macOS 12。与 Visyn、SeeU、Realm 和宿主业务无依赖。

Synapse 自身使用 Swift 5.9 包清单；当前 Alamofire 5.11.1 依赖的清单要求 Swift 6.2，因此完整依赖图需要 Swift 6.2 工具链。这沿用主工程已锁定的 Alamofire 版本。

Synapse manifest 使用 Swift tools 5.9；现有锁定的 Alamofire 5.11.1 自身 manifest 要求 Swift tools 6.2，因此完整依赖图需要 Swift 6.2 工具链。这是当前工程既有依赖要求，本次未升级 Alamofire。

```swift
import Synapse

// 在 MainActor 中创建/编辑配置；id 的业务含义由宿主决定。
let configuration = SynapseModelConfiguration(
    id: "classification",
    apiProtocol: .jevDecisions,
    namespace: "Synapse",
    defaultProvider: .openRouter
)
// 设置页通过 save(baseURL:model:apiKey:) 保存用户输入后，一轮业务只生成一次快照。
let route = configuration.snapshot()
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

## 配置与凭据命名

`SynapseCredentialStore` 明确使用 **UserDefaults**，值是沙盒 plist 中的明文，会受设备备份影响；它不宣称提供 Keychain 加密。保留现有用户指定策略，本次不迁移到 Keychain。

`SynapseModelConfiguration` 默认使用 `Synapse` 命名空间，底层 `SynapseCredentialStore` 默认使用 `Synapse.secret`，两者读取同一用途的密钥。

`SynapseModelConfiguration` 在 MainActor 管理一个用途的配置。宿主传入任意 `id`、通信协议和默认值，也可显式指定自己的命名空间。配置键为 `<namespace>.<id>.provider/baseURL/model`，密钥键为 `<namespace>.secret.<id>`。Galchat 的 `judge/reply/vision` 使用 `Synapse` 命名空间；关系描述、视觉开关等 App 设置使用 `Galchat.*`。

本次直接切换前缀，不迁移、回退读取或删除其他前缀下的旧数据。升级后需重新填写模型配置和密钥；初始化仍不会改写存储值。

- `provider` 只读；`applyProvider(_:)` 切换服务商并清除地址/模型覆盖值。服务商改变总会清除密钥；重选当前服务商也重置覆盖值，但仅在 origin 改变时清除密钥。
- `baseURL`、`model`、`apiKey` 可读写。空白地址/模型移除覆盖值、恢复默认；空白密钥删除存储值。Jev 未指定默认地址/模型时使用当前服务商的默认值，Chat Completions 由宿主提供默认值或用户填写。
- 更换地址的协议、主机或有效端口时清除该用途的密钥；同 origin 的路径/模型修改保留密钥，没有跨用途回退。
- 编辑表单调用 `save(baseURL:model:apiKey:)`：如果更换 origin 且提交的仍是原密钥，保持清空；同时填写的不同新密钥可以保存。保存及切换服务商后，界面应重新读取 `apiKey` 更新输入框。单独设置 `apiKey` 表示明确为当前服务设置凭据。
- `snapshot()` 返回不可变的 `SynapseModelRoute`，后续编辑不会改变已生成的请求快照。`isConfigured` 仅检查必要值是否非空，网关继续负责 HTTPS、URL 等校验；它不表示连通性测试成功。

产品默认模型、用途名称、关系描述、上下文条数、截图容量和界面通知由宿主管理。请求 JSON 直接使用 `SynapseJSONValue`；库不要求宿主保留旧类型别名。

## 网络行为

- 只接受带主机的 HTTPS 地址，拒绝 URL 用户凭据和片段；请求前检查模型与密钥。
- 拒绝跨 origin 重定向，避免聊天正文与凭据被转发；同 origin 也不接受把 POST 改为 GET 的重定向。
- 不回显服务端错误 body、URL 或原始网络错误；日志仅状态和耗时。
- 请求超时 30 秒，资源超时 90 秒；传播任务取消。保留既有 429/503/529 最多两次重试策略，数值 Retry-After 限制为 0...10 秒；其他状态与网络超时不自动重试。忙碌响应不保证上游未处理请求，调用方仍需了解服务商计费语义。

## 验证

`Tests/SynapseTests` 覆盖异构协议 JSON、Jev 字段保留、库默认配置/密钥命名空间、读取不改写存储值、服务商重置、origin 变化、表单旧密钥回填保护、用途隔离、空值回退、请求快照冻结、重定向拒绝及错误脱敏。按照项目 iOS 工作约定，本次仅编写并静态检查测试，未构建、运行测试、解析依赖或请求真实模型。

请在 Xcode 打开 Package 后运行测试，并在 App 真机确认新前缀下的配置保存与重新读取、服务商/域名切换、取消请求、慢网络与生成后排序流程。Realm、联系人、人设和情绪分析继续归宿主业务层。
