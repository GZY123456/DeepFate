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
        - 出生地：\(profile.location.fullDisplayText)
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

    func askAI(withOneThingResult result: OneThingResult, profile: UserProfile, chartText: String?) {
        let profileText = """
        用户档案信息：
        - 姓名：\(profile.name)
        - 性别：\(profile.gender.rawValue)
        - 出生地：\(profile.location.fullDisplayText)
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
        let movingLinesText = result.hexagram.movingLines.isEmpty
            ? "无动爻"
            : result.hexagram.movingLines.map { "\($0)" }.joined(separator: "、")
        let sixRelativesText = result.analysis.sixRelatives
            .map { "\(lineName($0.line))：\($0.role)(\($0.element))，\($0.note)" }
            .joined(separator: "\n")

        let prompt = """
        请基于以下一事一测六爻排卦信息，先给结论，再给可执行建议，语言清晰、直白：

        \(profileText)

        \(baziSection)

        问题：\(result.question)
        起卦时间：\(result.startedAt)
        干支：\(result.ganZhi.year)年 \(result.ganZhi.month)月 \(result.ganZhi.day)日 \(result.ganZhi.hour)时
        农历：\(result.ganZhi.lunarLabel)
        本卦：\(result.hexagram.primary.name)
        变卦：\(result.hexagram.changed.name)
        动爻：\(movingLinesText)

        当前系统解读：
        - 结论：\(result.analysis.conclusion)
        - 概览：\(result.analysis.summary)
        - 五行分析：\(result.analysis.fiveElements)
        - 建议：\(result.analysis.advice)
        - 六亲：
        \(sixRelativesText)
        """

        pendingChartPrompt = prompt
        switchToConsultTab = true
    }

    func clearPendingChart() {
        pendingChartPrompt = nil
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
}
