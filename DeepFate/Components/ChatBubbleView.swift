import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage
    let canEdit: Bool
    let showActionBar: Bool
    let isSpeaking: Bool
    let onRetry: (() -> Void)?
    let onEdit: (() -> Void)?
    let onCopy: (() -> Void)?
    let onSpeak: (() -> Void)?
    @Environment(\.consultTheme) private var consultTheme
    @State private var cursorOpacity: Double = 1

    private var theme: ConsultTheme { consultTheme ?? .soft }

    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 40)
                bubble
            } else {
                bubble
                Spacer(minLength: 40)
            }
        }
        .contextMenu {
            if message.isUser {
                Button("复制") {
                    onCopy?()
                }
                if canEdit {
                    Button("修改") {
                        onEdit?()
                    }
                }
                if message.canRetry {
                    Button("重试") {
                        onRetry?()
                    }
                }
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 2) {
                formattedText(message.text, color: theme.primaryText)
                if message.isStreaming {
                    Text("▍")
                        .opacity(cursorOpacity)
                        .onAppear {
                            cursorOpacity = 1
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                cursorOpacity = 0
                            }
                        }
                }
            }
            if showActionBar {
                Divider()
                actionBar
            }
        }
        .font(.body)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryTextBorder, lineWidth: 0.6)
        )
    }

    private func formattedText(_ text: String, color: Color) -> some View {
        Text(preprocessedMarkdown(text))
            .foregroundStyle(color)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                onCopy?()
            } label: {
                Image(systemName: "doc.on.doc")
            }

            Button {
                onSpeak?()
            } label: {
                speakingIcon
            }

            if message.isIncomplete {
                Text("未完成")
                    .font(.caption)
                    .foregroundStyle(theme.primaryText)
            }
        }
        .font(.caption)
        .foregroundStyle(theme.primaryText)
        .opacity(message.isStreaming ? 0 : 1)
    }

    private var speakingIcon: some View {
        let iconName = isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2"
        let icon = Image(systemName: iconName)
        if #available(iOS 17.0, *) {
            return icon.symbolEffect(.pulse, isActive: isSpeaking)
        }
        return icon
    }

    private func preprocessedMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let normalized = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return line }
            let hashes = trimmed.prefix { $0 == "#" }
            let rest = trimmed.drop(while: { $0 == "#" })
            if rest.isEmpty || rest.first == " " {
                return line
            }
            return String(hashes) + " " + rest
        }
        return normalized.joined(separator: "\n")
    }
}
