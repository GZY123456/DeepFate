import SwiftUI

// MARK: - 首页数据接口（占位，后续接 API）

/// 今日能量
struct TodayEnergy {
    var label: String       // e.g. "旭日东升"
    var fortuneLevel: String // e.g. "大吉"
}

/// 每日锦囊
struct DailyFortune {
    var content: String     // 锦囊正文
}

// MARK: - 首页视图

struct HomeView: View {
    // 占位数据，后续替换为 ViewModel / API
    @State private var todayEnergy = TodayEnergy(label: "旭日东升", fortuneLevel: "大吉")
    @State private var dailyFortune = DailyFortune(content: "今日宜静心，忌冲动。")
    @State private var todayDrawResult: DrawResult?
    @EnvironmentObject private var profileStore: ProfileStore
    private let drawClient = DrawClient()

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    // 1. 今日能量卡片
                    dailyEnergyCard

                    // 2. 命理详批 / 一事一测 按钮（等高、铺满宽）
                    actionButtons(minHeight: max(100, geometry.size.height * 0.18))

                    // 3. 每日锦囊分隔与内容（增高铺满）
                    dailyFortuneSection(minHeight: max(160, geometry.size.height * 0.28))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .background(LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.94, blue: 0.92),
                Color(red: 0.96, green: 0.91, blue: 0.94)
            ],
            startPoint: .top,
            endPoint: .bottom
        ))
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await refreshTodayDraw() }
        }
        .onChange(of: profileStore.activeProfileID) { _ in
            Task { await refreshTodayDraw() }
        }
    }

    // MARK: - 今日能量卡片

    private var dailyEnergyCard: some View {
        let label = todayDrawResult?.cardName ?? todayEnergy.label
        let level = todayDrawResult?.keywords.first ?? todayEnergy.fortuneLevel
        return NavigationLink {
            OneThingDrawView()
        } label: {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.55, green: 0.42, blue: 0.35),
                                    Color(red: 0.42, green: 0.32, blue: 0.28)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 88, height: 88)
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                }

                Text("今日能量: \(label) - \(level)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(red: 0.45, green: 0.35, blue: 0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 命理详批 / 一事一测

    private func actionButtons(minHeight: CGFloat) -> some View {
        HStack(spacing: 16) {
            NavigationLink {
                FortuneChartView()
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "location.north")
                        .font(.system(size: 28))
                    Text("命理详批")
                        .font(.headline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.82, green: 0.45, blue: 0.52))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                OneThingDrawView()
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 28))
                    Text("一事一测")
                        .font(.headline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.35, green: 0.55, blue: 0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func refreshTodayDraw() async {
        guard let id = profileStore.activeProfileID else {
            await MainActor.run {
                todayDrawResult = nil
            }
            return
        }
        do {
            let result = try await drawClient.fetchToday(profileId: id)
            await MainActor.run {
                todayDrawResult = result
            }
        } catch {
            await MainActor.run {
                todayDrawResult = nil
            }
        }
    }

    // MARK: - 每日锦囊

    private func dailyFortuneSection(minHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "diamond.fill")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.5, green: 0.35, blue: 0.4))
                Text("每日锦囊")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.2, blue: 0.22))
                Image(systemName: "diamond.fill")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.5, green: 0.35, blue: 0.4))
            }

            Text(dailyFortune.content)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: minHeight)
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.65, green: 0.48, blue: 0.52))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        }
    }
}
#Preview("首页") {
    NavigationStack {
        HomeView()
    }
}
