import SwiftUI

struct SuggestionChipsView: View {
    let suggestions: [String]
    let isDisabled: Bool
    let onTap: (String) -> Void
    @Environment(\.consultTheme) private var consultTheme

    private var theme: ConsultTheme { consultTheme ?? .soft }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { item in
                    Button(action: { onTap(item) }) {
                        Text(item)
                            .font(.subheadline)
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(theme.surface)
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
