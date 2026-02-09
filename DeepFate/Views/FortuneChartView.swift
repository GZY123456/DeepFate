import SwiftUI

// MARK: - 命理详批页：浅色背景 + 深色文字，保证对比度
private let chartBackgroundLight = Color(red: 0.96, green: 0.94, blue: 0.88)
private let chartBackgroundDark = Color(red: 0.14, green: 0.14, blue: 0.16)
private let rowSeparatorLight = Color(red: 0.82, green: 0.78, blue: 0.72)
private let rowSeparatorDark = Color(red: 0.28, green: 0.28, blue: 0.30)
private let labelSecondaryLight = Color(red: 0.45, green: 0.42, blue: 0.38)
private let labelSecondaryDark = Color(red: 0.65, green: 0.63, blue: 0.60)
// 表格行交替背景（浅色）
private let tableRowBgALight = Color(red: 1.0, green: 0.99, blue: 0.96)
private let tableRowBgBLight = Color(red: 0.96, green: 0.94, blue: 0.90)
private let tableRowBgADark = Color(red: 0.18, green: 0.18, blue: 0.20)
private let tableRowBgBDark = Color(red: 0.22, green: 0.22, blue: 0.24)
// 表格内文字：一律深色，不随系统深色模式变白
private let chartTextPrimary = Color(red: 0.12, green: 0.10, blue: 0.08)
private let chartTextLabel = Color(red: 0.32, green: 0.28, blue: 0.24)
private let chartTextPlaceholder = Color(red: 0.48, green: 0.44, blue: 0.40)

struct FortuneChartView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var consultRouter: ConsultRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedProfile: UserProfile?
    @State private var chartText: String = ""
    @State private var baziModel: BaZiModel?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showProfilePicker = false
    @State private var loadTask: Task<Void, Never>?

    private let chartClient = ChartClient()

    private var effectiveProfile: UserProfile? {
        selectedProfile ?? profileStore.profiles.first { $0.id == profileStore.activeProfileID }
    }

    // 命理详批页统一使用浅色背景
    private var chartBackground: Color { chartBackgroundLight }
    private var rowSeparator: Color { rowSeparatorLight }
    private var labelSecondary: Color { labelSecondaryLight }
    private var rowBgA: Color { tableRowBgALight }
    private var rowBgB: Color { tableRowBgBLight }

    var body: some View {
        Group {
            if let profile = effectiveProfile {
                chartContent(profile: profile)
            } else {
                emptyState
            }
        }
        .navigationTitle("命理详批")
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
            if selectedProfile == nil, let p = effectiveProfile {
                loadChart(for: p)
            }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func chartContent(profile: UserProfile) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let err = errorMessage {
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .padding()
                    }
                    if isLoading {
                        ProgressView("正在排盘…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if let bazi = baziModel {
                        baziHeader(profile: profile, bazi: bazi)
                        BaziChartGridView(bazi: bazi, rowSeparator: rowSeparator, textLabel: chartTextLabel, textPrimary: chartTextPrimary, textPlaceholder: chartTextPlaceholder, rowBgA: rowBgA, rowBgB: rowBgB)
                    } else if !chartText.isEmpty {
                        Text(chartText)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .background(chartBackground)

            Button {
                askAI()
            } label: {
                Text("问问AI")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(Color.purple)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .disabled(chartText.isEmpty)
        }
        .background(chartBackground)
    }

    private func baziHeader(profile: UserProfile, bazi: BaZiModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(chartTextPrimary)
            Text("真太阳时 \(bazi.trueSolarLabel)")
                .font(.system(size: 12))
                .foregroundStyle(chartTextLabel)
                .lineLimit(1)
            if let term = bazi.solarTermLabel, !term.isEmpty {
                Text("出生节气 \(term)")
                    .font(.system(size: 12))
                    .foregroundStyle(chartTextLabel)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("请先在档案馆添加档案后再排盘")
                .font(.body)
                .foregroundStyle(.secondary)
            NavigationLink("去档案馆") {
                ArchiveView()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .background(chartBackground)
    }

    private var profilePickerSheet: some View {
        NavigationStack {
            List(profileStore.profiles) { profile in
                Button {
                    selectedProfile = profile
                    showProfilePicker = false
                    loadChart(for: profile)
                } label: {
                    HStack {
                        Text(profile.name)
                        if profile.id == effectiveProfile?.id {
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

    private func loadChart(for profile: UserProfile) {
        loadTask?.cancel()
        let comp = profile.trueSolarComponents
        let year = comp.year ?? 2000
        let month = comp.month ?? 1
        let day = comp.day ?? 1
        let hour = comp.hour ?? 0
        let minute = comp.minute ?? 0
        let longitude = profile.location.longitude
        let gender = profile.gender.rawValue

        isLoading = true
        errorMessage = nil
        baziModel = nil
        loadTask = Task {
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
                await MainActor.run {
                    chartText = result.content
                    baziModel = result.bazi
                    isLoading = false
                    loadTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    isLoading = false
                    loadTask = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                    loadTask = nil
                }
            }
        }
    }

    private func askAI() {
        guard !chartText.isEmpty else { return }
        consultRouter.askAI(withChartText: chartText)
        dismiss()
    }
}

// MARK: - 八字表格网格（统一深色文字，保证浅底可读）
private struct BaziChartGridView: View {
    let bazi: BaZiModel
    let rowSeparator: Color
    let textLabel: Color
    let textPrimary: Color
    let textPlaceholder: Color
    let rowBgA: Color
    let rowBgB: Color

    private let labelColumnWidth: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            // 表头：年柱 月柱 日柱 时柱
            HStack(alignment: .center, spacing: 0) {
                Color.clear
                    .frame(width: labelColumnWidth)
                ForEach(bazi.pillarTitles, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(textLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.leading, 6)
                }
            }
            .background(rowBgA)
            divider
            rowLabel("干神", cells: bazi.pillars.map { $0.ganShen.isEmpty ? "—" : $0.ganShen }, large: false)
                .background(rowBgB)
            divider
            rowGanZhi(title: "天干", items: bazi.pillars.map(\.gan), large: true)
                .background(rowBgA)
            divider
            rowGanZhi(title: "地支", items: bazi.pillars.map(\.zhi), large: true)
                .background(rowBgB)
            divider
            rowZangGan(title: "藏干", pillars: bazi.pillars)
                .background(rowBgA)
            divider
            rowShiShen(title: "支神", pillars: bazi.pillars)
                .background(rowBgB)
            divider
            rowLabel("纳音", cells: bazi.pillars.map { $0.naYin.isEmpty ? "—" : $0.naYin }, large: false)
                .background(rowBgA)
            divider
            rowLabel("空亡", cells: bazi.pillars.map { $0.kongWang.isEmpty ? "—" : $0.kongWang }, large: false)
                .background(rowBgB)
            divider
            rowLabel("地势", cells: bazi.pillars.map { $0.diShi.isEmpty ? "—" : $0.diShi }, large: false)
                .background(rowBgA)
            divider
            rowLabel("自坐", cells: bazi.pillars.map { $0.ziZuo.isEmpty ? "—" : $0.ziZuo }, large: false)
                .background(rowBgB)
            divider
            rowShenSha(title: "神煞", pillars: bazi.pillars)
                .background(rowBgA)
            divider
            rowLabel("胎元", cells: [
                (bazi.taiYuan?.isEmpty == false) ? bazi.taiYuan! : "—",
                "—", "—", "—"
            ], large: false)
            .background(rowBgB)
            divider
            rowLabel("命宫", cells: [
                (bazi.mingGong?.isEmpty == false) ? bazi.mingGong! : "—",
                "—", "—", "—"
            ], large: false)
            .background(rowBgA)
            divider
            rowLabel("身宫", cells: [
                (bazi.shenGong?.isEmpty == false) ? bazi.shenGong! : "—",
                "—", "—", "—"
            ], large: false)
            .background(rowBgB)
            divider
            rowColumnList(title: "大运", items: bazi.daYun ?? [])
                .background(rowBgA)
            divider
            rowColumnList(title: "流年", items: bazi.liuNian ?? [])
                .background(rowBgB)
            if let rel = bazi.ganRelationText, !rel.isEmpty {
                divider
                Text("天干 \(rel)")
                    .font(.caption)
                    .foregroundStyle(textLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(rowBgB)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 24)
    }

    private var divider: some View {
        Rectangle()
            .fill(rowSeparator)
            .frame(height: 1)
    }

    private func rowLabel(_ title: String, cells: [String], large: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.system(size: large ? 15 : 13, weight: .medium))
                .foregroundStyle(textLabel)
                .frame(width: labelColumnWidth, alignment: .leading)
                .padding(.vertical, 10)
            ForEach(Array(bazi.pillarTitles.enumerated()), id: \.offset) { item in
                let cellText = cells.indices.contains(item.offset) ? cells[item.offset] : "—"
                Text(cellText)
                    .font(.system(size: large ? 16 : 13))
                    .foregroundStyle(cellText.isEmpty || cellText == "—" ? textPlaceholder : textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 10)
                    .padding(.leading, 6)
            }
        }
    }

    private func rowGanZhi(title: String, items: [String], large: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(textLabel)
                .frame(width: labelColumnWidth, alignment: .leading)
                .padding(.vertical, 12)
            ForEach(Array(items.enumerated()), id: \.offset) { item in
                let char = item.element
                let wx = WuXing.from(stemOrBranch: char)
                HStack(spacing: 4) {
                    Text(char)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(wx?.color ?? textPrimary)
                    Text(wx?.symbol ?? "")
                        .font(.system(size: 14))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.leading, 6)
            }
        }
    }

    private func rowZangGan(title: String, pillars: [BaZiPillar]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textLabel)
                .frame(width: labelColumnWidth, alignment: .leading)
                .padding(.vertical, 10)
            ForEach(Array(pillars.enumerated()), id: \.offset) { item in
                let list = item.element.zangGan
                VStack(alignment: .leading, spacing: 4) {
                    if list.isEmpty {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(textPlaceholder)
                    } else {
                        ForEach(Array(list.enumerated()), id: \.offset) { listItem in
                            Text(listItem.element)
                                .font(.caption)
                                .foregroundStyle(textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 6)
            }
        }
    }

    /// 支神：每柱内竖向一列显示，不并排
    private func rowShiShen(title: String, pillars: [BaZiPillar]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textLabel)
                .frame(width: labelColumnWidth, alignment: .leading)
                .padding(.vertical, 10)
            ForEach(Array(pillars.enumerated()), id: \.offset) { item in
                let list = item.element.shiShen
                VStack(alignment: .leading, spacing: 4) {
                    if list.isEmpty {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(textPlaceholder)
                    } else {
                        ForEach(Array(list.enumerated()), id: \.offset) { listItem in
                            Text(listItem.element)
                                .font(.caption)
                                .foregroundStyle(textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 6)
            }
        }
    }

    private func rowShenSha(title: String, pillars: [BaZiPillar]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textLabel)
                .frame(width: labelColumnWidth, alignment: .leading)
                .padding(.vertical, 10)
            ForEach(Array(pillars.enumerated()), id: \.offset) { item in
                let list = item.element.shenSha
                VStack(alignment: .leading, spacing: 4) {
                    if list.isEmpty {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(textPlaceholder)
                    } else {
                        ForEach(Array(list.enumerated()), id: \.offset) { listItem in
                            Text(listItem.element)
                                .font(.caption)
                                .foregroundStyle(textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 6)
            }
        }
    }

    private func rowSingleLine(title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textLabel)
                .frame(width: labelColumnWidth, alignment: .leading)
                .padding(.vertical, 10)
            Text(text)
                .font(.caption)
                .foregroundStyle(textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 6)
                .padding(.trailing, 6)
        }
    }

    private func rowColumnList(title: String, items: [String]) -> some View {
        let showItems = items.isEmpty ? ["—"] : items
        let rows = stride(from: 0, to: showItems.count, by: 2).map { index in
            Array(showItems[index..<min(index + 2, showItems.count)])
        }
        return HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textLabel)
                .frame(width: labelColumnWidth, alignment: .leading)
                .padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) {
                        let left = row.first ?? "—"
                        Text(formatDaYunItem(left))
                            .font(.caption)
                            .foregroundStyle(left == "—" ? textPlaceholder : textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        let right = row.count > 1 ? row[1] : "—"
                        Text(formatDaYunItem(right))
                            .font(.caption)
                            .foregroundStyle(right == "—" ? textPlaceholder : textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, 6)
        }
    }

    private func formatDaYunItem(_ item: String) -> String {
        guard item != "—" else { return item }
        if let range = item.range(of: ") ") {
            let left = item[..<range.upperBound].trimmingCharacters(in: .whitespaces)
            let right = item[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !right.isEmpty {
                return "\(left)\n\(right)"
            }
        }
        return item
    }
}
