import SwiftUI

// MARK: - 五行
enum WuXing: String, CaseIterable {
    case jin = "金"
    case mu = "木"
    case shui = "水"
    case huo = "火"
    case tu = "土"

    var color: Color {
        switch self {
        case .jin: return Color(red: 0.85, green: 0.55, blue: 0.2)   // 金
        case .mu: return Color(red: 0.2, green: 0.6, blue: 0.35)      // 木
        case .shui: return Color(red: 0.25, green: 0.45, blue: 0.85)   // 水
        case .huo: return Color(red: 0.9, green: 0.3, blue: 0.25)      // 火
        case .tu: return Color(red: 0.6, green: 0.45, blue: 0.3)      // 土
        }
    }

    static func from(stemOrBranch: String) -> WuXing? {
        let mapping: [String: WuXing] = [
            "甲": .mu, "乙": .mu, "丙": .huo, "丁": .huo, "戊": .tu, "己": .tu,
            "庚": .jin, "辛": .jin, "壬": .shui, "癸": .shui,
            "寅": .mu, "卯": .mu, "巳": .huo, "午": .huo, "辰": .tu, "戌": .tu, "丑": .tu, "未": .tu,
            "申": .jin, "酉": .jin, "亥": .shui, "子": .shui
        ]
        return mapping[stemOrBranch]
    }

    var symbol: String {
        switch self {
        case .jin: return "⚜️"
        case .mu: return "🌲"
        case .shui: return "💧"
        case .huo: return "🔥"
        case .tu: return "🪨"
        }
    }
}

// MARK: - 单柱（年/月/日/时）
struct BaZiPillar: Codable, Equatable {
    /// 天干（如 辛）
    var gan: String
    /// 地支（如 巳）
    var zhi: String
    /// 藏干（如 ["丙·火","庚·金","戊·土"]）
    var zangGan: [String]
    /// 十神/支神（如 ["正财","正印"]）
    var shiShen: [String]
    /// 纳音（如 白蜡金）
    var naYin: String
    /// 空亡（如 申酉）
    var kongWang: String
    /// 地势（如 临官）
    var diShi: String
    /// 自坐（如 死）
    var ziZuo: String
    /// 神煞列表（如 ["福星贵人","国印"]）
    var shenSha: [String]
    /// 干神（如 正财）
    var ganShen: String

    static let empty = BaZiPillar(
        gan: "", zhi: "", zangGan: [], shiShen: [], naYin: "", kongWang: "", diShi: "", ziZuo: "", shenSha: [], ganShen: ""
    )
}

// MARK: - 八字排盘模型
struct BaZiModel: Codable, Equatable {
    /// 公历/真太阳时描述
    var solarLabel: String
    var trueSolarLabel: String
    var lunarLabel: String
    /// 出生节气描述（可选）
    var solarTermLabel: String?
    /// 年柱、月柱、日柱、时柱
    var yearPillar: BaZiPillar
    var monthPillar: BaZiPillar
    var dayPillar: BaZiPillar
    var hourPillar: BaZiPillar
    /// 底部天干关系（如 丙辛合化水·乙辛冲）
    var ganRelationText: String?
    /// 性别
    var gender: String?
    /// 胎元/命宫/身宫/大运/流年
    var taiYuan: String?
    var mingGong: String?
    var shenGong: String?
    var daYun: [String]?
    var liuNian: [String]?

    var pillars: [BaZiPillar] { [yearPillar, monthPillar, dayPillar, hourPillar] }
    var pillarTitles: [String] { ["年柱", "月柱", "日柱", "时柱"] }

    /// 从后端纯文本排盘解析出最小可用模型（仅天干地支 + 纳音等若存在）
    static func from(plainText: String) -> BaZiModel? {
        var yearGan = "", yearZhi = "", monthGan = "", monthZhi = ""
        var dayGan = "", dayZhi = "", hourGan = "", hourZhi = ""
        var trueSolar = "", lunar = "", solar = ""
        var dayNaYin = "", gender: String? = nil

        let lines = plainText.components(separatedBy: .newlines)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("公历：") { solar = String(t.dropFirst("公历：".count)).trimmingCharacters(in: .whitespaces) }
            else if t.hasPrefix("真太阳时") { trueSolar = t }
            else if t.hasPrefix("农历：") { lunar = String(t.dropFirst("农历：".count)).trimmingCharacters(in: .whitespaces) }
            else if t.hasPrefix("年柱：") {
                let v = String(t.dropFirst("年柱：".count)).trimmingCharacters(in: .whitespaces)
                if v.count >= 2 {
                    yearGan = String(v.prefix(1))
                    yearZhi = String(v.suffix(1))
                }
            } else if t.hasPrefix("月柱：") {
                let v = String(t.dropFirst("月柱：".count)).trimmingCharacters(in: .whitespaces)
                if v.count >= 2 { monthGan = String(v.prefix(1)); monthZhi = String(v.suffix(1)) }
            } else if t.hasPrefix("日柱：") {
                let v = String(t.dropFirst("日柱：".count)).trimmingCharacters(in: .whitespaces)
                if v.count >= 2 { dayGan = String(v.prefix(1)); dayZhi = String(v.suffix(1)) }
            } else if t.hasPrefix("时柱：") {
                let v = String(t.dropFirst("时柱：".count)).trimmingCharacters(in: .whitespaces)
                if v.count >= 2 { hourGan = String(v.prefix(1)); hourZhi = String(v.suffix(1)) }
            } else if t.hasPrefix("日柱纳音：") { dayNaYin = String(t.dropFirst("日柱纳音：".count)).trimmingCharacters(in: .whitespaces) }
            else if t.hasPrefix("性别：") { gender = String(t.dropFirst("性别：".count)).trimmingCharacters(in: .whitespaces) }
        }

        let yearP = BaZiPillar(gan: yearGan, zhi: yearZhi, zangGan: [], shiShen: [], naYin: "", kongWang: "", diShi: "", ziZuo: "", shenSha: [], ganShen: "")
        let monthP = BaZiPillar(gan: monthGan, zhi: monthZhi, zangGan: [], shiShen: [], naYin: "", kongWang: "", diShi: "", ziZuo: "", shenSha: [], ganShen: "")
        let dayP = BaZiPillar(gan: dayGan, zhi: dayZhi, zangGan: [], shiShen: [], naYin: dayNaYin, kongWang: "", diShi: "", ziZuo: "", shenSha: [], ganShen: "")
        let hourP = BaZiPillar(gan: hourGan, zhi: hourZhi, zangGan: [], shiShen: [], naYin: "", kongWang: "", diShi: "", ziZuo: "", shenSha: [], ganShen: "")

        return BaZiModel(
            solarLabel: solar,
            trueSolarLabel: trueSolar,
            lunarLabel: lunar,
            solarTermLabel: nil,
            yearPillar: yearP,
            monthPillar: monthP,
            dayPillar: dayP,
            hourPillar: hourP,
            ganRelationText: nil,
            gender: gender,
            taiYuan: nil,
            mingGong: nil,
            shenGong: nil,
            daYun: nil,
            liuNian: nil
        )
    }
}
