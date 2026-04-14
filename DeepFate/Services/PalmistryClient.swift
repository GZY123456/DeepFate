import Foundation
import UIKit

enum PalmistryClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case encodeFailed
    case serverError(code: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的服务地址"
        case .invalidResponse:
            return "手相服务响应格式异常"
        case .encodeFailed:
            return "图片编码失败"
        case let .serverError(code, message):
            return "服务错误(\(code))：\(message ?? "未知")"
        }
    }
}

struct PalmistryClient {
    private let backend = SparkBackendConfig()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    func segment(
        profileId: UUID,
        handSide: PalmHandSide,
        capturedAt: Date,
        image: UIImage,
        landmarks: [String: PalmLandmarkPoint]
    ) async throws -> PalmistryResult {
        guard let jpegData = image.jpegData(compressionQuality: 0.94) else {
            throw PalmistryClientError.encodeFailed
        }
        let payload = PalmistryAnalyzeRequest(
            profileId: profileId.uuidString,
            handSide: handSide.rawValue,
            capturedAt: Self.isoFormatter.string(from: capturedAt),
            imageBase64: jpegData.base64EncodedString(),
            landmarks: landmarks,
            imageWidth: Int(image.size.width),
            imageHeight: Int(image.size.height)
        )

        return try await backend.performRequest { baseURL in
            guard let url = URL(string: baseURL + "/palmistry/segment") else {
                throw PalmistryClientError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)
            return try decodeResult(data: data, response: response)
        }
    }

    func startReport(profileId: UUID, readingId: String) async throws {
        try await backend.performRequest { baseURL in
            guard let url = URL(string: baseURL + "/palmistry/report") else {
                throw PalmistryClientError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                PalmistryReportStartRequest(profileId: profileId.uuidString, readingId: readingId)
            )
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PalmistryClientError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw PalmistryClientError.serverError(code: http.statusCode, message: nil)
            }
        }
    }

    func fetchReportStatus(profileId: UUID, readingId: String) async throws -> PalmistryReportStatusPayload {
        try await backend.performRequest { baseURL in
            guard var components = URLComponents(string: baseURL + "/palmistry/\(readingId)/report-status") else {
                throw PalmistryClientError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "profile_id", value: profileId.uuidString)]
            guard let url = components.url else {
                throw PalmistryClientError.invalidURL
            }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw PalmistryClientError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw PalmistryClientError.serverError(code: http.statusCode, message: msg)
            }
            return try JSONDecoder().decode(PalmistryReportStatusPayload.self, from: data)
        }
    }

    func fetchHistory(profileId: UUID, limit: Int = 30) async throws -> [PalmistryHistoryItem] {
        try await backend.performRequest { baseURL in
            guard var components = URLComponents(string: baseURL + "/palmistry/history") else {
                throw PalmistryClientError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "profile_id", value: profileId.uuidString),
                URLQueryItem(name: "limit", value: String(limit))
            ]
            guard let url = components.url else {
                throw PalmistryClientError.invalidURL
            }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw PalmistryClientError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw PalmistryClientError.serverError(code: http.statusCode, message: msg)
            }
            return try JSONDecoder().decode([PalmistryHistoryItem].self, from: data)
        }
    }

    func fetchResult(profileId: UUID, readingId: String) async throws -> PalmistryResult {
        try await backend.performRequest { baseURL in
            guard var components = URLComponents(string: baseURL + "/palmistry/\(readingId)") else {
                throw PalmistryClientError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "profile_id", value: profileId.uuidString)]
            guard let url = components.url else {
                throw PalmistryClientError.invalidURL
            }
            let (data, response) = try await session.data(from: url)
            return try decodeResult(data: data, response: response)
        }
    }

    private func decodeResult(data: Data, response: URLResponse) throws -> PalmistryResult {
        guard let http = response as? HTTPURLResponse else {
            throw PalmistryClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PalmistryClientError.serverError(code: http.statusCode, message: msg)
        }
        return try JSONDecoder().decode(PalmistryResult.self, from: data)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct PalmistryAnalyzeRequest: Encodable {
    let profileId: String
    let handSide: String
    let capturedAt: String
    let imageBase64: String
    let landmarks: [String: PalmLandmarkPoint]
    let imageWidth: Int
    let imageHeight: Int
}

private struct PalmistryReportStartRequest: Encodable {
    let profileId: String
    let readingId: String
}
