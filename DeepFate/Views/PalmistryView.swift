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
            Text("请允许相机权限后再进行手相拍照。")
        }
        .onAppear {
            detector.onCapture = { frame in
                Task { await analyze(frame: frame) }
            }
            detector.onPermissionDenied = {
                showPermissionAlert = true
            }
            detector.expectedHandSide = effectiveHandSide
            detector.prepareIfNeeded(position: detector.cameraPosition)
        }
        .onDisappear {
            detector.stop()
        }
        .onChange(of: effectiveHandSide) { _, _ in
            detector.expectedHandSide = effectiveHandSide
            detector.resetStability()
        }
        .onChange(of: profileStore.activeProfileID) { _, _ in
            detector.expectedHandSide = effectiveHandSide
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
            } else {
                Text(profile.gender == .male ? "按传统掌相的常见看法，男性先看左手，左手更偏先天与根基。" : "按传统掌相的常见看法，女性先看右手，右手更偏当下状态与外在应验。")
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

                HandGuideOverlay(labelSide: effectiveHandSide, thumbOnLeft: detector.guideThumbOnLeft, progress: detector.stabilityProgress)
                    .padding(24)

                VStack {
                    HStack {
                        statusPill(icon: "hand.raised", text: effectiveHandSide.title)
                        Spacer()
                        Button {
                            Task { await detector.toggleCamera() }
                        } label: {
                            statusPill(
                                icon: "camera.rotate",
                                text: detector.cameraPosition == .back ? "切前置" : "切后置"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(detector.isSwitchingCamera || isAnalyzing)
                        .opacity(detector.isSwitchingCamera || isAnalyzing ? 0.55 : 1)
                        statusPill(icon: detector.isSwitchingCamera ? "arrow.triangle.2.circlepath" : "camera.aperture", text: detector.statusText)
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
            .frame(height: 520)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func actionHints(profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拍摄要求")
                .font(.headline)
                .foregroundStyle(Color(red: 0.34, green: 0.22, blue: 0.17))
            hintRow("1", text: "仅允许单手入镜，掌心朝向镜头，尽量五指自然张开。")
            hintRow("2", text: "前置和后置摄像头都可用，优先选择掌纹更清晰、反光更少的一侧。")
            hintRow("3", text: "戒指和美甲可以保留，但请保证掌纹区域清晰、不要被阴影遮挡。")
            hintRow("4", text: profile.gender == .male ? "当前默认识别左手。传统掌相常以“男左”为先，偏看先天根基与底盘。"
                : profile.gender == .female ? "当前默认识别右手。传统掌相常以“女右”为先，偏看当下状态与外在应验。"
                : "未设置性别时不强制左右手，你可以按实际需求手动切换。")
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
    let labelSide: PalmHandSide
    let thumbOnLeft: Bool
    let progress: Double
    @State private var scanProgress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let zone = CGRect(x: size.width * 0.10, y: size.height * 0.06, width: size.width * 0.80, height: size.height * 0.86)
            let handPath = PalmGuideGeometry.visualPath(in: zone, thumbOnLeft: thumbOnLeft)
            let outsideMask = Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addPath(handPath)
            }
            let glow = Color(red: 0.96, green: 0.82, blue: 0.56)
            let scanY = zone.minY + zone.height * (0.14 + scanProgress * 0.68)

            ZStack {
                outsideMask
                    .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))

                handPath
                    .fill(Color.white.opacity(0.025))

                handPath
                    .stroke(Color.white.opacity(0.14), lineWidth: 7)
                    .blur(radius: 10)

                handPath
                    .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round, dash: [10, 8]))

                handPath
                    .stroke(glow.opacity(0.28), lineWidth: 1.2)
                    .blur(radius: 2)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                glow.opacity(0.10),
                                glow.opacity(0.68),
                                glow.opacity(0.12),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: zone.width * 0.74, height: 20)
                    .position(x: zone.midX, y: scanY)
                    .mask { handPath.fill(Color.white) }
                    .blur(radius: 1.4)

                Rectangle()
                    .fill(glow.opacity(0.72))
                    .frame(width: zone.width * 0.58, height: 2)
                    .position(x: zone.midX, y: scanY)
                    .mask { handPath.fill(Color.white) }
                    .shadow(color: glow.opacity(0.75), radius: 10)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(glow, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: zone.width * 0.92, height: zone.width * 0.92)
                    .shadow(color: glow.opacity(0.38), radius: 10)

                VStack(spacing: 6) {
                    Text(labelSide.title)
                        .font(.system(.title3, design: .serif).weight(.semibold))
                    Text("请将整只手放入掌形引导框")
                        .font(.footnote)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.26), in: Capsule())
                .offset(y: zone.maxY - size.height / 2 - 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                scanProgress = 0
                withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: true)) {
                    scanProgress = 1
                }
            }
        }
    }
}

private struct PalmCameraPreviewView: UIViewRepresentable {
    @ObservedObject var detector: PalmCaptureDetector

    func makeUIView(context: Context) -> PalmCameraPreviewContainerView {
        let view = PalmCameraPreviewContainerView()
        view.attach(session: detector.session, isFront: detector.isUsingFrontCamera)
        return view
    }

    func updateUIView(_ uiView: PalmCameraPreviewContainerView, context: Context) {
        uiView.attach(session: detector.session, isFront: detector.isUsingFrontCamera)
    }
}

private enum PalmGuideGeometry {
    private struct Component {
        let rect: CGRect
        let rotation: CGFloat
    }

    static func visualPath(in rect: CGRect, thumbOnLeft: Bool) -> Path {
        outlinePath(in: rect, thumbOnLeft: thumbOnLeft, expansion: 1.0)
    }

    static func detectionPath(in rect: CGRect, thumbOnLeft: Bool) -> Path {
        var path = Path()
        for component in detectionComponents(in: rect, thumbOnLeft: thumbOnLeft) {
            let rounded = Path(roundedRect: component.rect, cornerSize: CGSize(width: component.rect.width / 2, height: component.rect.width / 2))
            let transformed = rounded.applying(
                CGAffineTransform(translationX: component.rect.midX, y: component.rect.midY)
                    .rotated(by: component.rotation)
                    .translatedBy(x: -component.rect.midX, y: -component.rect.midY)
            )
            path.addPath(transformed)
        }
        return path
    }

    static func contains(_ point: CGPoint, thumbOnLeft: Bool) -> Bool {
        detectionPath(in: CGRect(x: 0, y: 0, width: 1, height: 1), thumbOnLeft: thumbOnLeft).contains(point)
    }

    private static func outlinePath(in rect: CGRect, thumbOnLeft: Bool, expansion: CGFloat) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)

        func mapped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let mirroredX = thumbOnLeft ? x : 1 - x
            let base = CGPoint(x: rect.minX + mirroredX * rect.width, y: rect.minY + y * rect.height)
            let dx = (base.x - center.x) * expansion
            let dy = (base.y - center.y) * expansion
            return CGPoint(x: center.x + dx, y: center.y + dy)
        }

        var path = Path()
        path.move(to: mapped(0.66, 0.98))
        path.addCurve(to: mapped(0.34, 0.98), control1: mapped(0.57, 1.00), control2: mapped(0.44, 1.00))
        path.addCurve(to: mapped(0.21, 0.84), control1: mapped(0.28, 0.96), control2: mapped(0.21, 0.91))
        path.addCurve(to: mapped(0.17, 0.64), control1: mapped(0.20, 0.77), control2: mapped(0.17, 0.71))
        path.addCurve(to: mapped(0.07, 0.56), control1: mapped(0.12, 0.61), control2: mapped(0.08, 0.60))
        path.addCurve(to: mapped(0.12, 0.43), control1: mapped(0.03, 0.52), control2: mapped(0.03, 0.45))
        path.addCurve(to: mapped(0.19, 0.35), control1: mapped(0.15, 0.40), control2: mapped(0.17, 0.37))
        path.addCurve(to: mapped(0.22, 0.18), control1: mapped(0.20, 0.31), control2: mapped(0.19, 0.22))
        path.addCurve(to: mapped(0.29, 0.13), control1: mapped(0.23, 0.14), control2: mapped(0.26, 0.12))
        path.addCurve(to: mapped(0.32, 0.31), control1: mapped(0.31, 0.14), control2: mapped(0.34, 0.25))
        path.addCurve(to: mapped(0.40, 0.07), control1: mapped(0.31, 0.23), control2: mapped(0.34, 0.10))
        path.addCurve(to: mapped(0.48, 0.04), control1: mapped(0.42, 0.04), control2: mapped(0.45, 0.03))
        path.addCurve(to: mapped(0.52, 0.31), control1: mapped(0.52, 0.07), control2: mapped(0.54, 0.24))
        path.addCurve(to: mapped(0.60, 0.10), control1: mapped(0.51, 0.23), control2: mapped(0.54, 0.11))
        path.addCurve(to: mapped(0.67, 0.08), control1: mapped(0.62, 0.07), control2: mapped(0.65, 0.07))
        path.addCurve(to: mapped(0.70, 0.33), control1: mapped(0.70, 0.11), control2: mapped(0.72, 0.26))
        path.addCurve(to: mapped(0.78, 0.18), control1: mapped(0.69, 0.27), control2: mapped(0.73, 0.18))
        path.addCurve(to: mapped(0.85, 0.21), control1: mapped(0.80, 0.16), control2: mapped(0.84, 0.17))
        path.addCurve(to: mapped(0.84, 0.47), control1: mapped(0.86, 0.26), control2: mapped(0.86, 0.38))
        path.addCurve(to: mapped(0.82, 0.78), control1: mapped(0.84, 0.58), control2: mapped(0.86, 0.71))
        path.addCurve(to: mapped(0.66, 0.98), control1: mapped(0.80, 0.90), control2: mapped(0.74, 0.98))
        path.closeSubpath()
        return path
    }

    private static func detectionComponents(in rect: CGRect, thumbOnLeft: Bool) -> [Component] {
        func orient(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            let originX = thumbOnLeft ? x : (1 - x - width)
            return CGRect(
                x: rect.minX + originX * rect.width,
                y: rect.minY + y * rect.height,
                width: width * rect.width,
                height: height * rect.height
            )
        }

        return [
            Component(rect: orient(0.26, 0.35, 0.48, 0.42), rotation: 0),
            Component(rect: orient(0.32, 0.73, 0.34, 0.19), rotation: 0),
            Component(rect: orient(0.11, 0.38, 0.18, 0.28), rotation: thumbOnLeft ? -0.78 : 0.78),
            Component(rect: orient(0.20, 0.12, 0.13, 0.33), rotation: thumbOnLeft ? -0.04 : 0.04),
            Component(rect: orient(0.35, 0.05, 0.13, 0.39), rotation: 0),
            Component(rect: orient(0.50, 0.09, 0.12, 0.35), rotation: thumbOnLeft ? 0.03 : -0.03),
            Component(rect: orient(0.63, 0.16, 0.11, 0.27), rotation: thumbOnLeft ? 0.06 : -0.06)
        ]
    }
}

private final class PalmCameraPreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func attach(session: AVCaptureSession, isFront: Bool) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.connection?.videoRotationAngle = 90
        previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        previewLayer.connection?.isVideoMirrored = isFront
    }
}

private struct PalmCapturedFrame {
    let image: UIImage
    let landmarks: [String: PalmLandmarkPoint]
    let capturedAt: Date
}

private final class PalmCaptureDetector: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published private(set) var guidanceText: String = "将整只手放入引导框，稳定后会自动拍照"
    @Published private(set) var statusText: String = "等待识别"
    @Published private(set) var stabilityProgress: Double = 0
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var isSwitchingCamera: Bool = false

    let session = AVCaptureSession()
    var expectedHandSide: PalmHandSide = .right

    var onCapture: ((PalmCapturedFrame) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "PalmCaptureDetector.queue")
    private let context = CIContext(options: nil)
    private var currentInput: AVCaptureDeviceInput?
    private var didConfigure = false
    private var frameCounter = 0
    private var stableCount = 0
    private var isCapturing = false
    private let requiredStableCount = 5
    private let detectionZone = CGRect(x: 0.10, y: 0.05, width: 0.80, height: 0.88)

    var isUsingFrontCamera: Bool {
        cameraPosition == .front
    }

    var guideThumbOnLeft: Bool {
        cameraPosition == .front ? expectedHandSide == .left : expectedHandSide == .right
    }

    func prepareIfNeeded(position: AVCaptureDevice.Position) {
        guard !didConfigure else { return }
        cameraPosition = position
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer {
            session.commitConfiguration()
            didConfigure = true
        }

        guard configureInput(position: position) else {
            return
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.connection(with: .video)?.videoRotationAngle = 90
        output.connection(with: .video)?.isVideoMirrored = position == .front
    }

    private func configureInput(position: AVCaptureDevice.Position) -> Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: position
        )
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return false
        }

        let previousInput = currentInput
        if let previousInput {
            session.removeInput(previousInput)
        }

        guard session.canAddInput(input) else {
            if let previousInput, session.canAddInput(previousInput) {
                session.addInput(previousInput)
                currentInput = previousInput
            }
            return false
        }

        session.addInput(input)
        currentInput = input
        return true
    }

    @MainActor
    func switchCamera(to position: AVCaptureDevice.Position) async {
        if isSwitchingCamera { return }
        if !didConfigure {
            prepareIfNeeded(position: position)
            cameraPosition = position
        }
        guard cameraPosition != position || currentInput == nil else {
            resetStability()
            statusText = position == .front ? "前置识别中" : "后置识别中"
            return
        }

        isSwitchingCamera = true
        statusText = "切换中"
        let wasRunning = session.isRunning
        let switched = await withCheckedContinuation { continuation in
            queue.async {
                self.session.beginConfiguration()
                let success = self.configureInput(position: position)
                if let connection = self.output.connection(with: .video) {
                    connection.videoRotationAngle = 90
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = position == .front
                }
                self.session.commitConfiguration()
                if wasRunning && !self.session.isRunning {
                    self.session.startRunning()
                }
                continuation.resume(returning: success)
            }
        }
        resetStability()
        if switched {
            cameraPosition = position
            statusText = position == .front ? "前置识别中" : "后置识别中"
        } else {
            statusText = "切换失败"
        }
        isSwitchingCamera = false
    }

    @MainActor
    func toggleCamera() async {
        let next: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        await switchCamera(to: next)
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
        prepareIfNeeded(position: cameraPosition)
        resetStability()
        guard !session.isRunning else {
            statusText = cameraPosition == .front ? "前置识别中" : "后置识别中"
            return
        }
        let session = session
        queue.async {
            session.startRunning()
        }
        statusText = cameraPosition == .front ? "前置识别中" : "后置识别中"
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
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: cameraPosition == .front ? .leftMirrored : .right, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            guard let observation = observations.first else {
                markInvalid("请把掌心对准引导框，避免背景干扰")
                return
            }
            let recognition = try observation.recognizedPoints(.all)
            let payload = selectedLandmarks(from: recognition)
            guard isComplete(points: payload) else {
                markInvalid("请把手掌再靠近一些，并让五指略微张开")
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
        guard requiredPoints.allSatisfy({ $0.confidence > 0.06 }) else { return false }
        for point in requiredPoints {
            guard PalmGuideGeometry.contains(CGPoint(x: point.x, y: point.y), thumbOnLeft: guideThumbOnLeft) else {
                return false
            }
        }

        let xs = requiredPoints.map { $0.x }
        let ys = requiredPoints.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return false }
        let bbox = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
        guard bbox.width > 0.11, bbox.height > 0.18 else { return false }
        guard detectionZone.contains(CGPoint(x: bbox.midX, y: bbox.midY)) else { return false }
        guard bbox.minX >= detectionZone.minX - 0.12,
              bbox.maxX <= detectionZone.maxX + 0.12,
              bbox.minY >= detectionZone.minY - 0.12,
              bbox.maxY <= detectionZone.maxY + 0.12 else {
            return false
        }
        guard let wrist = points["VNHLKWrist"] else { return false }
        let fingerTips = [
            points["VNHLKIndexTip"],
            points["VNHLKMiddleTip"],
            points["VNHLKRingTip"],
            points["VNHLKLittleTip"]
        ].compactMap { $0 }
        let averageTipY = fingerTips.map { $0.y }.reduce(0, +) / Double(fingerTips.count)
        guard averageTipY > wrist.y + 0.015 else { return false }
        let tipSpread = (fingerTips.map { $0.x }.max() ?? 0) - (fingerTips.map { $0.x }.min() ?? 0)
        guard tipSpread > 0.045 else { return false }
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
        return UIImage(
            cgImage: cgImage,
            scale: 1,
            orientation: cameraPosition == .front ? .leftMirrored : .right
        )
    }
}
