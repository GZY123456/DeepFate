import Foundation

enum DrawClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(code: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的服务地址"
        case .invalidResponse: return "抽卡响应格式异常"
        case let .serverError(code, msg): return "服务错误(\(code))：\(msg ?? "未知")"
        }
    }
}

struct DrawClient {
    private let backend = SparkBackendConfig()
    private let session = URLSession.shared

    func fetchToday(profileId: UUID) async throws -> DrawResult {
        guard var components = URLComponents(string: backend.baseURL + "/draws/today") else {
            throw DrawClientError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "profile_id", value: profileId.uuidString)]
        guard let url = components.url else { throw DrawClientError.invalidURL }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw DrawClientError.invalidResponse }
        if http.statusCode == 404 {
            throw DrawClientError.serverError(code: 404, message: "今日尚未抽卡")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw DrawClientError.serverError(code: http.statusCode, message: msg)
        }
        let payload = try JSONDecoder().decode(DrawResultPayload.self, from: data)
        return DrawResult(
            date: payload.date,
            cardName: payload.cardName,
            keywords: payload.keywords,
            interpretation: payload.interpretation,
            advice: payload.advice
        )
    }

    func generateToday(profileId: UUID) async throws -> DrawResult {
        guard let url = URL(string: backend.baseURL + "/draws/daily") else {
            throw DrawClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["profileId": profileId.uuidString]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DrawClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw DrawClientError.serverError(code: http.statusCode, message: msg)
        }
        let payload = try JSONDecoder().decode(DrawResultPayload.self, from: data)
        return DrawResult(
            date: payload.date,
            cardName: payload.cardName,
            keywords: payload.keywords,
            interpretation: payload.interpretation,
            advice: payload.advice
        )
    }
}
