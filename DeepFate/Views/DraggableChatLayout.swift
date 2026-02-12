import SwiftUI

/// 上下可拖动分割布局：上方为 3D 模型，下方为聊天窗口
struct DraggableChatLayout<ModelContent: View, ChatContent: View>: View {
    /// 聊天区域占总高度的比例（0.0 ~ 1.0）
    @Binding var chatRatio: CGFloat
    /// 上方区域内容（3D 模型）
    let modelContent: () -> ModelContent
    /// 下方区域内容（聊天）
    let chatContent: () -> ChatContent

    // 拖动状态
    @State private var dragStartRatio: CGFloat = 0

    // 约束范围：聊天区最少占 30%，最多占 80%
    private let minRatio: CGFloat = 0.30
    private let maxRatio: CGFloat = 0.80

    // 手柄高度
    private let handleHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let totalHeight = geometry.size.height
            let chatHeight = totalHeight * chatRatio
            let modelHeight = totalHeight - chatHeight

            VStack(spacing: 0) {
                // 上方：3D 模型区域
                modelContent()
                    .frame(height: modelHeight)
                    .clipped()

                // 下方：拖动手柄 + 聊天窗口
                VStack(spacing: 0) {
                    // 拖动手柄
                    dragHandle
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let delta = -value.translation.height / totalHeight
                                    let newRatio = (dragStartRatio + delta)
                                        .clamped(to: minRatio...maxRatio)
                                    chatRatio = newRatio
                                }
                                .onEnded { _ in
                                    dragStartRatio = chatRatio
                                }
                        )
                        .onAppear {
                            dragStartRatio = chatRatio
                        }

                    // 聊天内容
                    chatContent()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: chatHeight)
                .background(
                    Color(.systemBackground)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 20,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 20
                            )
                        )
                        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: -4)
                )
            }
        }
    }

    /// 拖动手柄：居中小灰条
    private var dragHandle: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 10)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
            Spacer().frame(height: 13)
        }
        .frame(maxWidth: .infinity)
        .frame(height: handleHeight)
        .contentShape(Rectangle())
    }
}

// MARK: - Comparable clamping

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
