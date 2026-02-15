import SwiftUI
import UIKit

private enum DailyDrawRitual: String {
    case sigil
    case face

    var title: String {
        switch self {
        case .sigil: return "画符启封"
        case .face: return "相面抽卡"
        }
    }
}

struct OneThingDrawView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var consultRouter: ConsultRouter
    @Environment(\.dismiss) private var dismiss

    @State private var drawResult: DrawResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    @State private var isRevealing = false
    @State private var revealPulse = false
    @State private var revealFlash = false
    @State private var revealShake = false
    @State private var isAskingAI = false
    @State private var askError: String?
    @State private var showProfilePicker = false
    @State private var ritual: DailyDrawRitual = .sigil

    private let drawClient = DrawClient()
    private let chartClient = ChartClient()

    var body: some View {
        Group {
            if let profile = activeProfile {
                content(profile: profile)
            } else {
                emptyState
            }
        }
        .navigationTitle("今日运势")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showProfilePicker = true
                } label: {
                    Image(systemName: "person.2")
                    Text("切换用户")
                }
            }
        }
        .sheet(isPresented: $showProfilePicker) {
            profilePickerSheet
        }
        .onAppear {
            guard let profile = activeProfile else { return }
            resolveRitual(for: profile)
            Task { await checkToday(for: profile) }
        }
        .onChange(of: profileStore.activeProfileID) { _, _ in
            guard let profile = activeProfile else { return }
            resolveRitual(for: profile)
            Task { await checkToday(for: profile) }
        }
    }

    private var activeProfile: UserProfile? {
        guard let id = profileStore.activeProfileID else { return nil }
        return profileStore.profiles.first { $0.id == id }
    }

    private func content(profile: UserProfile) -> some View {
        ZStack {
            background
            if let drawResult {
                DrawResultView(result: drawResult, isAskingAI: isAskingAI, onAskAI: {
                    Task { await sendAskAI(drawResult: drawResult, profile: profile) }
                }, askError: askError)
            } else {
                drawCardView(profile: profile)
            }
        }
    }

    private func drawCardView(profile: UserProfile) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("今日只抽一次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("在卡面上画下你的符号")
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 4)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.18, green: 0.12, blue: 0.24), Color(red: 0.08, green: 0.06, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 20, x: 0, y: 10)
                    .overlay(inkPattern.opacity(0.12))

                if !hasDrawn {
                    VStack(spacing: 10) {
                        Text("符箓之卡")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("请画下符号以启封")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                DrawingCanvas(
                    strokes: $strokes,
                    currentStroke: $currentStroke
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(12)
                .opacity(isRevealing ? 0.0 : 1.0)

                if isRevealing {
                    revealSeal
                }
            }
            .frame(height: 480)
            .padding(.horizontal, 20)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button("重画") {
                        strokes = []
                        currentStroke = []
                    }
                    .buttonStyle(.bordered)

                    Button(isLoading ? "抽取中..." : "完成符咒，抽卡") {
                        Task { await generateResult(for: profile, withReveal: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || !hasDrawn)
                }
                NavigationLink {
                    if let profile = activeProfile {
                        FaceRitualCaptureView(
                            onSuccess: {
                                Task { await generateResult(for: profile, withReveal: false) }
                            },
                            onUseRandomFallback: {
                                Task { await generateResult(for: profile, withReveal: false) }
                            },
                            onSwitchUser: {
                                showProfilePicker = true
                            }
                        )
                    }
                } label: {
                    Text("测试相面")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(red: 0.45, green: 0.32, blue: 0.58))
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.top, -6)
    }

    private var hasDrawn: Bool {
        let count = strokes.reduce(0) { $0 + $1.count } + currentStroke.count
        return count > 12
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("请先创建档案后再抽卡")
                .font(.body)
                .foregroundStyle(.secondary)
            NavigationLink("去档案馆") {
                ArchiveView()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.97, green: 0.93, blue: 0.90),
                Color(red: 0.92, green: 0.86, blue: 0.90)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var profilePickerSheet: some View {
        NavigationStack {
            List(profileStore.profiles) { profile in
                Button {
                    profileStore.setActive(profile.id)
                    drawResult = nil
                    isRevealing = false
                    resolveRitual(for: profile)
                    showProfilePicker = false
                    Task { await checkToday(for: profile) }
                } label: {
                    HStack {
                        Text(profile.name)
                        if profile.id == activeProfile?.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.purple)
                        }
                    }
                }
            }
            .navigationTitle("选择档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        showProfilePicker = false
                    }
                }
            }
        }
    }

    private func checkToday(for profile: UserProfile) async {
        errorMessage = nil
        do {
            let result = try await drawClient.fetchToday(profileId: profile.id)
            await MainActor.run {
                drawResult = result
            }
        } catch {
            // 404 means no draw today; ignore
        }
    }

    private func generateResult(for profile: UserProfile, withReveal: Bool) async {
        errorMessage = nil
        isLoading = true
        if withReveal {
            withAnimation(.easeInOut(duration: 0.35)) {
                isRevealing = true
            }
            startRevealPulse()
        }
        do {
            let result = try await drawClient.generateToday(profileId: profile.id)
            await MainActor.run {
                if withReveal {
                    triggerRevealFinish()
                } else {
                    isRevealing = false
                }
                withAnimation(.easeInOut(duration: 0.35)) {
                    drawResult = result
                }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
                if withReveal {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRevealing = false
                    }
                } else {
                    isRevealing = false
                }
            }
        }
    }

    private func resolveRitual(for profile: UserProfile) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: profile.location.timezoneID) ?? .current
        let dayText = formatter.string(from: Date())
        let key = "\(dayText)-\(profile.id.uuidString)"
        var hash = 5381
        for scalar in key.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        ritual = abs(hash) % 2 == 0 ? .sigil : .face
        strokes = []
        currentStroke = []
    }

    private var currentRitual: DailyDrawRitual {
        ritual
    }

    private func sendAskAI(drawResult: DrawResult, profile: UserProfile) async {
        guard !isAskingAI else { return }
        askError = nil
        isAskingAI = true
        let chartText = await fetchChartText(for: profile)
        await MainActor.run {
            consultRouter.askAI(withDrawResult: drawResult, profile: profile, chartText: chartText)
            isAskingAI = false
            dismiss()
        }
    }

    private func fetchChartText(for profile: UserProfile) async -> String? {
        let comp = profile.trueSolarComponents
        let year = comp.year ?? 2000
        let month = comp.month ?? 1
        let day = comp.day ?? 1
        let hour = comp.hour ?? 0
        let minute = comp.minute ?? 0
        let longitude = profile.location.longitude
        let gender = profile.gender.rawValue
        do {
            let result = try await chartClient.fetchChart(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                longitude: longitude,
                gender: gender
            )
            return result.content
        } catch {
            await MainActor.run {
                askError = "未能获取八字信息，将仅依据抽卡结果解读。"
            }
            return nil
        }
    }

    private func startRevealPulse() {
        revealPulse = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                revealPulse = true
            }
        }
    }

    private func triggerRevealFinish() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.18)) {
            revealFlash = true
        }
        withAnimation(.default) {
            revealShake.toggle()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isRevealing = false
            }
        }
    }

    private var revealSeal: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.95, green: 0.92, blue: 0.84), Color(red: 0.85, green: 0.78, blue: 0.66)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(parchmentTexture.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.2), lineWidth: 1)
                )

            VStack(spacing: 12) {
                Text("封印启示")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.35, green: 0.18, blue: 0.12))
                Circle()
                    .strokeBorder(Color(red: 0.45, green: 0.18, blue: 0.14).opacity(0.8), lineWidth: 2)
                    .frame(width: 78, height: 78)
                    .overlay(
                        Image(systemName: "seal.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color(red: 0.55, green: 0.15, blue: 0.14))
                    )
                    .scaleEffect(revealPulse ? 1.06 : 0.98)
                    .opacity(revealPulse ? 0.9 : 0.7)
            }
            .padding(.top, 18)

            VStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.62, green: 0.15, blue: 0.16))
                    .frame(width: 140, height: 28)
                    .overlay(
                        Text("朱砂封条")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(red: 0.98, green: 0.94, blue: 0.9))
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)
                Spacer()
            }
            .padding(.top, 12)
        }
        .scaleEffect(revealFlash ? 1.05 : 0.98)
        .brightness(revealFlash ? 0.08 : 0)
        .offset(x: revealShake ? 2 : -2)
        .animation(.linear(duration: 0.08).repeatCount(4, autoreverses: true), value: revealShake)
        .transition(.opacity)
        .padding(12)
    }

    private var parchmentTexture: some View {
        LinearGradient(
            colors: [
                Color.white.opacity(0.08),
                Color.black.opacity(0.04),
                Color.white.opacity(0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .blendMode(.overlay)
        .overlay(
            LinearGradient(
                colors: [Color.black.opacity(0.08), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var inkPattern: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                .frame(width: 160, height: 160)
                .offset(x: -80, y: -120)
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .frame(width: 240, height: 240)
                .offset(x: 90, y: 120)
        }
        .blendMode(.softLight)
    }
}

private struct DrawingCanvas: View {
    @Binding var strokes: [[CGPoint]]
    @Binding var currentStroke: [CGPoint]

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.25))

                Path { path in
                    for stroke in strokes {
                        addStroke(stroke, to: &path)
                    }
                    addStroke(currentStroke, to: &path)
                }
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if currentStroke.isEmpty {
                            currentStroke = [value.location]
                        } else {
                            currentStroke.append(value.location)
                        }
                    }
                    .onEnded { _ in
                        if !currentStroke.isEmpty {
                            strokes.append(currentStroke)
                            currentStroke = []
                        }
                    }
            )
        }
    }

    private func addStroke(_ points: [CGPoint], to path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
    }
}
