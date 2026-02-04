import Foundation

struct DrawResult: Identifiable, Codable, Equatable {
    let date: String
    let cardName: String
    let keywords: [String]
    let interpretation: String
    let advice: String

    var id: String {
        "\(date)-\(cardName)"
    }
}

struct DrawResultPayload: Codable {
    let date: String
    let cardName: String
    let keywords: [String]
    let interpretation: String
    let advice: String
}
