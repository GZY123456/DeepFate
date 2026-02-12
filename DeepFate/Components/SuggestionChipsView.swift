import SwiftUI

struct SuggestionChipsView: View {
    let suggestions: [String]
    let isDisabled: Bool
    let onTap: (String) -> Void
    private let deepBrown = Color(red: 0.3647, green: 0.2510, blue: 0.2157) // #5D4037
    private let warmWhite = Color(red: 1.0, green: 0.9882, blue: 0.9608).opacity(0.85) // rgba(255,252,245,0.85)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { item in
                    Button(action: { onTap(item) }) {
                        Text(item)
                            .font(.subheadline)
                            .foregroundStyle(deepBrown)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(warmWhite)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .opacity(isDisabled ? 0.5 : 1)
                }
            }
            .padding(.horizontal)
        }
    }
}
