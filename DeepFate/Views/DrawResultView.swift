import SwiftUI

struct DrawResultView: View {
    let result: DrawResult
    let isAskingAI: Bool
    let onAskAI: () -> Void
    let askError: String?
    @State private var glow = false

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(spacing: 18) {
                    header
                    keywords
                    infoCard(title: "解读", content: result.interpretation)
                    infoCard(title: "建议", content: result.advice)
                    if let askError {
                        Text(askError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                    askAIButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text("今日抽卡")
                .font(.caption)
                .foregroundStyle(Color(red: 0.38, green: 0.3, blue: 0.26))
            ZStack {
                ritualRing
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.94, green: 0.88, blue: 0.78), Color(red: 0.88, green: 0.8, blue: 0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 8)

                VStack(spacing: 8) {
                    Text(result.cardName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color(red: 0.28, green: 0.18, blue: 0.12))
                    Text(result.date)
                        .font(.footnote)
                        .foregroundStyle(Color(red: 0.45, green: 0.36, blue: 0.3))
                }
                .padding(.vertical, 20)
            }
            .frame(height: 160)
        }
    }

    private var ritualRing: some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    colors: [
                        Color(red: 0.62, green: 0.48, blue: 0.38),
                        Color(red: 0.78, green: 0.62, blue: 0.48).opacity(0.4),
                        Color(red: 0.62, green: 0.48, blue: 0.38)
                    ],
                    center: .center
                ),
                lineWidth: 2
            )
            .frame(width: 180, height: 180)
            .opacity(glow ? 0.6 : 0.25)
            .scaleEffect(glow ? 1.05 : 0.98)
            .blur(radius: 0.6)
            .offset(y: -6)
    }

    private var keywords: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关键词")
                .font(.headline)
                .foregroundStyle(Color(red: 0.3, green: 0.22, blue: 0.18))
            FlowTagsView(tags: result.keywords)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.98, green: 0.96, blue: 0.92))
        )
    }

    private func infoCard(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(red: 0.3, green: 0.22, blue: 0.18))
            Text(content)
                .font(.body)
                .foregroundStyle(Color(red: 0.2, green: 0.16, blue: 0.14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.98, green: 0.96, blue: 0.92))
        )
    }

    private var askAIButton: some View {
        Button {
            onAskAI()
        } label: {
            Text(isAskingAI ? "生成中..." : "问问AI")
                .font(.headline)
                .foregroundStyle(Color(red: 0.98, green: 0.96, blue: 0.92))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .background(Color(red: 0.45, green: 0.16, blue: 0.22))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 8)
        .disabled(isAskingAI)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.95, blue: 0.92),
                Color(red: 0.94, green: 0.9, blue: 0.88)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(ritualPattern.opacity(0.1))
        .ignoresSafeArea()
    }

    private var ritualPattern: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                .frame(width: 240, height: 240)
                .offset(y: -120)
            Circle()
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                .frame(width: 320, height: 320)
                .offset(y: -140)
        }
    }
}

private struct FlowTagsView: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(Color(red: 0.32, green: 0.24, blue: 0.2))
                            .background(Capsule().fill(Color(red: 0.92, green: 0.86, blue: 0.8)))
                    }
                    Spacer()
                }
            }
        }
    }

    private var chunks: [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        for tag in tags {
            current.append(tag)
            if current.count == 3 {
                rows.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
