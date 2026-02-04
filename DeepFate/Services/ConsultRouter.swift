import Foundation
import SwiftUI

/// 用于从命理详批等页面跳转到咨询页并携带待发送内容
@MainActor
final class ConsultRouter: ObservableObject {
    @Published var pendingChartPrompt: String?
    @Published var switchToConsultTab: Bool = false

    func askAI(withChartText chartText: String) {
        let prompt = "请根据以下排盘信息进行命理分析：\n\n\(chartText)"
        pendingChartPrompt = prompt
        switchToConsultTab = true
    }

    func askAI(withDrawResult result: DrawResult, profile: UserProfile, chartText: String?) {
        let keywords = result.keywords.joined(separator: "、")
        let profileText = """
        用户档案信息：
        - 姓名：\(profile.name)
        - 性别：\(profile.gender.rawValue)
        - 出生地：\(profile.location.province)\(profile.location.city)\(profile.location.district)
        - 出生时间（阳历）：\(formatDateComponents(profile.birthInfo.solarComponents))
        - 出生时间（阴历）：\(formatDateComponents(profile.birthInfo.lunarComponents))
        - 真太阳时：\(formatDateComponents(profile.trueSolarComponents))
        """
        let baziSection: String
        if let chartText, !chartText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baziSection = "\n八字排盘信息：\n\(chartText)\n"
        } else {
            baziSection = ""
        }
        let prompt = """
        请结合用户八字信息与今日抽卡结果进行解读与建议，语气温和、具体可执行：

        \(profileText)

        \(baziSection)

        抽卡结果：
        - 日期：\(result.date)
        - 卡名：\(result.cardName)
        - 关键词：\(keywords)
        - 解读：\(result.interpretation)
        - 建议：\(result.advice)
        """
        pendingChartPrompt = prompt
        switchToConsultTab = true
    }

    func clearPendingChart() {
        pendingChartPrompt = nil
    }
}
