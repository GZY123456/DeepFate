import Foundation

/// 调用后端 /chart 生成八字排盘
struct ChartClient {
    private let backend = SparkBackendConfig()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// 拉取排盘：返回全文 content（用于「问问AI」）与可选结构化 bazi（用于表格展示）
    func fetchChart(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        longitude: Double,
        gender: String
    ) async throws -> (content: String, bazi: BaZiModel?) {
        guard let url = URL(string: backend.baseURL + "/chart") else {
            throw ChartError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        let body: [String: Any] = [
            "year": year,
            "month": month,
            "day": day,
            "hour": hour,
            "minute": minute,
            "longitude": longitude,
            "gender": gender
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ChartError.timeout
        }
        guard let http = response as? HTTPURLResponse else {
            throw ChartError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ChartError.serverError(code: http.statusCode, message: msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String else {
            throw ChartError.invalidResponse
        }
        var bazi: BaZiModel?
        if let baziObj = json["bazi"] as? [String: Any] {
            if let baziData = try? JSONSerialization.data(withJSONObject: baziObj),
               var decoded = try? JSONDecoder().decode(BaZiModel.self, from: baziData) {
                decoded.taiYuan = decoded.taiYuan ?? (baziObj["taiYuan"] as? String)
                decoded.mingGong = decoded.mingGong ?? (baziObj["mingGong"] as? String)
                decoded.shenGong = decoded.shenGong ?? (baziObj["shenGong"] as? String)
                decoded.daYun = decoded.daYun ?? (baziObj["daYun"] as? [String])
                decoded.liuNian = decoded.liuNian ?? (baziObj["liuNian"] as? [String])
                bazi = decoded
            } else if var fallback = BaZiModel.from(plainText: content) {
                fallback.taiYuan = baziObj["taiYuan"] as? String
                fallback.mingGong = baziObj["mingGong"] as? String
                fallback.shenGong = baziObj["shenGong"] as? String
                fallback.daYun = baziObj["daYun"] as? [String]
                fallback.liuNian = baziObj["liuNian"] as? [String]
                bazi = fallback
            }
        }
        if bazi == nil {
            bazi = BaZiModel.from(plainText: content)
        }
        return (content: content, bazi: bazi)
    }
}

enum ChartError: LocalizedError {
    case invalidURL
    case invalidResponse
    case timeout
    case serverError(code: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的服务地址"
        case .invalidResponse: return "排盘响应格式异常"
        case .timeout: return "排盘请求超时，请检查后端服务地址或网络连接"
        case let .serverError(code, msg): return "服务错误(\(code))：\(msg ?? "未知")"
        }
    }
}
