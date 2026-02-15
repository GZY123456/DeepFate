import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var text: String
    /// 发往 API 的正文（若不为空则替代 text 用于接口），界面仍显示 text
    var apiContent: String?
    let isUser: Bool
    var isStreaming: Bool
    var canRetry: Bool
    var isIncomplete: Bool

    init(
        id: UUID = UUID(),
        text: String,
        apiContent: String? = nil,
        isUser: Bool,
        isStreaming: Bool = false,
        canRetry: Bool = false,
        isIncomplete: Bool = false
    ) {
        self.id = id
        self.text = text
        self.apiContent = apiContent
        self.isUser = isUser
        self.isStreaming = isStreaming
        self.canRetry = canRetry
        self.isIncomplete = isIncomplete
    }
}
