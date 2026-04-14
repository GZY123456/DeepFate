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

enum PalmistryReportStatus: String, Codable, Equatable {
    case pending
    case ready
    case failed
}

struct PalmLandmarkPoint: Codable, Hashable, Equatable {
    let x: Double
    let y: Double
    let confidence: Double
}

struct PalmOverlayPoint: Codable, Hashable, Equatable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            let x = try container.decode(Double.self)
            let y = try container.decode(Double.self)
            self.init(x: x, y: y)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }
}

struct PalmLineOverlay: Codable, Hashable, Equatable, Identifiable {
    let key: String
    let title: String
    let colorHex: String
    let confidence: Double
    let points: [PalmOverlayPoint]

    var id: String { key }
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
    let summaryTags: [String]
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
    var overlays: [PalmLineOverlay]
    let reportStatus: PalmistryReportStatus
    let reportError: String?
    let analysis: PalmistryAnalysis?

    var isReportReady: Bool {
        reportStatus == .ready && analysis != nil
    }
}

struct PalmistryHistoryItem: Identifiable, Codable, Equatable {
    let id: String
    let profileId: String
    let handSide: PalmHandSide
    let takenAt: String
    let takenAtISO: String
    let thumbnailURL: URL?
    let reportStatus: PalmistryReportStatus
    let summary: String
    let overall: String
}

struct PalmistryReportStatusPayload: Codable, Equatable {
    let readingId: String
    let reportStatus: PalmistryReportStatus
    let reportError: String?
    let result: PalmistryResult?
}
