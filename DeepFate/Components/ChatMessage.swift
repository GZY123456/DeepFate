import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var text: String
    let isUser: Bool
    var isStreaming: Bool
    var canRetry: Bool
    var isIncomplete: Bool

    init(
        id: UUID = UUID(),
        text: String,
        isUser: Bool,
        isStreaming: Bool = false,
        canRetry: Bool = false,
        isIncomplete: Bool = false
    ) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.isStreaming = isStreaming
        self.canRetry = canRetry
        self.isIncomplete = isIncomplete
    }
}
