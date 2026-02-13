import SwiftUI

/// 上下可拖动分割布局：背景固定全屏，聊天窗口在上层可拖动
struct DraggableChatLayout<ModelContent: View, ChatContent: View>: View {
    /// 聊天区域占总高度的比例（0.0 ~ 1.0）
    @Binding var chatRatio: CGFloat
    /// 背景内容（固定全屏，不随聊天框移动）
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

            ZStack(alignment: .bottom) {
                // 背景：固定全屏，不随聊天框移动
                modelContent()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .ignoresSafeArea()

                // 上层：可拖动的聊天窗口
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
