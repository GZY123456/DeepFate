import Foundation

enum PalmHandSide: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "左手"
        case .right: return "右手"
        }
    }

    var mirrored: Bool {
        self == .right
    }
}

struct PalmLandmarkPoint: Codable, Hashable, Equatable {
    let x: Double
    let y: Double
    let confidence: Double
}

struct PalmistryStructuredFeatures: Codable, Equatable {
    let source: String
    let palmShape: String
    let fingerSpread: String
    let lineClarity: String
    let qualitySummary: String
    let lifeLine: String
    let headLine: String
    let heartLine: String
    let careerLine: String
    let notes: [String]
}

struct PalmistryAnalysis: Codable, Equatable {
    let overall: String
    let summary: String
    let lifeLine: String
    let headLine: String
    let heartLine: String
    let career: String
    let wealth: String
    let love: String
    let health: String
    let advice: String
    let structured: PalmistryStructuredFeatures
}

struct PalmistryResult: Identifiable, Codable, Equatable {
    let id: String
    let profileId: String
    let handSide: PalmHandSide
    let takenAt: String
    let takenAtISO: String
    let originalImageURL: URL?
    let thumbnailURL: URL?
    let analysis: PalmistryAnalysis
}

struct PalmistryHistoryItem: Identifiable, Codable, Equatable {
    let id: String
    let profileId: String
    let handSide: PalmHandSide
    let takenAt: String
    let takenAtISO: String
    let thumbnailURL: URL?
    let summary: String
    let overall: String
}
