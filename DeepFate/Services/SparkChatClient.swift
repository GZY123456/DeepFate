import Foundation
import Darwin

struct SparkBackendConfig {
    private static let backendBaseURLKey = "backendBaseURL"
    private static let lastSuccessfulBaseURLKey = "lastSuccessfulBackendBaseURL"
    private static let fallbackURL = "http://127.0.0.1:8000"
    private static let legacyURLs = [
        "http://10.10.13.2:8000",
        "http://192.168.0.101:8000",
        "http://192.168.0.103:8000"
    ]

    let chatPath: String = "/spark/chat"
    let streamPath: String = "/spark/chat/stream"
    let titlePath: String = "/spark/title"

    var baseURL: String {
        configuredBaseURL ?? lastSuccessfulBaseURL ?? Self.fallbackURL
    }

    var isValid: Bool {
        !baseURL.isEmpty
    }

    func resolvedBaseURL(forceRefresh: Bool = false) async -> String {
        let preferred = configuredBaseURL ?? lastSuccessfulBaseURL ?? Self.fallbackURL
        let candidates = candidateBaseURLs()
        return await BackendEndpointResolver.shared.resolve(
            preferred: preferred,
            candidates: candidates,
            forceRefresh: forceRefresh
        )
    }

    func performRequest<T>(_ operation: (String) async throws -> T) async throws -> T {
        let firstURL = await resolvedBaseURL()
        do {
            let value = try await operation(firstURL)
            await BackendEndpointResolver.shared.markSuccess(firstURL)
            return value
        } catch {
            guard Self.shouldRefreshDiscovery(for: error) else {
                throw error
            }
            let refreshedURL = await resolvedBaseURL(forceRefresh: true)
            guard refreshedURL != firstURL else {
                throw error
            }
            let value = try await operation(refreshedURL)
            await BackendEndpointResolver.shared.markSuccess(refreshedURL)
            return value
        }
    }

    private var configuredBaseURL: String? {
        let raw = UserDefaults.standard.string(forKey: Self.backendBaseURLKey) ?? ""
        return Self.normalizeURL(raw)
    }

    private var lastSuccessfulBaseURL: String? {
        let raw = UserDefaults.standard.string(forKey: Self.lastSuccessfulBaseURLKey) ?? ""
        return Self.normalizeURL(raw)
    }

    private func candidateBaseURLs() -> [String] {
        var rawCandidates: [String] = []
        if let configuredBaseURL { rawCandidates.append(configuredBaseURL) }
        if let lastSuccessfulBaseURL { rawCandidates.append(lastSuccessfulBaseURL) }
        rawCandidates.append(contentsOf: Self.legacyURLs)
        rawCandidates.append(contentsOf: [
            Self.fallbackURL,
            "http://localhost:8000",
            "http://host.docker.internal:8000"
        ])

        if let prefix = Self.localIPv4Prefix() {
            var suffixes: [Int] = [13, 10, 11, 12, 20, 100, 101, 102, 103, 200]
            if let configured = configuredBaseURL, let last = Self.lastOctet(of: configured) {
                suffixes.insert(last, at: 0)
            }
            if let successful = lastSuccessfulBaseURL, let last = Self.lastOctet(of: successful) {
                suffixes.insert(last, at: 0)
            }
            for suffix in suffixes where (1...254).contains(suffix) {
                rawCandidates.append("http://\(prefix).\(suffix):8000")
            }
        }

        var unique: [String] = []
        for value in rawCandidates {
            guard let normalized = Self.normalizeURL(value) else { continue }
            if !unique.contains(normalized) {
                unique.append(normalized)
            }
        }
        return unique
    }

    private static func shouldRefreshDiscovery(for error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        let code = URLError.Code(rawValue: nsError.code)
        return code == .timedOut
            || code == .cannotConnectToHost
            || code == .networkConnectionLost
            || code == .notConnectedToInternet
            || code == .cannotFindHost
            || code == .dnsLookupFailed
    }

    private static func normalizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private static func localIPv4Prefix() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return nil
        }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let addr = interface.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "pdp_ip0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                address = String(cString: host)
                break
            }
        }

        guard let address else { return nil }
        let pieces = address.split(separator: ".")
        guard pieces.count == 4 else { return nil }
        return pieces.prefix(3).joined(separator: ".")
    }

    private static func lastOctet(of urlString: String) -> Int? {
        guard let host = URLComponents(string: urlString)?.host else { return nil }
        let pieces = host.split(separator: ".")
        guard pieces.count == 4 else { return nil }
        return Int(pieces[3])
    }
}

private actor BackendEndpointResolver {
    static let shared = BackendEndpointResolver()

    private let successKey = "lastSuccessfulBackendBaseURL"
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.8
        config.timeoutIntervalForResource = 1.2
        return URLSession(configuration: config)
    }()
    private var inMemoryURL: String?
    private var inMemoryUpdatedAt: Date?
    private let memoryTTL: TimeInterval = 300

    func resolve(preferred: String, candidates: [String], forceRefresh: Bool) async -> String {
        if !forceRefresh,
           let inMemoryURL,
           let inMemoryUpdatedAt,
           Date().timeIntervalSince(inMemoryUpdatedAt) <= memoryTTL {
            return inMemoryURL
        }
        if !forceRefresh, !preferred.isEmpty {
            if await isReachable(baseURL: preferred) {
                markSuccessInternal(preferred)
                return preferred
            }
        }
        for candidate in candidates {
            if await isReachable(baseURL: candidate) {
                markSuccessInternal(candidate)
                return candidate
            }
        }
        if !preferred.isEmpty {
            inMemoryURL = preferred
            inMemoryUpdatedAt = Date()
            return preferred
        }
        return "http://127.0.0.1:8000"
    }

    func markSuccess(_ baseURL: String) {
        markSuccessInternal(baseURL)
    }

    private func markSuccessInternal(_ baseURL: String) {
        inMemoryURL = baseURL
        inMemoryUpdatedAt = Date()
        UserDefaults.standard.set(baseURL, forKey: successKey)
    }

    private func isReachable(baseURL: String) async -> Bool {
        guard let healthURL = URL(string: baseURL + "/locations") else {
            return false
        }
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.8
        do {
            let (_, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

enum SparkAPIError: LocalizedError {
    case missingBackendConfig
    case invalidURL
    case serverError(code: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingBackendConfig:
            return "请先配置服务端地址，用于获取 Spark 的签名连接信息。"
        case .invalidURL:
            return "无法生成有效的 WebSocket URL。"
        case let .serverError(code, message):
            return "服务端错误(\(code))：\(message ?? "未知错误")"
        case .invalidResponse:
            return "服务响应格式异常。"
        }
    }
}

final class SparkChatClient {
    private let backend = SparkBackendConfig()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 240
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    @discardableResult
    func send(
        history: [ChatMessage],
        profileId: String?,
        tianshiId: String? = nil,
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) -> Task<Void, Never> {
        let messages = history.map { $0.asBackendMessage }
        return send(messages: messages, profileId: profileId, tianshiId: tianshiId, onDelta: onDelta, onComplete: onComplete)
    }

    @discardableResult
    func send(
        messages: [BackendMessage],
        profileId: String?,
        tianshiId: String? = nil,
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) -> Task<Void, Never> {
        guard backend.isValid else {
            onComplete(.failure(SparkAPIError.missingBackendConfig))
            return Task { }
        }

        let task = Task {
            do {
                let requestBody = BackendChatRequest(messages: messages, profileId: profileId, tianshiId: tianshiId)
                guard let encodedBody = try? JSONEncoder().encode(requestBody) else {
                    throw SparkAPIError.invalidResponse
                }
                let result = try await backend.performRequest { baseURL in
                    guard let url = URL(string: baseURL + self.backend.streamPath) else {
                        throw SparkAPIError.invalidURL
                    }
                    return try await self.streamResponse(url: url, body: encodedBody, onDelta: onDelta)
                }
                onComplete(.success(result))
            } catch {
                onComplete(.failure(error))
            }
        }
        return task
    }

    private func streamResponse(
        url: URL,
        body: Data,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 240

        let (bytes, _) = try await session.bytes(for: request)
        var currentEvent: String?
        var accumulated = ""

        for try await line in bytes.lines {
            if Task.isCancelled {
                throw CancellationError()
            }
            if line.hasPrefix("event:") {
                currentEvent = line.replacingOccurrences(of: "event:", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("data:") {
                let raw = line.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
                if currentEvent == "error" {
                    let message = raw.replacingOccurrences(of: "\\n", with: "\n")
                    throw SparkAPIError.serverError(code: 500, message: message)
                }
                if raw == "[DONE]" {
                    return accumulated
                }
                let chunk = raw.replacingOccurrences(of: "\\n", with: "\n")
                accumulated += chunk
                onDelta(chunk)
                continue
            }
            if line.isEmpty {
                currentEvent = nil
            }
        }

        return accumulated
    }
}

private struct BackendChatRequest: Encodable {
    let messages: [BackendMessage]
    let profileId: String?
    let tianshiId: String?
}

struct BackendMessage: Encodable {
    let role: String
    let content: String
}

private struct BackendTitleRequest: Encodable {
    let text: String
}

private struct BackendTitleResponse: Decodable {
    let title: String?
    let error: String?
}

extension ChatMessage {
    var asBackendMessage: BackendMessage {
        let content = (isUser && apiContent != nil) ? (apiContent ?? text) : text
        return BackendMessage(role: isUser ? "user" : "assistant", content: content)
    }
}

extension SparkChatClient {
    func fetchTitle(for text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard backend.isValid else {
            completion(.failure(SparkAPIError.missingBackendConfig))
            return
        }
        Task {
            do {
                let requestBody = BackendTitleRequest(text: text)
                guard let body = try? JSONEncoder().encode(requestBody) else {
                    throw SparkAPIError.invalidResponse
                }
                let title = try await backend.performRequest { baseURL in
                    guard let url = URL(string: baseURL + self.backend.titlePath) else {
                        throw SparkAPIError.invalidURL
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = body
                    request.timeoutInterval = 120
                    let (data, _) = try await self.session.data(for: request)
                    guard let response = try? JSONDecoder().decode(BackendTitleResponse.self, from: data) else {
                        throw SparkAPIError.invalidResponse
                    }
                    if let message = response.error, !message.isEmpty {
                        throw SparkAPIError.serverError(code: 500, message: message)
                    }
                    guard let title = response.title, !title.isEmpty else {
                        throw SparkAPIError.invalidResponse
                    }
                    return title
                }
                completion(.success(title))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
