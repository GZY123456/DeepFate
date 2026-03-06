import SwiftUI
@preconcurrency import AVFoundation
import Vision
import UIKit

struct PalmistryView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var consultRouter: ConsultRouter
    @Environment(\.dismiss) private var dismiss

    @StateObject private var detector = PalmCaptureDetector()
    @State private var result: PalmistryResult?
    @State private var isAnalyzing = false
    @State private var isAskingAI = false
    @State private var errorMessage: String?
    @State private var askError: String?
    @State private var showHistory = false
    @State private var showProfilePicker = false
    @State private var showPermissionAlert = false
    @State private var history: [PalmistryHistoryItem] = []
    @State private var historyError: String?
    @State private var isLoadingHistory = false
    @State private var selectedManualSide: PalmHandSide = .right

    private let palmistryClient = PalmistryClient()
    private let chartClient = ChartClient()

    var body: some View {
        Group {
            if let profile = activeProfile {
                ZStack {
                    background
                    if let result {
                        resultContent(profile: profile, result: result)
                    } else {
                        captureContent(profile: profile)
                    }
                }
            } else {
                emptyState
            }
        }
        .navigationTitle("看手相")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showProfilePicker = true
                } label: {
                    Label("切换用户", systemImage: "person.2")
                }
            }
        }
        .sheet(isPresented: $showProfilePicker) {
            profilePickerSheet
        }
        .sheet(isPresented: $showHistory) {
            historySheet
        }
        .alert("需要相机权限", isPresented: $showPermissionAlert) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("请允许相机权限后再进行手相拍照。画面只做本地完整度检测，完成后才上传拍照结果。")
        }
        .onAppear {
            detector.onCapture = { frame in
                Task { await analyze(frame: frame) }
            }
            detector.onPermissionDenied = {
                showPermissionAlert = true
            }
            detector.prepareIfNeeded()
        }
        .onDisappear {
            detector.stop()
        }
        .onChange(of: effectiveHandSide) { _, _ in
            detector.resetStability()
        }
        .onChange(of: profileStore.activeProfileID) { _, _ in
            detector.resetStability()
            result = nil
            errorMessage = nil
            askError = nil
        }
    }

    private var activeProfile: UserProfile? {
        guard let id = profileStore.activeProfileID else { return nil }
        return profileStore.profiles.first { $0.id == id }
    }

    private var effectiveHandSide: PalmHandSide {
        guard let profile = activeProfile else { return .right }
        switch profile.gender {
        case .male:
            return .left
        case .female:
            return .right
        case .other:
            return selectedManualSide
        }
    }

    private var profilePickerSheet: some View {
        NavigationStack {
            List(profileStore.profiles) { profile in
                Button {
                    profileStore.setActive(profile.id)
                    result = nil
                    showProfilePicker = false
                } label: {
                    HStack(spacing: 12) {
                        ProfileAvatarView(name: profile.name, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                                .font(.headline)
                            Text("\(profile.gender.rawValue) · \(formatDateComponents(profile.birthInfo.solarComponents))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.id == activeProfile?.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(red: 0.82, green: 0.46, blue: 0.38))
                        }
                    }
                }
            }
            .navigationTitle("选择档案")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showProfilePicker = false }
                }
            }
        }
    }

    private func captureContent(profile: UserProfile) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                header(profile: profile)
                cameraCard(profile: profile)
                privacyCard
                actionHints(profile: profile)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .task {
            await startCameraIfNeeded()
        }
    }

    private func header(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("掌纹识运")
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(Color(red: 0.34, green: 0.22, blue: 0.17))
                    Text("识别完整手掌后自动拍照并进入解析")
                        .font(.footnote)
                        .foregroundStyle(Color(red: 0.52, green: 0.42, blue: 0.35))
                }
                Spacer()
                if profile.gender == .other {
                    Picker("手别", selection: $selectedManualSide) {
                        ForEach(PalmHandSide.allCases) { side in
                            Text(side.title).tag(side)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                } else {
                    sideBadge(effectiveHandSide, locked: true)
                }
            }
            if profile.gender == .other {
                Text("未设置性别，当前由你手动指定识别手别。")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.56, green: 0.45, blue: 0.38))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cameraCard(profile: UserProfile) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.black.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )

                PalmCameraPreviewView(detector: detector)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.94, blue: 0.90).opacity(0.12),
                                Color.clear,
                                Color.black.opacity(0.16)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }

                HandGuideOverlay(side: effectiveHandSide, progress: detector.stabilityProgress)
                    .padding(24)

                VStack {
                    HStack {
                        statusPill(icon: "hand.raised", text: effectiveHandSide.title)
                        Spacer()
                        statusPill(icon: "camera.aperture", text: detector.statusText)
                    }
                    .padding(14)
                    Spacer()
                    if isAnalyzing {
                        analyzingOverlay
                    } else {
                        guideFooter
                    }
                }
            }
            .frame(height: 470)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.76, green: 0.50, blue: 0.40))
            VStack(alignment: .leading, spacing: 6) {
                Text("隐私说明")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.34, green: 0.22, blue: 0.17))
                Text("DeepFate 只在本地做完整度检测。只有当手掌完整入框后，才会自动拍照并上传本次照片用于手相分析。")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.48, green: 0.38, blue: 0.31))
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.6), lineWidth: 1)
        )
    }

    private func actionHints(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拍摄要求")
                .font(.headline)
                .foregroundStyle(Color(red: 0.34, green: 0.22, blue: 0.17))
            hintRow("1", text: "仅允许单手入镜，掌心朝向镜头，尽量五指自然张开。")
            hintRow("2", text: "戒指和美甲可以保留，但请保证掌纹区域清晰、不要被阴影遮挡。")
            hintRow("3", text: profile.gender == .male ? "当前默认识别左手。" : profile.gender == .female ? "当前默认识别右手。" : "你可以在上方手动切换左手或右手。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.66))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.58), lineWidth: 1)
        )
    }

    private func resultContent(profile: UserProfile, result: PalmistryResult) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                palmResultHero(result)
                sectionCard(title: "总评", content: result.analysis.summary)
                sectionCard(title: "生命线", content: result.analysis.lifeLine)
                sectionCard(title: "智慧线", content: result.analysis.headLine)
                sectionCard(title: "感情线", content: result.analysis.heartLine)
                sectionCard(title: "事业", content: result.analysis.career)
                sectionCard(title: "财运", content: result.analysis.wealth)
                sectionCard(title: "情感", content: result.analysis.love)
                sectionCard(title: "健康", content: result.analysis.health)
                structuredCard(result.analysis.structured)
                sectionCard(title: "建议", content: result.analysis.advice)
                if let askError {
                    Text(askError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                actionButtons(profile: profile, result: result)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
    }

    private func palmResultHero(_ result: PalmistryResult) -> some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.58))
                    .frame(height: 270)
                    .overlay {
                        if let url = result.originalImageURL {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case let .success(image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                case .failure:
                                    Color(red: 0.94, green: 0.88, blue: 0.83)
                                case .empty:
                                    ProgressView()
                                @unknown default:
                                    ProgressView()
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                    }
                    .overlay(
                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(0.40)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.analysis.overall)
                        .font(.system(.title2, design: .serif).weight(.bold))
                    HStack(spacing: 8) {
                        sideBadge(result.handSide, locked: false)
                        Text(result.takenAt)
                            .font(.caption)
                    }
                }
                .foregroundStyle(.white)
                .padding(18)
            }
        }
    }

    private func structuredCard(_ structured: PalmistryStructuredFeatures) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("结构化观察")
                .font(.headline)
                .foregroundStyle(Color(red: 0.34, green: 0.22, blue: 0.17))
            let rows = [
                ("掌型", structured.palmShape),
                ("舒展度", structured.fingerSpread),
                ("掌纹清晰度", structured.lineClarity),
                ("质量备注", structured.qualitySummary),
                ("生命线观察", structured.lifeLine),
                ("智慧线观察", structured.headLine),
                ("感情线观察", structured.heartLine),
                ("事业线观察", structured.careerLine)
            ]
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.58, green: 0.42, blue: 0.34))
                    Text(row.1)
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.14))
                }
            }
            if !structured.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("补充")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.58, green: 0.42, blue: 0.34))
                    ForEach(structured.notes, id: \.self) { note in
                        Text("• \(note)")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.14))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground)
    }

    private func sectionCard(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(red: 0.34, green: 0.22, blue: 0.17))
            Text(content)
                .font(.body)
                .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground)
    }

    private func actionButtons(profile: UserProfile, result: PalmistryResult) -> some View {
        VStack(spacing: 12) {
            Button {
                Task { await askAI(for: result, profile: profile) }
            } label: {
                Text(isAskingAI ? "生成中..." : "问问AI")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(Color(red: 0.79, green: 0.42, blue: 0.36))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(isAskingAI)

            HStack(spacing: 12) {
                Button {
                    Task { await loadHistory() }
                    showHistory = true
                } label: {
                    Text("历史记录")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.42, green: 0.28, blue: 0.22))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(Color.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    resetForNewScan()
                } label: {
                    Text("看新的手相")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.42, green: 0.28, blue: 0.22))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(Color.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var historySheet: some View {
        NavigationStack {
            Group {
                if isLoadingHistory {
                    ProgressView("加载中...")
                } else if let historyError {
                    VStack(spacing: 12) {
                        Text(historyError)
                            .foregroundStyle(.secondary)
                        Button("重试") {
                            Task { await loadHistory() }
                        }
                    }
                } else if history.isEmpty {
                    ContentUnavailableView("暂无手相记录", systemImage: "hand.raised.slash")
                } else {
                    List(history) { item in
                        Button {
                            Task { await openHistoryItem(item) }
                        } label: {
                            HStack(spacing: 12) {
                                thumbnail(for: item.thumbnailURL)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.overall)
                                        .font(.headline)
                                        .foregroundStyle(Color.primary)
                                    Text(item.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    HStack(spacing: 8) {
                                        Text(item.handSide.title)
                                        Text(item.takenAt)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("手相历史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showHistory = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func thumbnail(for url: URL?) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(red: 0.95, green: 0.90, blue: 0.86))
            .frame(width: 64, height: 78)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "hand.raised")
                                .foregroundStyle(.secondary)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            ProgressView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Text("请先创建档案后再看手相")
                .foregroundStyle(.secondary)
            NavigationLink("去档案馆") {
                ArchiveView()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.94, blue: 0.92),
                Color(red: 0.95, green: 0.90, blue: 0.92)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.62), lineWidth: 1)
            )
    }

    private var guideFooter: some View {
        VStack(spacing: 8) {
            ProgressView(value: detector.stabilityProgress)
                .tint(Color(red: 0.82, green: 0.46, blue: 0.38))
            Text(detector.guidanceText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(16)
    }

    private var analyzingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.1)
            Text("已自动拍照，正在解析手相...")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(16)
    }

    private func sideBadge(_ side: PalmHandSide, locked: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: locked ? "lock.fill" : "hand.raised")
                .font(.caption)
            Text(side.title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Color(red: 0.42, green: 0.28, blue: 0.22))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.78), in: Capsule())
    }

    private func statusPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.24), in: Capsule())
    }

    private func hintRow(_ index: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color(red: 0.82, green: 0.46, blue: 0.38), in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.14))
            Spacer(minLength: 0)
        }
    }

    private func startCameraIfNeeded() async {
        guard !isAnalyzing else { return }
        let granted = await detector.requestCameraAccess()
        guard granted else {
            showPermissionAlert = true
            return
        }
        await detector.start()
    }

    @MainActor
    private func analyze(frame: PalmCapturedFrame) async {
        guard let profile = activeProfile else { return }
        guard !isAnalyzing else { return }
        isAnalyzing = true
        errorMessage = nil
        askError = nil
        do {
            let response = try await palmistryClient.analyze(
                profileId: profile.id,
                handSide: effectiveHandSide,
                capturedAt: frame.capturedAt,
                image: frame.image,
                landmarks: frame.landmarks
            )
            result = response
        } catch {
            errorMessage = error.localizedDescription
            await detector.start()
        }
        isAnalyzing = false
    }

    private func resetForNewScan() {
        result = nil
        errorMessage = nil
        askError = nil
        detector.resetStability()
        Task { await startCameraIfNeeded() }
    }

    private func loadHistory() async {
        guard let profile = activeProfile else { return }
        isLoadingHistory = true
        historyError = nil
        do {
            history = try await palmistryClient.fetchHistory(profileId: profile.id)
        } catch {
            historyError = error.localizedDescription
        }
        isLoadingHistory = false
    }

    private func openHistoryItem(_ item: PalmistryHistoryItem) async {
        guard let profile = activeProfile else { return }
        do {
            let full = try await palmistryClient.fetchResult(profileId: profile.id, readingId: item.id)
            await MainActor.run {
                result = full
                showHistory = false
            }
        } catch {
            await MainActor.run {
                historyError = error.localizedDescription
            }
        }
    }

    private func askAI(for result: PalmistryResult, profile: UserProfile) async {
        guard !isAskingAI else { return }
        isAskingAI = true
        askError = nil
        defer { isAskingAI = false }

        let solar = profile.trueSolarComponents
        let minute = solar.minute ?? 0
        let chartText: String?
        do {
            chartText = try await chartClient.fetchChart(
                year: solar.year ?? profile.birthInfo.solarComponents.year ?? 2000,
                month: solar.month ?? profile.birthInfo.solarComponents.month ?? 1,
                day: solar.day ?? profile.birthInfo.solarComponents.day ?? 1,
                hour: solar.hour ?? profile.birthInfo.solarComponents.hour ?? 0,
                minute: minute,
                longitude: profile.location.longitude,
                gender: profile.gender.rawValue
            ).content
        } catch {
            chartText = nil
        }

        await MainActor.run {
            consultRouter.askAI(withPalmistryResult: result, profile: profile, chartText: chartText)
        }
    }
}

private struct HandGuideOverlay: View {
    let side: PalmHandSide
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let palmWidth = size.width * 0.38
            let palmHeight = size.height * 0.32
            let fingerWidth = palmWidth * 0.14
            let fingerHeight = palmHeight * 0.68
            let thumbWidth = palmWidth * 0.20
            let thumbHeight = palmHeight * 0.38
            let guideColor = Color.white.opacity(0.85)
            let glow = Color(red: 0.98, green: 0.77, blue: 0.45)

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .foregroundStyle(guideColor.opacity(0.55))
                    .frame(width: palmWidth, height: palmHeight)
                    .offset(y: size.height * 0.14)

                HStack(spacing: fingerWidth * 0.18) {
                    ForEach(0..<4, id: \.self) { idx in
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .foregroundStyle(guideColor.opacity(idx == 1 ? 0.95 : 0.75))
                            .frame(width: fingerWidth, height: fingerHeight * (idx == 1 ? 1.06 : 1.0 - Double(abs(idx - 1)) * 0.06))
                    }
                }
                .offset(y: -size.height * 0.06)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(guideColor.opacity(0.75))
                    .frame(width: thumbWidth, height: thumbHeight)
                    .rotationEffect(.degrees(side == .left ? -32 : 32))
                    .offset(x: side == .left ? -palmWidth * 0.34 : palmWidth * 0.34, y: size.height * 0.10)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(glow, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size.width * 0.72, height: size.width * 0.72)
                    .shadow(color: glow.opacity(0.6), radius: 10)

                VStack(spacing: 6) {
                    Text(side.title)
                        .font(.system(.title3, design: .serif).weight(.semibold))
                    Text("请将整只手放入引导框")
                        .font(.footnote)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.22), in: Capsule())
                .offset(y: size.height * 0.35)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(x: side.mirrored ? -1 : 1, y: 1)
        }
    }
}

private struct PalmCameraPreviewView: UIViewRepresentable {
    @ObservedObject var detector: PalmCaptureDetector

    func makeUIView(context: Context) -> PalmCameraPreviewContainerView {
        let view = PalmCameraPreviewContainerView()
        view.attach(session: detector.session)
        return view
    }

    func updateUIView(_ uiView: PalmCameraPreviewContainerView, context: Context) {
        uiView.attach(session: detector.session)
    }
}

private final class PalmCameraPreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func attach(session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.connection?.videoRotationAngle = 90
    }
}

private struct PalmCapturedFrame {
    let image: UIImage
    let landmarks: [String: PalmLandmarkPoint]
    let capturedAt: Date
}

private final class PalmCaptureDetector: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var guidanceText: String = "将整只手放入引导框，稳定后会自动拍照"
    @Published private(set) var statusText: String = "等待识别"
    @Published private(set) var stabilityProgress: Double = 0

    let session = AVCaptureSession()

    var onCapture: ((PalmCapturedFrame) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "PalmCaptureDetector.queue")
    private let context = CIContext(options: nil)
    private var didConfigure = false
    private var frameCounter = 0
    private var stableCount = 0
    private var isCapturing = false
    private let requiredStableCount = 8
    private let detectionZone = CGRect(x: 0.16, y: 0.14, width: 0.68, height: 0.72)

    func prepareIfNeeded() {
        guard !didConfigure else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer {
            session.commitConfiguration()
            didConfigure = true
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.connection(with: .video)?.videoRotationAngle = 90
    }

    func requestCameraAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            await MainActor.run { self.onPermissionDenied?() }
            return false
        @unknown default:
            return false
        }
    }

    @MainActor
    func start() async {
        prepareIfNeeded()
        resetStability()
        guard !session.isRunning else { return }
        let session = session
        queue.async {
            session.startRunning()
        }
        statusText = "识别中"
    }

    func stop() {
        guard session.isRunning else { return }
        let session = session
        queue.async {
            session.stopRunning()
        }
    }

    @MainActor
    func resetStability() {
        stableCount = 0
        frameCounter = 0
        isCapturing = false
        stabilityProgress = 0
        guidanceText = "将整只手放入引导框，稳定后会自动拍照"
        statusText = "等待识别"
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCounter += 1
        if frameCounter % 2 != 0 { return }
        if isCapturing { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            guard observations.count == 1, let observation = observations.first else {
                markInvalid("请确保画面中只有一只手")
                return
            }
            let recognition = try observation.recognizedPoints(.all)
            let payload = selectedLandmarks(from: recognition)
            guard isComplete(points: payload) else {
                markInvalid("请将整只手完整放入引导框")
                return
            }
            stableCount += 1
            let progress = min(1.0, Double(stableCount) / Double(requiredStableCount))
            DispatchQueue.main.async {
                self.stabilityProgress = progress
                self.statusText = progress >= 1 ? "已锁定" : "识别中"
                self.guidanceText = progress >= 1 ? "保持稳定，正在自动拍照" : "保持手掌清晰且完整"
            }
            guard stableCount >= requiredStableCount else { return }
            isCapturing = true
            guard let image = makeImage(from: pixelBuffer) else {
                markInvalid("拍照失败，请重试")
                return
            }
            let frame = PalmCapturedFrame(image: image, landmarks: payload, capturedAt: Date())
            DispatchQueue.main.async {
                self.stop()
                self.onCapture?(frame)
            }
        } catch {
            markInvalid("识别中，请调整光线和手掌位置")
        }
    }

    private func selectedLandmarks(from points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]) -> [String: PalmLandmarkPoint] {
        let keys: [(String, VNHumanHandPoseObservation.JointName)] = [
            ("VNHLKWrist", .wrist),
            ("VNHLKThumbTip", .thumbTip), ("VNHLKThumbIP", .thumbIP), ("VNHLKThumbMP", .thumbMP),
            ("VNHLKIndexTip", .indexTip), ("VNHLKIndexDIP", .indexDIP), ("VNHLKIndexPIP", .indexPIP), ("VNHLKIndexMCP", .indexMCP),
            ("VNHLKMiddleTip", .middleTip), ("VNHLKMiddleDIP", .middleDIP), ("VNHLKMiddlePIP", .middlePIP), ("VNHLKMiddleMCP", .middleMCP),
            ("VNHLKRingTip", .ringTip), ("VNHLKRingDIP", .ringDIP), ("VNHLKRingPIP", .ringPIP), ("VNHLKRingMCP", .ringMCP),
            ("VNHLKLittleTip", .littleTip), ("VNHLKLittleDIP", .littleDIP), ("VNHLKLittlePIP", .littlePIP), ("VNHLKLittleMCP", .littleMCP)
        ]
        var output: [String: PalmLandmarkPoint] = [:]
        for (name, key) in keys {
            guard let point = points[key] else { continue }
            output[name] = PalmLandmarkPoint(x: Double(point.location.x), y: Double(point.location.y), confidence: Double(point.confidence))
        }
        return output
    }

    private func isComplete(points: [String: PalmLandmarkPoint]) -> Bool {
        let requiredKeys = [
            "VNHLKWrist",
            "VNHLKThumbTip",
            "VNHLKIndexTip",
            "VNHLKMiddleTip",
            "VNHLKRingTip",
            "VNHLKLittleTip",
            "VNHLKIndexMCP",
            "VNHLKMiddleMCP",
            "VNHLKRingMCP",
            "VNHLKLittleMCP"
        ]
        let requiredPoints = requiredKeys.compactMap { points[$0] }
        guard requiredPoints.count == requiredKeys.count else { return false }
        guard requiredPoints.allSatisfy({ $0.confidence > 0.2 }) else { return false }

        let xs = requiredPoints.map { $0.x }
        let ys = requiredPoints.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return false }
        let bbox = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
        guard bbox.width > 0.24, bbox.height > 0.42 else { return false }
        guard detectionZone.contains(CGPoint(x: bbox.midX, y: bbox.midY)) else { return false }
        guard bbox.minX >= detectionZone.minX - 0.06,
              bbox.maxX <= detectionZone.maxX + 0.06,
              bbox.minY >= detectionZone.minY - 0.06,
              bbox.maxY <= detectionZone.maxY + 0.06 else {
            return false
        }
        guard let wrist = points["VNHLKWrist"] else { return false }
        let fingerTips = [
            points["VNHLKIndexTip"],
            points["VNHLKMiddleTip"],
            points["VNHLKRingTip"],
            points["VNHLKLittleTip"]
        ].compactMap { $0 }
        guard fingerTips.allSatisfy({ $0.y > wrist.y + 0.10 }) else { return false }
        let tipSpread = (fingerTips.map { $0.x }.max() ?? 0) - (fingerTips.map { $0.x }.min() ?? 0)
        guard tipSpread > 0.16 else { return false }
        return true
    }

    private func markInvalid(_ guidance: String) {
        stableCount = max(0, stableCount - 2)
        DispatchQueue.main.async {
            self.stabilityProgress = min(1.0, Double(self.stableCount) / Double(self.requiredStableCount))
            self.statusText = "调整中"
            self.guidanceText = guidance
        }
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }
}
