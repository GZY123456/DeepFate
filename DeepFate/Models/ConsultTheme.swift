import SwiftUI

/// 咨询页天师：软萌小师妹 / 性感大师姐
enum Tianshi: String, CaseIterable, Identifiable {
    case soft = "soft"   // 软萌小师妹
    case sexy = "sexy"   // 性感大师姐

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soft: return "软萌小师妹"
        case .sexy: return "性感大师姐"
        }
    }

    /// 头像图片名（Asset 中需有对应 imageset，圆形由 UI 处理）
    var avatarImageName: String {
        switch self {
        case .soft: return "TianshiAvatarSoft"
        case .sexy: return "TianshiAvatarSexy"
        }
    }

    /// 咨询页背景图名
    var backgroundImageName: String {
        switch self {
        case .soft: return "ConsultBackground"
        case .sexy: return "ConsultBackgroundSexy"
        }
    }

    /// 开场白（新建会话的首条助手消息）
    var greeting: String {
        switch self {
        case .soft: return "你终于来啦！今天心情怎么样？要是觉得心里有什么不踏实的事儿，咱们就排一卦看看。不管结果好坏，我都会在这儿陪着你的。"
        case .sexy: return "看透卦象易，看透人心难。过来坐吧，让我瞧瞧你眉间压着的那抹愁云，是为了那求而不得的功名利禄，还是为了某段……舍不掉的儿女情长？"
        }
    }

    var theme: ConsultTheme {
        switch self {
        case .soft: return .soft
        case .sexy: return .sexy
        }
    }
}

/// 咨询页配色（保证对比度，避免纯黑纯白）
struct ConsultTheme {
    /// 主文字色（深色，非纯黑）
    var primaryText: Color
    /// 聊天区/气泡/输入框背景（浅色，非纯白）
    var surface: Color
    /// 强调色（按钮、标题等）
    var accent: Color
    /// 主文字半透明（占位、边框等）
    var primaryTextMuted: Color { primaryText.opacity(0.55) }
    var primaryTextBorder: Color { primaryText.opacity(0.18) }

    static let soft: ConsultTheme = ConsultTheme(
        primaryText: Color(red: 0.365, green: 0.251, blue: 0.216),   // #5D4037 深棕
        surface: Color(red: 1.0, green: 0.988, blue: 0.961).opacity(0.85),
        accent: Color(red: 1.0, green: 0.541, blue: 0.396)           // #FF8A65 珊瑚
    )

    static let sexy: ConsultTheme = ConsultTheme(
        primaryText: Color(red: 0.18, green: 0.13, blue: 0.25),      // #2D2140 深紫
        surface: Color(red: 0.94, green: 0.92, blue: 0.97),          // #F0EBF8 浅紫
        accent: Color(red: 0.48, green: 0.36, blue: 0.71)           // #7B5BB5 中紫
    )
}

// MARK: - Environment

private struct ConsultThemeKey: EnvironmentKey {
    static let defaultValue: ConsultTheme? = nil
}

extension EnvironmentValues {
    var consultTheme: ConsultTheme? {
        get { self[ConsultThemeKey.self] }
        set { self[ConsultThemeKey.self] = newValue }
    }
}
