import Foundation

enum OneThingClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case timeout
    case serverError(code: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的服务地址"
        case .invalidResponse:
            return "一事一测响应格式异常"
        case .timeout:
            return "一事一测请求超时，请检查网络或后端服务"
        case let .serverError(code, message):
            return "服务错误(\(code))：\(message ?? "未知错误")"
        }
    }
}

struct OneThingClient {
    private let backend = SparkBackendConfig()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config)
    }()

    func fetchLatest(profileId: UUID) async throws -> OneThingResult {
        guard var components = URLComponents(string: backend.baseURL + "/one-thing/latest") else {
            throw OneThingClientError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "profile_id", value: profileId.uuidString)]
        guard let url = components.url else { throw OneThingClientError.invalidURL }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError where error.code == .timedOut {
            throw OneThingClientError.timeout
        }

        guard let http = response as? HTTPURLResponse else {
            throw OneThingClientError.invalidResponse
        }
        if http.statusCode == 404 {
            throw OneThingClientError.serverError(code: 404, message: "今日未起卦")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OneThingClientError.serverError(code: http.statusCode, message: msg)
        }
        do {
            return try JSONDecoder().decode(OneThingResult.self, from: data)
        } catch {
            throw OneThingClientError.invalidResponse
        }
    }

    func fetchHistory(profileId: UUID, limit: Int = 30) async throws -> [OneThingHistoryItem] {
        guard var components = URLComponents(string: backend.baseURL + "/one-thing/history") else {
            throw OneThingClientError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "profile_id", value: profileId.uuidString),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw OneThingClientError.invalidURL }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError where error.code == .timedOut {
            throw OneThingClientError.timeout
        }

        guard let http = response as? HTTPURLResponse else {
            throw OneThingClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OneThingClientError.serverError(code: http.statusCode, message: msg)
        }
        do {
            return try JSONDecoder().decode([OneThingHistoryItem].self, from: data)
        } catch {
            throw OneThingClientError.invalidResponse
        }
    }

    func fetchRecord(profileId: UUID, recordId: String) async throws -> OneThingResult {
        guard var components = URLComponents(string: backend.baseURL + "/one-thing/record/\(recordId)") else {
            throw OneThingClientError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "profile_id", value: profileId.uuidString)]
        guard let url = components.url else { throw OneThingClientError.invalidURL }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError where error.code == .timedOut {
            throw OneThingClientError.timeout
        }

        guard let http = response as? HTTPURLResponse else {
            throw OneThingClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OneThingClientError.serverError(code: http.statusCode, message: msg)
        }
        do {
            return try JSONDecoder().decode(OneThingResult.self, from: data)
        } catch {
            throw OneThingClientError.invalidResponse
        }
    }

    func deleteRecord(profileId: UUID, recordId: String) async throws {
        guard var components = URLComponents(string: backend.baseURL + "/one-thing/record/\(recordId)") else {
            throw OneThingClientError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "profile_id", value: profileId.uuidString)]
        guard let url = components.url else { throw OneThingClientError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OneThingClientError.timeout
        }

        guard let http = response as? HTTPURLResponse else {
            throw OneThingClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 {
                return
            }
            throw OneThingClientError.serverError(code: http.statusCode, message: nil)
        }
    }

    func cast(profileId: UUID, question: String, startedAt: Date, tosses: [[String]]) async throws -> OneThingResult {
        guard let url = URL(string: backend.baseURL + "/one-thing/cast") else {
            throw OneThingClientError.invalidURL
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = OneThingCastPayload(
            profileId: profileId.uuidString,
            question: question,
            startedAt: formatter.string(from: startedAt),
            tosses: tosses
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OneThingClientError.timeout
        }

        guard let http = response as? HTTPURLResponse else {
            throw OneThingClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OneThingClientError.serverError(code: http.statusCode, message: msg)
        }
        do {
            return try JSONDecoder().decode(OneThingResult.self, from: data)
        } catch {
            throw OneThingClientError.invalidResponse
        }
    }
}
