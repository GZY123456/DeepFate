import SwiftUI

struct XiuXinView: View {
    @State private var selectedElement: XiuXinElement = .metal
    @State private var floatingEffects: [FloatingEffect] = []
    @State private var counters: [XiuXinElement: Int] = [:]
    @State private var showSummary = false
    @State private var summaryValues: [XiuXinElement: Int] = [:]
    @State private var summaryTask: Task<Void, Never>?
    @State private var woodfishBounce = false
    @State private var summaryToken = UUID()

    var body: some View {
        GeometryReader { proxy in
            let woodfishHeight = proxy.size.height * 0.33
            ZStack {
                background

                VStack(spacing: 0) {
                    Text("修心")
                        .font(.title2.weight(.semibold))
                        .padding(.top, 18)

                    Spacer()

                    woodfishView(size: woodfishHeight)

                    Spacer(minLength: 16)

                    elementButtons
                        .padding(.bottom, 36)
                }
                .padding(.horizontal, 24)

                ForEach(floatingEffects) { effect in
                    Text(effect.text)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(effect.color)
                        .opacity(effect.opacity)
                        .offset(y: effect.offsetY)
                        .position(
                            x: proxy.size.width * 0.5,
                            y: proxy.size.height * 0.5 - woodfishHeight * 0.5 - 20
                        )
                }

                if showSummary {
                    SummaryOverlay(values: summaryValues)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var background: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.90, green: 0.97, blue: 1.0),
                    Color(red: 0.72, green: 0.86, blue: 0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [
                    Color.white.opacity(0.6),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 260
            )
            .offset(x: -60, y: -80)
            LinearGradient(
                colors: [
                    Color.white.opacity(0.0),
                    Color.blue.opacity(0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func woodfishView(size: CGFloat) -> some View {
        return Button {
            triggerEffect(for: selectedElement)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                woodfishBounce = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                    woodfishBounce = false
                }
            }
        } label: {
            Image("WoodFish")
                .resizable()
                .scaledToFit()
                .frame(height: size)
                .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)
            .scaleEffect(woodfishBounce ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private var elementButtons: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                ForEach([XiuXinElement.metal, .wood, .water], id: \.self) { element in
                    ElementButton(element: element, isSelected: element == selectedElement) {
                        selectedElement = element
                        triggerEffect(for: element)
                    }
                }
            }
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                ForEach([XiuXinElement.fire, .earth], id: \.self) { element in
                    ElementButton(element: element, isSelected: element == selectedElement) {
                        selectedElement = element
                        triggerEffect(for: element)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func triggerEffect(for element: XiuXinElement) {
        let count = (counters[element] ?? 0) + 1
        counters[element] = count

        let effect = FloatingEffect(text: "\(element.effectText)+1", color: element.color)
        floatingEffects.append(effect)
        animateFloatingEffect(effect.id)

        scheduleSummary()
    }

    private func animateFloatingEffect(_ id: UUID) {
        guard let index = floatingEffects.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 1.0)) {
            floatingEffects[index].offsetY = -60
            floatingEffects[index].opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            floatingEffects.removeAll { $0.id == id }
        }
    }

    private func scheduleSummary() {
        summaryTask?.cancel()
        showSummary = false
        summaryToken = UUID()
        let token = summaryToken
        summaryTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                guard token == summaryToken else { return }
                summaryValues = counters
                counters = [:]
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSummary = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showSummary = false
                    }
                }
            }
        }
    }
}

private struct ElementButton: View {
    let element: XiuXinElement
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: element.symbol)
                    .font(.title3)
                    .foregroundStyle(element.color)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(element.color.opacity(0.2)))
                Text(element.shortName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(10)
            .frame(width: 84)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? element.color : .clear, lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct SummaryOverlay: View {
    let values: [XiuXinElement: Int]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(XiuXinElement.allCases, id: \.self) { element in
                let count = values[element] ?? 0
                Text("\(element.effectText)+\(count)")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(element.color.opacity(0.9))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.92))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 6)
    }
}

private enum XiuXinElement: CaseIterable {
    case metal
    case wood
    case water
    case fire
    case earth

    var shortName: String {
        switch self {
        case .metal: return "金"
        case .wood: return "木"
        case .water: return "水"
        case .fire: return "火"
        case .earth: return "土"
        }
    }

    var effectText: String {
        switch self {
        case .metal: return "功德"
        case .wood: return "治愈"
        case .water: return "气运"
        case .fire: return "事业"
        case .earth: return "爱情"
        }
    }

    var symbol: String {
        switch self {
        case .metal: return "bell"
        case .wood: return "leaf"
        case .water: return "drop"
        case .fire: return "flame"
        case .earth: return "mountain.2"
        }
    }

    var color: Color {
        switch self {
        case .metal:
            return Color(red: 0.92, green: 0.82, blue: 0.62)
        case .wood:
            return Color(red: 0.55, green: 0.78, blue: 0.58)
        case .water:
            return Color(red: 0.47, green: 0.72, blue: 0.92)
        case .fire:
            return Color(red: 0.92, green: 0.48, blue: 0.40)
        case .earth:
            return Color(red: 0.82, green: 0.70, blue: 0.50)
        }
    }
}

private struct FloatingEffect: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
    var offsetY: CGFloat = 0
    var opacity: Double = 1
}
