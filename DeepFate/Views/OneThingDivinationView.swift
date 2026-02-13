import SwiftUI
import UIKit

struct OneThingDivinationView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var consultRouter: ConsultRouter
    @Environment(\.dismiss) private var dismiss

    @State private var todayResult: OneThingResult?
    @State private var activeQuestion = ""
    @State private var questionInput = ""
    @State private var tosses: [[String]] = []
    @State private var coinFaces: [CoinFace] = [.front, .back, .front]
    @State private var startedAt = Date()
    @State private var spinAngle: Double = 0

    @State private var isLoadingToday = false
    @State private var isShaking = false
    @State private var isSubmitting = false
    @State private var isAskingAI = false
    @State private var showQuestionSheet = false
    @State private var showProfilePicker = false
    @State private var showSixRelativesSheet = false
    @State private var errorMessage: String?
    @State private var askError: String?

    private let client = OneThingClient()
    private let chartClient = ChartClient()

    private var activeProfile: UserProfile? {
        guard let id = profileStore.activeProfileID else { return nil }
        return profileStore.profiles.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let profile = activeProfile {
                content(profile: profile)
            } else {
                emptyState
            }
        }
        .navigationTitle("一事一测")
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
        .sheet(isPresented: $showQuestionSheet) {
            questionInputSheet
                .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $showSixRelativesSheet) {
            if let result = todayResult {
                sixRelativesSheet(result)
            }
        }
        .onAppear {
            guard let profile = activeProfile else { return }
            Task { await loadToday(for: profile) }
        }
        .onChange(of: profileStore.activeProfileID) { _, _ in
            guard let profile = activeProfile else { return }
            Task { await loadToday(for: profile) }
        }
    }

    private func content(profile: UserProfile) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.95, blue: 0.9),
                    Color(red: 0.93, green: 0.9, blue: 0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if let result = todayResult {
                resultView(result: result, profile: profile)
            } else {
                castingView(profile: profile)
            }
        }
    }

    private func castingView(profile: UserProfile) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoadingToday {
                    ProgressView("正在读取今日卦象…")
                        .padding(.top, 40)
                } else {
                    if activeQuestion.isEmpty {
                        VStack(spacing: 10) {
                            Text("先输入你要测算的一件事")
                                .font(.headline)
                            Button("输入测算问题") {
                                showQuestionSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 30)
                    } else {
                        questionCard
                        sixYaoBoard
                        coinArea
                        actionArea(profile: profile)
                    }
                }

                if let message = errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("所问之事")
                .font(.caption)
                .foregroundStyle(Color(red: 0.46, green: 0.38, blue: 0.3))
            Text(activeQuestion)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(red: 0.24, green: 0.19, blue: 0.15))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.82))
        )
    }

    private var sixYaoBoard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("六爻")
                .font(.headline)
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.18))

            VStack(spacing: 8) {
                ForEach((1...6).reversed(), id: \.self) { lineNo in
                    let toss = (lineNo - 1) < tosses.count ? tosses[lineNo - 1] : nil
                    sixYaoRow(lineNo: lineNo, toss: toss)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.93).opacity(0.92))
            )
        }
    }

    private func sixYaoRow(lineNo: Int, toss: [String]?) -> some View {
        let line = linePreview(from: toss)
        return HStack(spacing: 10) {
            Text(lineName(lineNo))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.43, green: 0.34, blue: 0.28))
                .frame(width: 40, alignment: .leading)
            Text(line.symbol)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.22, green: 0.18, blue: 0.14))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(line.type)
                .font(.caption)
                .foregroundStyle(Color(red: 0.56, green: 0.45, blue: 0.36))
                .frame(width: 36, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coinArea: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { index in
                    CoinFaceView(face: coinFaces[index], spinAngle: spinAngle + Double(index) * 22)
                }
            }
            Text("摇卦进度：\(tosses.count)/6")
                .font(.footnote)
                .foregroundStyle(Color(red: 0.45, green: 0.36, blue: 0.3))
        }
        .padding(.top, 8)
    }

    private func actionArea(profile: UserProfile) -> some View {
        VStack(spacing: 12) {
            Button {
                shakeOnce(profile: profile)
            } label: {
                Text(buttonTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(red: 0.58, green: 0.36, blue: 0.27))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isShaking || isSubmitting || tosses.count >= 6 || activeQuestion.isEmpty)

            if tosses.count < 6 {
                Button("重置重摇") {
                    tosses = []
                    errorMessage = nil
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var buttonTitle: String {
        if isSubmitting { return "排卦中..." }
        if isShaking { return "摇卦中..." }
        if tosses.count >= 6 { return "卦象已成" }
        return "摇一摇"
    }

    private func resultView(result: OneThingResult, profile: UserProfile) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.question)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(red: 0.24, green: 0.19, blue: 0.15))
                    Text("起卦：\(result.startedAt)")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.49, green: 0.4, blue: 0.33))
                    Text("结论：\(result.analysis.conclusion)")
                        .font(.headline)
                        .foregroundStyle(colorForConclusion(result.analysis.conclusion))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.88))
                )

                Button {
                    showSixRelativesSheet = true
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("卦象速览（点击查看六亲排布）")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 0.29, green: 0.23, blue: 0.18))
                        HStack(alignment: .top, spacing: 12) {
                            hexagramMini(result.hexagram.primary)
                            Image(systemName: "arrow.right")
                                .font(.caption.bold())
                                .foregroundStyle(Color(red: 0.53, green: 0.44, blue: 0.36))
                                .padding(.top, 26)
                            hexagramMini(result.hexagram.changed)
                        }
                        Text("动爻：\(movingLinesText(result.hexagram.movingLines))")
                            .font(.footnote)
                            .foregroundStyle(Color(red: 0.53, green: 0.44, blue: 0.36))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(red: 0.99, green: 0.97, blue: 0.93).opacity(0.95))
                    )
                }
                .buttonStyle(.plain)

                analysisCard(title: "结论", content: result.analysis.summary)
                Text("向上滑动查看详细五行分析与建议")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.52, green: 0.42, blue: 0.34))
                analysisCard(title: "五行分析", content: result.analysis.fiveElements)
                analysisCard(title: "建议", content: result.analysis.advice)

                if let askError {
                    Text(askError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await askAI(profile: profile, result: result) }
                } label: {
                    Text(isAskingAI ? "生成中..." : "问问AI")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.53, green: 0.29, blue: 0.68))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isAskingAI)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
    }

    private func analysisCard(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(red: 0.3, green: 0.24, blue: 0.18))
            Text(content)
                .font(.body)
                .foregroundStyle(Color(red: 0.2, green: 0.16, blue: 0.14))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.88))
        )
    }

    private func hexagramMini(_ hexagram: OneThingHexagram) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hexagram.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.26, green: 0.2, blue: 0.16))
            Text("\(hexagram.upperTrigram)上\(hexagram.lowerTrigram)下")
                .font(.caption)
                .foregroundStyle(Color(red: 0.5, green: 0.42, blue: 0.34))
            VStack(spacing: 4) {
                ForEach(Array(hexagram.linePattern.enumerated()), id: \.offset) { _, pattern in
                    HexagramLineShape(isYang: pattern == "阳")
                }
            }
        }
    }

    private func questionInputSheet() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("输入要测算的事情")
                .font(.headline)
            ZStack(alignment: .leading) {
                if questionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("例如：这次面试能顺利通过吗？")
                        .foregroundStyle(Color(red: 0.68, green: 0.61, blue: 0.56))
                        .padding(.horizontal, 12)
                }
                TextField("", text: $questionInput, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.93))
            )
            Text("提示：问题越聚焦，卦象解读越准确。")
                .font(.caption)
                .foregroundStyle(Color(red: 0.6, green: 0.52, blue: 0.46))

            HStack(spacing: 8) {
                ForEach(sampleQuestions, id: \.self) { sample in
                    Button(sample) {
                        questionInput = sample
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.94, green: 0.9, blue: 0.86)))
                }
            }

            Button {
                beginCasting()
            } label: {
                Text("开始摇卦")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color(red: 0.58, green: 0.36, blue: 0.27))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(questionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(18)
        .presentationDetents([.height(300)])
    }

    private func sixRelativesSheet(_ result: OneThingResult) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("本卦：\(result.hexagram.primary.name)  变卦：\(result.hexagram.changed.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.18))

                    ForEach(result.analysis.sixRelatives.sorted(by: { $0.line > $1.line })) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(lineName(item.line)) · \(item.role)")
                                .font(.headline)
                                .foregroundStyle(Color(red: 0.26, green: 0.2, blue: 0.16))
                            Text("五行：\(item.element)  ·  阴阳：\(item.yinYang)  ·  \(item.moving ? "动爻" : "静爻")")
                                .font(.caption)
                                .foregroundStyle(Color(red: 0.51, green: 0.42, blue: 0.35))
                            Text(item.note)
                                .font(.subheadline)
                                .foregroundStyle(Color(red: 0.22, green: 0.18, blue: 0.14))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.99, green: 0.97, blue: 0.93))
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("六亲排布")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        showSixRelativesSheet = false
                    }
                }
            }
            .background(Color(red: 0.96, green: 0.93, blue: 0.88))
        }
    }

    private var profilePickerSheet: some View {
        NavigationStack {
            List(profileStore.profiles) { profile in
                Button {
                    profileStore.setActive(profile.id)
                    showProfilePicker = false
                    Task { await loadToday(for: profile) }
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

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("请先创建档案后再进行一事一测")
                .foregroundStyle(.secondary)
            NavigationLink("去档案馆") {
                ArchiveView()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private var sampleQuestions: [String] {
        ["这次面试结果如何？", "近期换工作合适吗？", "这段关系会有进展吗？"]
    }

    private func beginCasting() {
        let trimmed = questionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeQuestion = trimmed
        tosses = []
        startedAt = Date()
        errorMessage = nil
        todayResult = nil
        showQuestionSheet = false
    }

    private func shakeOnce(profile: UserProfile) {
        guard !isShaking, !isSubmitting, tosses.count < 6, !activeQuestion.isEmpty else { return }
        isShaking = true
        errorMessage = nil
        withAnimation(.easeInOut(duration: 0.55)) {
            spinAngle += 360
        }
        let nextFaces = (0..<3).map { _ in Bool.random() ? CoinFace.front : CoinFace.back }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            coinFaces = nextFaces
            tosses.append(nextFaces.map(\.rawValue))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            isShaking = false
            if tosses.count == 6 {
                isSubmitting = true
                Task { await submitCasting(profile: profile) }
            }
        }
    }

    private func submitCasting(profile: UserProfile) async {
        do {
            let result = try await client.cast(
                profileId: profile.id,
                question: activeQuestion,
                startedAt: startedAt,
                tosses: tosses
            )
            await MainActor.run {
                todayResult = result
                isSubmitting = false
                askError = nil
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    private func loadToday(for profile: UserProfile) async {
        await MainActor.run {
            isLoadingToday = true
            errorMessage = nil
            todayResult = nil
            tosses = []
            activeQuestion = ""
            questionInput = ""
        }
        do {
            let result = try await client.fetchToday(profileId: profile.id)
            await MainActor.run {
                todayResult = result
                activeQuestion = result.question
                isLoadingToday = false
                showQuestionSheet = false
            }
        } catch let err as OneThingClientError {
            await MainActor.run {
                isLoadingToday = false
                switch err {
                case let .serverError(code, _) where code == 404:
                    showQuestionSheet = true
                default:
                    errorMessage = err.localizedDescription
                }
            }
        } catch {
            await MainActor.run {
                isLoadingToday = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func askAI(profile: UserProfile, result: OneThingResult) async {
        guard !isAskingAI else { return }
        isAskingAI = true
        askError = nil
        let chartText = await fetchChartText(for: profile)
        await MainActor.run {
            consultRouter.askAI(withOneThingResult: result, profile: profile, chartText: chartText)
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
                askError = "未能获取八字信息，将仅根据卦象提问。"
            }
            return nil
        }
    }

    private func linePreview(from toss: [String]?) -> (symbol: String, type: String) {
        guard let toss, toss.count == 3 else {
            return ("────  ────", "待摇")
        }
        let heads = toss.filter { $0 == CoinFace.front.rawValue }.count
        let sum = heads * 3 + (3 - heads) * 2
        switch sum {
        case 6:
            return ("────  ────", "老阴")
        case 7:
            return ("────────", "少阳")
        case 8:
            return ("────  ────", "少阴")
        case 9:
            return ("────────", "老阳")
        default:
            return ("────  ────", "待摇")
        }
    }

    private func movingLinesText(_ lines: [Int]) -> String {
        if lines.isEmpty { return "无" }
        return lines.sorted().map { "\($0)" }.joined(separator: "、")
    }

    private func lineName(_ line: Int) -> String {
        switch line {
        case 1: return "初爻"
        case 2: return "二爻"
        case 3: return "三爻"
        case 4: return "四爻"
        case 5: return "五爻"
        case 6: return "上爻"
        default: return "\(line)爻"
        }
    }

    private func colorForConclusion(_ value: String) -> Color {
        switch value {
        case "吉":
            return Color(red: 0.16, green: 0.46, blue: 0.25)
        case "凶":
            return Color(red: 0.66, green: 0.2, blue: 0.18)
        default:
            return Color(red: 0.54, green: 0.42, blue: 0.26)
        }
    }
}

private struct CoinFaceView: View {
    let face: CoinFace
    let spinAngle: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.89, green: 0.75, blue: 0.45),
                            Color(red: 0.66, green: 0.5, blue: 0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.45), lineWidth: 1.2)
                )
            Text(face.rawValue)
                .font(.title2.bold())
                .foregroundStyle(Color(red: 0.32, green: 0.2, blue: 0.12))
        }
        .frame(width: 74, height: 74)
        .rotation3DEffect(.degrees(spinAngle), axis: (x: 0, y: 1, z: 0))
        .shadow(color: Color.black.opacity(0.22), radius: 7, x: 0, y: 4)
    }
}

private struct HexagramLineShape: View {
    let isYang: Bool

    var body: some View {
        if isYang {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(red: 0.22, green: 0.16, blue: 0.14))
                .frame(width: 110, height: 5)
        } else {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(red: 0.22, green: 0.16, blue: 0.14))
                    .frame(width: 50, height: 5)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(red: 0.22, green: 0.16, blue: 0.14))
                    .frame(width: 50, height: 5)
            }
        }
    }
}
