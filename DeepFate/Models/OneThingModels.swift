import Foundation

enum CoinFace: String, Codable, CaseIterable, Equatable {
    case front = "正"
    case back = "反"
}

struct OneThingLine: Codable, Equatable, Identifiable {
    var id: Int { line }
    let line: Int
    let coins: [String]
    let sum: Int
    let type: String
    let isYang: Bool
    let isMoving: Bool
    let changedIsYang: Bool

    var lineName: String {
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

struct OneThingHexagram: Codable, Equatable {
    let number: Int
    let name: String
    let upperTrigram: String
    let upperElement: String
    let lowerTrigram: String
    let lowerElement: String
    let linePattern: [String]
    let lineSymbols: [String]
}

struct OneThingHexagramGroup: Codable, Equatable {
    let primary: OneThingHexagram
    let changed: OneThingHexagram
    let movingLines: [Int]
}

struct OneThingGanZhi: Codable, Equatable {
    let year: String
    let month: String
    let day: String
    let hour: String
    let lunarLabel: String
}

struct OneThingSixRelative: Codable, Equatable, Identifiable {
    var id: Int { line }
    let line: Int
    let role: String
    let element: String
    let yinYang: String
    let moving: Bool
    let note: String
}

struct OneThingAnalysis: Codable, Equatable {
    let conclusion: String
    let summary: String
    let fiveElements: String
    let advice: String
    let sixRelatives: [OneThingSixRelative]
}

struct OneThingResult: Codable, Equatable, Identifiable {
    let id: String
    let date: String
    let question: String
    let startedAt: String
    let startedAtISO: String?
    let ganZhi: OneThingGanZhi
    let tosses: [[String]]
    let lines: [OneThingLine]
    let hexagram: OneThingHexagramGroup
    let analysis: OneThingAnalysis
}

struct OneThingHistoryItem: Codable, Equatable, Identifiable {
    let id: String
    let date: String
    let startedAt: String
    let question: String
    let conclusion: String
    let primaryName: String
    let changedName: String
}

struct OneThingCastPayload: Codable {
    let profileId: String
    let question: String
    let startedAt: String
    let tosses: [[String]]
}
