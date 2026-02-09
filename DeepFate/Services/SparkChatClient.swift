import Foundation

struct SparkBackendConfig {
    private let defaultURL: String = "http://192.168.0.103:8000"
    var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "backendBaseURL") ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldMigrateStoredURL(trimmed) {
            UserDefaults.standard.set(defaultURL, forKey: "backendBaseURL")
            return defaultURL
        }
        return trimmed.isEmpty ? defaultURL : trimmed
    }
    let chatPath: String = "/spark/chat"
    let streamPath: String = "/spark/chat/stream"
    let titlePath: String = "/spark/title"

    var isValid: Bool {
        !baseURL.isEmpty
    }

    private func shouldMigrateStoredURL(_ storedURL: String) -> Bool {
        guard !storedURL.isEmpty else { return false }
        guard let stored = URL(string: storedURL),
              let storedHost = stored.host,
              let defaults = URL(string: defaultURL),
              let defaultHost = defaults.host else { return false }
        // Keep user-defined non-IP endpoints (e.g. domain/ngrok) unchanged.
        guard isIPv4(storedHost), isPrivateIPv4(storedHost) else { return false }
        return storedHost != defaultHost
    }

    private func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            return true
        }
    }

    private func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        return false
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
    private let session = URLSession(configuration: .default)

    @discardableResult
    func send(
        history: [ChatMessage],
        profileId: String?,
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) -> Task<Void, Never> {
        let messages = history.map { $0.asBackendMessage }
        return send(messages: messages, profileId: profileId, onDelta: onDelta, onComplete: onComplete)
    }

    @discardableResult
    func send(
        messages: [BackendMessage],
        profileId: String?,
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) -> Task<Void, Never> {
        guard backend.isValid else {
            onComplete(.failure(SparkAPIError.missingBackendConfig))
            return Task { }
        }
        guard let url = URL(string: backend.baseURL + backend.streamPath) else {
            onComplete(.failure(SparkAPIError.invalidURL))
            return Task { }
        }

        let requestBody = BackendChatRequest(messages: messages, profileId: profileId)
        guard let data = try? JSONEncoder().encode(requestBody) else {
            onComplete(.failure(SparkAPIError.invalidResponse))
            return Task { }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let task = Task {
            do {
                let (bytes, _) = try await session.bytes(for: request)
                var currentEvent: String?
                var accumulated = ""
                var completed = false

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
                            completed = true
                            let message = raw.replacingOccurrences(of: "\\n", with: "\n")
                            onComplete(.failure(SparkAPIError.serverError(code: 500, message: message)))
                            break
                        }
                        if raw == "[DONE]" {
                            completed = true
                            onComplete(.success(accumulated))
                            break
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

                if !completed {
                    onComplete(.success(accumulated))
                }
            } catch {
                onComplete(.failure(error))
            }
        }
        return task
    }
}

private struct BackendChatRequest: Encodable {
    let messages: [BackendMessage]
    let profileId: String?
}

struct BackendMessage: Encodable {
    let role: String
    let content: String
}

private struct BackendChatResponse: Decodable {
    let content: String?
    let error: String?
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
        BackendMessage(role: isUser ? "user" : "assistant", content: text)
    }
}

extension SparkChatClient {
    func fetchTitle(for text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard backend.isValid else {
            completion(.failure(SparkAPIError.missingBackendConfig))
            return
        }
        guard let url = URL(string: backend.baseURL + backend.titlePath) else {
            completion(.failure(SparkAPIError.invalidURL))
            return
        }
        let requestBody = BackendTitleRequest(text: text)
        guard let data = try? JSONEncoder().encode(requestBody) else {
            completion(.failure(SparkAPIError.invalidResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        session.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let response = try? JSONDecoder().decode(BackendTitleResponse.self, from: data) else {
                completion(.failure(SparkAPIError.invalidResponse))
                return
            }
            if let message = response.error, !message.isEmpty {
                completion(.failure(SparkAPIError.serverError(code: 500, message: message)))
                return
            }
            guard let title = response.title, !title.isEmpty else {
                completion(.failure(SparkAPIError.invalidResponse))
                return
            }
            completion(.success(title))
        }.resume()
    }
}
