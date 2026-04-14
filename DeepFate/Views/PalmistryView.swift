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
    @State private var capturedImage: UIImage?
    @State private var showFullReport = false
    @State private var reportPollingTask: Task<Void, Never>?

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
            reportPollingTask?.cancel()
        }
        .onChange(of: effectiveHandSide) { _, _ in
            detector.expectedHandSide = effectiveHandSide
            detector.resetStability()
        }
        .onChange(of: profileStore.activeProfileID) { _, _ in
            detector.expectedHandSide = effectiveHandSide
            detector.resetStability()
            result = nil
            capturedImage = nil
            showFullReport = false
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.red.opacity(0.16), lineWidth: 1)
                    )
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
                reportStatusCard(result)
                if let analysis = result.analysis, !analysis.summaryTags.isEmpty {
                    tagFlow(analysis.summaryTags)
                }
                if result.isReportReady && showFullReport, let analysis = result.analysis {
                    sectionCard(title: "总评", content: analysis.summary)
                    sectionCard(title: "生命线", content: analysis.lifeLine)
                    sectionCard(title: "智慧线", content: analysis.headLine)
                    sectionCard(title: "爱情线", content: analysis.heartLine)
                    sectionCard(title: "事业线", content: analysis.structured.careerLine)
                    sectionCard(title: "事业", content: analysis.career)
                    sectionCard(title: "财运", content: analysis.wealth)
                    sectionCard(title: "情感", content: analysis.love)
                    sectionCard(title: "健康", content: analysis.health)
                    structuredCard(analysis.structured)
                    sectionCard(title: "建议", content: analysis.advice)
                }
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

    private func reportStatusCard(_ result: PalmistryResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专属解读")
                .font(.headline)
                .foregroundStyle(Color(red: 0.34, green: 0.22, blue: 0.17))
            switch result.reportStatus {
            case .pending:
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(Color(red: 0.79, green: 0.42, blue: 0.36))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("您的专属天师正在思考中...")
                            .font(.subheadline.weight(.semibold))
                        Text("已完成掌纹分割与主线高亮，完整报告生成后可在当前页展开查看。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            case .failed:
                Text(result.reportError?.isEmpty == false ? result.reportError! : "报告生成较慢，请稍后查看")
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.54, green: 0.30, blue: 0.25))
                    .padding(14)
                    .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            case .ready:
                Text(showFullReport ? "完整报告已展开，你可以继续查看详情。" : "完整报告已生成，点击下方按钮即可展开查看。")
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.14))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground)
    }

    private func palmResultHero(_ result: PalmistryResult) -> some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.58))
                    .frame(height: 360)
                    .overlay {
                        PalmResultMediaView(
                            capturedImage: capturedImage,
                            remoteURL: result.originalImageURL,
                            lines: result.overlays
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    .overlay(
                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(0.40)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    )
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(result.overlays) { line in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: line.colorHex))
                                .frame(width: 8, height: 8)
                            Text(line.title)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.22), in: Capsule())
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.analysis?.overall ?? "已完成掌纹分割")
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

    private func tagFlow(_ tags: [String]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 90), spacing: 10)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.56, green: 0.31, blue: 0.26))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.74), in: Capsule())
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
                if result.isReportReady {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showFullReport = true
                    }
                }
            } label: {
                Text(result.isReportReady ? (showFullReport ? "完整报告已展开" : "查看完整报告") : "您的专属天师正在思考中...")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(result.isReportReady ? Color(red: 0.79, green: 0.42, blue: 0.36) : Color.white.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(!result.isReportReady || showFullReport)

            if showFullReport, result.isReportReady {
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
            }

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
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: detector.stabilityProgress)
                .tint(Color(red: 0.82, green: 0.46, blue: 0.38))
            Text("稳定进度 \(detector.stableHoldDurationText)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.85))
            Text(detector.guidanceText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
            if !detector.validationReasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(detector.validationReasons, id: \.self) { reason in
                        Text("• \(reason)")
                            .font(.caption)
                            .foregroundStyle(Color(red: 1.0, green: 0.92, blue: 0.84))
                    }
                }
            }
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
        capturedImage = frame.image
        showFullReport = false
        errorMessage = nil
        askError = nil
        do {
            let response = try await palmistryClient.segment(
                profileId: profile.id,
                handSide: effectiveHandSide,
                capturedAt: frame.capturedAt,
                image: frame.image,
                landmarks: frame.landmarks
            )
            result = response
            isAnalyzing = false
            if response.reportStatus == .pending {
                do {
                    try await palmistryClient.startReport(profileId: profile.id, readingId: response.id)
                } catch {
                    errorMessage = presentPalmistryError(error)
                }
                startReportPolling(profileId: profile.id, readingId: response.id)
            } else {
                showFullReport = response.isReportReady
            }
            return
        } catch {
            capturedImage = nil
            errorMessage = presentPalmistryError(error)
            await detector.start()
        }
        isAnalyzing = false
    }

    private func presentPalmistryError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "未连接到手相服务，请在设置页检查后端服务地址后重试。\n\(error.localizedDescription)"
        }
        return error.localizedDescription
    }

    private func resetForNewScan() {
        reportPollingTask?.cancel()
        result = nil
        capturedImage = nil
        showFullReport = false
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
                capturedImage = nil
                result = full
                showFullReport = full.isReportReady
                showHistory = false
            }
        } catch {
            await MainActor.run {
                historyError = error.localizedDescription
            }
        }
    }

    private func askAI(for result: PalmistryResult, profile: UserProfile) async {
        guard result.isReportReady else { return }
        guard let analysis = result.analysis else { return }
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
            consultRouter.askAI(withPalmistryResult: PalmistryResult(
                id: result.id,
                profileId: result.profileId,
                handSide: result.handSide,
                takenAt: result.takenAt,
                takenAtISO: result.takenAtISO,
                originalImageURL: result.originalImageURL,
                thumbnailURL: result.thumbnailURL,
                overlays: result.overlays,
                reportStatus: result.reportStatus,
                reportError: result.reportError,
                analysis: analysis
            ), profile: profile, chartText: chartText)
        }
    }

    private func startReportPolling(profileId: UUID, readingId: String) {
        reportPollingTask?.cancel()
        reportPollingTask = Task {
            for _ in 0..<24 {
                if Task.isCancelled { return }
                do {
                    let payload = try await palmistryClient.fetchReportStatus(profileId: profileId, readingId: readingId)
                    await MainActor.run {
                        if let reading = payload.result {
                            self.result = reading
                            if reading.isReportReady {
                                self.showFullReport = false
                            }
                        }
                    }
                    if payload.reportStatus == .ready || payload.reportStatus == .failed {
                        return
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await MainActor.run {
                if let current = self.result, current.reportStatus == .pending {
                    self.result = PalmistryResult(
                        id: current.id,
                        profileId: current.profileId,
                        handSide: current.handSide,
                        takenAt: current.takenAt,
                        takenAtISO: current.takenAtISO,
                        originalImageURL: current.originalImageURL,
                        thumbnailURL: current.thumbnailURL,
                        overlays: current.overlays,
                        reportStatus: .failed,
                        reportError: "报告生成较慢，请稍后查看",
                        analysis: current.analysis
                    )
                }
            }
        }
    }
}

private struct PalmLineOverlayView: View {
    let lines: [PalmLineOverlay]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(lines) { line in
                    if line.points.count >= 2 {
                        let path = Path { path in
                            let first = line.points[0]
                            path.move(to: CGPoint(x: first.x * proxy.size.width, y: first.y * proxy.size.height))
                            for point in line.points.dropFirst() {
                                path.addLine(to: CGPoint(x: point.x * proxy.size.width, y: point.y * proxy.size.height))
                            }
                        }
                        path
                            .stroke(Color(hex: line.colorHex).opacity(0.28), style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                        path
                            .stroke(Color(hex: line.colorHex), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        path
                            .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PalmResultMediaView: View {
    let capturedImage: UIImage?
    let remoteURL: URL?
    let lines: [PalmLineOverlay]

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let aspectSize = capturedImage?.size ?? CGSize(width: 3, height: 4)
            let fittedRect = AVMakeRect(aspectRatio: aspectSize, insideRect: bounds)

            ZStack {
                Color(red: 0.94, green: 0.88, blue: 0.83)

                if let capturedImage {
                    Image(uiImage: capturedImage)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .frame(width: fittedRect.width, height: fittedRect.height)
                        .position(x: fittedRect.midX, y: fittedRect.midY)

                    PalmLineOverlayView(lines: lines)
                        .frame(width: fittedRect.width, height: fittedRect.height)
                        .position(x: fittedRect.midX, y: fittedRect.midY)
                } else if let remoteURL {
                    AsyncImage(url: remoteURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .interpolation(.high)
                                .antialiased(true)
                                .scaledToFit()
                        case .failure:
                            Color(red: 0.94, green: 0.88, blue: 0.83)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            ProgressView()
                        }
                    }
                    .frame(width: fittedRect.width, height: fittedRect.height)
                    .position(x: fittedRect.midX, y: fittedRect.midY)

                    PalmLineOverlayView(lines: lines)
                        .frame(width: fittedRect.width, height: fittedRect.height)
                        .position(x: fittedRect.midX, y: fittedRect.midY)
                }
            }
        }
        .allowsHitTesting(false)
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
            // 柔和的草绿色高亮，用于描边与扫描线
            let glow = Color(red: 0.42, green: 0.76, blue: 0.54)
            let scanY = zone.minY + zone.height * (0.14 + scanProgress * 0.68)

            ZStack {
                outsideMask
                    .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))

                handPath
                    .fill(Color.white.opacity(0.020))

                handPath
                    .stroke(glow.opacity(0.20), lineWidth: 7)
                    .blur(radius: 10)

                handPath
                    .stroke(glow.opacity(0.95), style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round, dash: [11, 7]))

                handPath
                    .stroke(glow.opacity(0.55), lineWidth: 1.4)
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
                    .frame(width: zone.width * 0.96, height: 20)
                    .position(x: zone.midX, y: scanY)
                    .mask { handPath.fill(Color.white) }
                    .blur(radius: 1.4)

                Rectangle()
                    .fill(glow.opacity(0.86))
                    .frame(width: zone.width * 0.98, height: 2.2)
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
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let mirroredX = thumbOnLeft ? x : 1 - x
            return CGPoint(
                x: rect.minX + mirroredX * rect.width,
                y: rect.minY + y * rect.height
            )
        }

        var path = Path()

        // ── 手腕底部（起点）──
        path.move(to: map(0.22, 0.99))

        // ── 左侧手腕→掌根（更宽）──
        path.addCurve(to: map(0.04, 0.74),
                      control1: map(0.14, 0.99), control2: map(0.02, 0.88))

        // ── 拇指（外侧边缘，斜向左下方约45°伸出）──
        path.addCurve(to: map(-0.08, 0.58),
                      control1: map(0.02, 0.70), control2: map(-0.04, 0.64))
        path.addCurve(to: map(-0.14, 0.40),
                      control1: map(-0.11, 0.52), control2: map(-0.14, 0.46))
        // ── 拇指尖（圆润弧线）──
        path.addCurve(to: map(-0.08, 0.30),
                      control1: map(-0.14, 0.34), control2: map(-0.12, 0.30))
        // ── 拇指（内侧边缘，回到掌面）──
        path.addCurve(to: map(0.02, 0.36),
                      control1: map(-0.04, 0.30), control2: map(-0.01, 0.32))
        path.addCurve(to: map(0.10, 0.44),
                      control1: map(0.04, 0.38), control2: map(0.07, 0.42))

        // ── 虎口（位置低于小指指根 y=0.40）──
        path.addCurve(to: map(0.16, 0.50),
                      control1: map(0.12, 0.46), control2: map(0.14, 0.49))

        // ── 食指（从虎口起始，向左微倾）──
        path.addCurve(to: map(0.15, 0.04),
                      control1: map(0.16, 0.40), control2: map(0.14, 0.12))
        path.addCurve(to: map(0.25, 0.01),
                      control1: map(0.16, -0.01), control2: map(0.20, -0.03))
        path.addCurve(to: map(0.30, 0.34),
                      control1: map(0.28, 0.04), control2: map(0.30, 0.22))

        // ── 食指-中指指缝 ──
        path.addCurve(to: map(0.35, 0.36),
                      control1: map(0.30, 0.35), control2: map(0.33, 0.37))

        // ── 中指（最长）──
        path.addCurve(to: map(0.38, -0.04),
                      control1: map(0.35, 0.26), control2: map(0.37, 0.04))
        path.addCurve(to: map(0.49, -0.06),
                      control1: map(0.39, -0.08), control2: map(0.44, -0.09))
        path.addCurve(to: map(0.55, 0.34),
                      control1: map(0.53, -0.04), control2: map(0.56, 0.18))

        // ── 中指-无名指指缝 ──
        path.addCurve(to: map(0.60, 0.36),
                      control1: map(0.55, 0.35), control2: map(0.58, 0.37))

        // ── 无名指（向右微倾）──
        path.addCurve(to: map(0.64, 0.00),
                      control1: map(0.60, 0.26), control2: map(0.63, 0.08))
        path.addCurve(to: map(0.74, -0.01),
                      control1: map(0.65, -0.04), control2: map(0.70, -0.05))
        path.addCurve(to: map(0.78, 0.36),
                      control1: map(0.77, 0.02), control2: map(0.79, 0.22))

        // ── 无名指-小指指缝 ──
        path.addCurve(to: map(0.82, 0.40),
                      control1: map(0.78, 0.37), control2: map(0.80, 0.41))

        // ── 小指（向右外倾）──
        path.addCurve(to: map(0.87, 0.10),
                      control1: map(0.82, 0.32), control2: map(0.86, 0.16))
        path.addCurve(to: map(0.96, 0.09),
                      control1: map(0.88, 0.05), control2: map(0.93, 0.04))
        path.addCurve(to: map(0.97, 0.44),
                      control1: map(0.98, 0.13), control2: map(0.98, 0.32))

        // ── 右侧掌缘下行 ──
        path.addCurve(to: map(0.94, 0.74),
                      control1: map(0.97, 0.56), control2: map(0.96, 0.68))
        path.addCurve(to: map(0.74, 0.99),
                      control1: map(0.92, 0.86), control2: map(0.84, 0.98))

        // ── 手腕底部（收窄）──
        path.addCurve(to: map(0.22, 0.99),
                      control1: map(0.58, 1.01), control2: map(0.36, 1.01))

        path.closeSubpath()
        return path
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
        visualPath(in: CGRect(x: 0, y: 0, width: 1, height: 1), thumbOnLeft: thumbOnLeft).contains(point)
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
            Component(rect: orient(0.27, 0.35, 0.47, 0.42), rotation: 0),
            Component(rect: orient(0.33, 0.74, 0.32, 0.18), rotation: 0),
            Component(rect: orient(0.10, 0.36, 0.17, 0.27), rotation: thumbOnLeft ? -0.70 : 0.70),
            Component(rect: orient(0.21, 0.12, 0.12, 0.31), rotation: thumbOnLeft ? -0.04 : 0.04),
            Component(rect: orient(0.36, 0.05, 0.12, 0.38), rotation: 0),
            Component(rect: orient(0.50, 0.09, 0.11, 0.34), rotation: thumbOnLeft ? 0.03 : -0.03),
            Component(rect: orient(0.63, 0.16, 0.10, 0.26), rotation: thumbOnLeft ? 0.06 : -0.06)
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
    @Published private(set) var stableFrameCount: Int = 0
    @Published private(set) var stableHoldDuration: Double = 0
    @Published private(set) var validationReasons: [String] = []
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
    private var stableSince: CFTimeInterval?
    private var isCapturing = false
    private let requiredStableDuration: CFTimeInterval = 1.2
    private let detectionZone = CGRect(x: 0.10, y: 0.05, width: 0.80, height: 0.88)

    var stableHoldDurationText: String {
        String(format: "%.1f/%.1f 秒", stableHoldDuration, requiredStableDuration)
    }

    var isUsingFrontCamera: Bool {
        cameraPosition == .front
    }

    var guideThumbOnLeft: Bool {
        cameraPosition == .front ? expectedHandSide == .right : expectedHandSide == .left
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
        stableSince = nil
        isCapturing = false
        stabilityProgress = 0
        stableFrameCount = 0
        stableHoldDuration = 0
        validationReasons = []
        guidanceText = "识别到完整手掌后会自动拍照"
        statusText = "等待识别"
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCounter += 1
        if isCapturing { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: cameraPosition == .front ? .upMirrored : .up,
            options: [:]
        )
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            guard let observation = observations.first else {
                markInvalid("请把整只手放入画面中，避免背景干扰")
                return
            }
            let recognition = try observation.recognizedPoints(.all)
            let payload = selectedLandmarks(from: recognition)
            let reasons = validationErrors(points: payload)
            guard reasons.isEmpty else {
                markInvalid("请把整只手放入画面中，露出手腕，并让五指自然张开", reasons: reasons)
                return
            }
            stableCount += 1
            let now = CACurrentMediaTime()
            if stableSince == nil {
                stableSince = now
            }
            let elapsed = max(0, now - (stableSince ?? now))
            let progress = min(1.0, elapsed / requiredStableDuration)
            DispatchQueue.main.async {
                self.stabilityProgress = progress
                self.stableFrameCount = self.stableCount
                self.stableHoldDuration = elapsed
                self.validationReasons = []
                self.statusText = progress >= 1 ? "已锁定" : "识别中"
                self.guidanceText = progress >= 1 ? "已识别到完整手掌，正在自动拍照" : "已识别到完整手掌，请保持 1 秒稳定"
            }
            guard elapsed >= requiredStableDuration else { return }
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
            markInvalid("识别中，请调整光线和手掌位置", reasons: ["手部关键点识别不稳定", "请增加光线或降低背景干扰"])
        }
    }

    private func selectedLandmarks(from points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]) -> [String: PalmLandmarkPoint] {
        let keys: [(String, VNHumanHandPoseObservation.JointName)] = [
            ("VNHLKWrist", .wrist),
            ("VNHLKThumbTip", .thumbTip), ("VNHLKThumbIP", .thumbIP), ("VNHLKThumbMP", .thumbMP), ("VNHLKThumbCMC", .thumbCMC),
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

    private func validationErrors(points: [String: PalmLandmarkPoint]) -> [String] {
        var reasons: [String] = []
        let requiredKeys = [
            "VNHLKWrist",
            "VNHLKThumbCMC",
            "VNHLKThumbMP",
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
        let missingKeys = requiredKeys.filter { points[$0] == nil }
        if !missingKeys.isEmpty {
            if missingKeys.contains("VNHLKWrist") {
                reasons.append("手腕没有完整入框")
            }
            if missingKeys.contains("VNHLKThumbTip") || missingKeys.contains("VNHLKThumbCMC") {
                reasons.append("大拇指识别不完整")
            }
            if missingKeys.contains("VNHLKIndexTip") || missingKeys.contains("VNHLKMiddleTip") || missingKeys.contains("VNHLKRingTip") || missingKeys.contains("VNHLKLittleTip") {
                reasons.append("五指没有完整识别")
            }
            return Array(reasons.prefix(3))
        }
        let requiredPoints = requiredKeys.compactMap { points[$0] }
        if !requiredPoints.allSatisfy({ $0.confidence > 0.05 }) {
            reasons.append("手部关键点识别不稳定")
        }

        guard
            let wrist = points["VNHLKWrist"],
            let indexMCP = points["VNHLKIndexMCP"],
            let middleMCP = points["VNHLKMiddleMCP"],
            let ringMCP = points["VNHLKRingMCP"],
            let littleMCP = points["VNHLKLittleMCP"],
            let thumbCMC = points["VNHLKThumbCMC"],
            let thumbMP = points["VNHLKThumbMP"]
        else { return ["掌心关键点缺失"] }

        let palmCenter = CGPoint(
            x: CGFloat((indexMCP.x + middleMCP.x + ringMCP.x + littleMCP.x + wrist.x) / 5),
            y: CGFloat((indexMCP.y + middleMCP.y + ringMCP.y + littleMCP.y + wrist.y) / 5)
        )
        let thumbBase = CGPoint(
            x: CGFloat((thumbCMC.x + thumbMP.x) / 2),
            y: CGFloat((thumbCMC.y + thumbMP.y) / 2)
        )
        let centerInScreen = palmCenter.x > 0.05 && palmCenter.x < 0.95 && palmCenter.y > 0.05 && palmCenter.y < 0.95
        if !centerInScreen {
            reasons.append("掌心没有完整进入画面")
        }
        let thumbBaseInScreen = thumbBase.x > 0.02 && thumbBase.x < 0.98 && thumbBase.y > 0.02 && thumbBase.y < 0.98
        if !thumbBaseInScreen {
            reasons.append("大拇指根部没有完整进入画面")
        }

        let xs = requiredPoints.map { $0.x }
        let ys = requiredPoints.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return ["手部轮廓范围计算失败"]
        }
        let bbox = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
        if !(bbox.width > 0.08 && bbox.height > 0.16) {
            reasons.append("手离镜头太远，请再靠近一些")
        }
        if !(bbox.minX >= -0.03 &&
             bbox.maxX <= 1.03 &&
             bbox.minY >= -0.03 &&
             bbox.maxY <= 1.03) {
            reasons.append("整只手需要完整出现在画面里")
        }
        let fingerTips = [
            points["VNHLKIndexTip"],
            points["VNHLKMiddleTip"],
            points["VNHLKRingTip"],
            points["VNHLKLittleTip"]
        ].compactMap { $0 }
        let tipSpread = (fingerTips.map { $0.x }.max() ?? 0) - (fingerTips.map { $0.x }.min() ?? 0)
        if !(tipSpread > 0.035) {
            reasons.append("五指还需要再自然张开一些")
        }
        let mcpSpread = max(indexMCP.x, middleMCP.x, ringMCP.x, littleMCP.x) - min(indexMCP.x, middleMCP.x, ringMCP.x, littleMCP.x)
        if !(mcpSpread > 0.10) {
            reasons.append("掌根区域展开不够，请放松手掌")
        }
        let unique = Array(NSOrderedSet(array: reasons).array as? [String] ?? reasons)
        return Array(unique.prefix(3))
    }

    private func markInvalid(_ guidance: String, reasons: [String] = []) {
        stableCount = 0
        stableSince = nil
        DispatchQueue.main.async {
            self.stabilityProgress = 0
            self.stableFrameCount = self.stableCount
            self.stableHoldDuration = 0
            self.statusText = "调整中"
            self.guidanceText = guidance
            self.validationReasons = Array(reasons.prefix(3))
        }
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let orientedImage = UIImage(
            cgImage: cgImage,
            scale: 1,
            orientation: cameraPosition == .front ? .upMirrored : .up
        )
        return orientedImage.normalizedForDisplay()
    }
}

private enum PalmOverlayEstimator {
    static func build(from landmarks: [String: PalmLandmarkPoint], handSide: PalmHandSide) -> [PalmLineOverlay] {
        guard
            let wrist = point(landmarks, "VNHLKWrist"),
            let indexMCP = point(landmarks, "VNHLKIndexMCP"),
            let middleMCP = point(landmarks, "VNHLKMiddleMCP"),
            let ringMCP = point(landmarks, "VNHLKRingMCP"),
            let littleMCP = point(landmarks, "VNHLKLittleMCP"),
            let indexPIP = point(landmarks, "VNHLKIndexPIP"),
            let middlePIP = point(landmarks, "VNHLKMiddlePIP"),
            let ringPIP = point(landmarks, "VNHLKRingPIP"),
            let littlePIP = point(landmarks, "VNHLKLittlePIP"),
            let thumbCMC = point(landmarks, "VNHLKThumbCMC"),
            let thumbMP = point(landmarks, "VNHLKThumbMP")
        else {
            return []
        }

        let palmWidth = max(abs(littleMCP.x - indexMCP.x), 0.12)
        let palmHeight = max(abs(wrist.y - middleMCP.y), 0.18)
        let centerX = (indexMCP.x + middleMCP.x + ringMCP.x + littleMCP.x) / 4
        let thumbOnLeft = thumbCMC.x < centerX

        let outerMCP = thumbOnLeft ? littleMCP : indexMCP
        let innerMCP = thumbOnLeft ? indexMCP : littleMCP
        let outerPIP = thumbOnLeft ? littlePIP : indexPIP
        let innerPIP = thumbOnLeft ? indexPIP : littlePIP
        let lifeDirection: CGFloat = thumbOnLeft ? -1 : 1

        let heart = cubicPoints(
            from: [
                CGPoint(x: outerPIP.x + palmWidth * (thumbOnLeft ? 0.06 : -0.06), y: outerMCP.y + palmHeight * 0.02),
                CGPoint(x: ringPIP.x, y: ringMCP.y + palmHeight * 0.06),
                CGPoint(x: middlePIP.x, y: middleMCP.y + palmHeight * 0.06),
                CGPoint(x: innerPIP.x + palmWidth * (thumbOnLeft ? -0.02 : 0.02), y: innerMCP.y + palmHeight * 0.02)
            ],
            samples: 22
        )
        let head = cubicPoints(
            from: [
                CGPoint(x: innerMCP.x + palmWidth * 0.04 * lifeDirection, y: innerMCP.y + palmHeight * 0.12),
                CGPoint(x: middleMCP.x + palmWidth * 0.05 * lifeDirection, y: middleMCP.y + palmHeight * 0.18),
                CGPoint(x: ringMCP.x + palmWidth * 0.02 * lifeDirection, y: ringMCP.y + palmHeight * 0.24),
                CGPoint(x: outerMCP.x + palmWidth * 0.04 * (thumbOnLeft ? 1 : -1), y: outerMCP.y + palmHeight * 0.26)
            ],
            samples: 22
        )
        let career = cubicPoints(
            from: [
                CGPoint(x: centerX - palmWidth * 0.01, y: wrist.y - palmHeight * 0.05),
                CGPoint(x: centerX - palmWidth * 0.02, y: wrist.y - palmHeight * 0.26),
                CGPoint(x: centerX + palmWidth * 0.00, y: middleMCP.y + palmHeight * 0.26),
                CGPoint(x: centerX + palmWidth * 0.01, y: middleMCP.y + palmHeight * 0.02)
            ],
            samples: 20
        )
        let life = cubicPoints(
            from: [
                CGPoint(x: innerMCP.x + palmWidth * 0.02 * lifeDirection, y: innerMCP.y + palmHeight * 0.04),
                CGPoint(x: thumbCMC.x + palmWidth * 0.16 * lifeDirection, y: thumbCMC.y + palmHeight * 0.10),
                CGPoint(x: thumbMP.x + palmWidth * 0.18 * lifeDirection, y: wrist.y - palmHeight * 0.16),
                CGPoint(x: centerX + palmWidth * 0.24 * lifeDirection, y: wrist.y - palmHeight * 0.04)
            ],
            samples: 24
        )

        return [
            PalmLineOverlay(key: "heart_line", title: "爱情线", colorHex: "FF7A95", confidence: 0.8, points: heart),
            PalmLineOverlay(key: "head_line", title: "智慧线", colorHex: "7B8CFF", confidence: 0.78, points: head),
            PalmLineOverlay(key: "career_line", title: "事业线", colorHex: "F6C453", confidence: 0.76, points: career),
            PalmLineOverlay(key: "life_line", title: "生命线", colorHex: "53D3A6", confidence: 0.84, points: life)
        ]
    }

    private static func point(_ landmarks: [String: PalmLandmarkPoint], _ key: String) -> CGPoint? {
        guard let point = landmarks[key] else { return nil }
        return CGPoint(x: point.x, y: 1 - point.y)
    }

    private static func cubicPoints(from anchors: [CGPoint], samples: Int) -> [PalmOverlayPoint] {
        guard anchors.count == 4 else { return [] }
        return (0..<samples).map { index in
            let t = CGFloat(index) / CGFloat(max(samples - 1, 1))
            let point = cubicPoint(anchors[0], anchors[1], anchors[2], anchors[3], t)
            return PalmOverlayPoint(
                x: max(0, min(1, point.x)),
                y: max(0, min(1, point.y))
            )
        }
    }

    private static func cubicPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let inv = 1 - t
        let x = inv * inv * inv * p0.x
            + 3 * inv * inv * t * p1.x
            + 3 * inv * t * t * p2.x
            + t * t * t * p3.x
        let y = inv * inv * inv * p0.y
            + 3 * inv * inv * t * p1.y
            + 3 * inv * t * t * p2.y
            + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            r = 1
            g = 1
            b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}

private extension UIImage {
    func normalizedForDisplay() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let drawSize: CGSize
        switch imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            drawSize = CGSize(width: size.height, height: size.width)
        default:
            drawSize = size
        }
        let renderer = UIGraphicsImageRenderer(size: drawSize, format: format)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: drawSize)).fill()
            draw(in: CGRect(origin: .zero, size: drawSize))
        }
    }
}
