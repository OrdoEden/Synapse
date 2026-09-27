import Foundation

/// Chat Completions 多模态内容（OpenAI 兼容格式），供识图路线发送"文字 + 图片"。
public struct SynapseImageInput: Sendable, Equatable {
    public enum Detail: String, Sendable {
        case low, high, auto
    }

    public let data: Data
    public let mimeType: String
    public let detail: Detail

    public init(data: Data, mimeType: String = "image/jpeg", detail: Detail = .low) {
        self.data = data
        self.mimeType = mimeType
        self.detail = detail
    }

    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

extension SynapseChatMessage {
    /// 一条用户消息：先文字、后图片，图片以 base64 data URL 内联，不经第三方存储。
    /// 调用方负责控制图片尺寸（建议最长边 ≤ 512）以限制请求体积与费用。
    public static func user(text: String, images: [SynapseImageInput]) -> SynapseChatMessage {
        var parts: [SynapseJSONValue] = [["type": "text", "text": .string(text)]]
        for image in images {
            parts.append([
                "type": "image_url",
                "image_url": ["url": .string(image.dataURL), "detail": .string(image.detail.rawValue)]
            ])
        }
        return SynapseChatMessage(role: "user", content: .array(parts))
    }

    public static func system(_ text: String) -> SynapseChatMessage {
        SynapseChatMessage(role: "system", content: .string(text))
    }
}
