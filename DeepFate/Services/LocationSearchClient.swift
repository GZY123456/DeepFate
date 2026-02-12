import Foundation
import MapKit

struct GeoLocationSuggestion: Identifiable, Equatable {
    let id: String
    let name: String
    let province: String
    let city: String
    let district: String
    let detailAddress: String
    let fullAddress: String
    let longitude: Double
    let latitude: Double
    let timezoneID: String
    let utcOffsetMinutes: Int?
    let source: String
    let adcode: String

    var displayAddress: String {
        if fullAddress.isEmpty {
            return [province, city, district].filter { !$0.isEmpty }.joined()
        }
        return fullAddress
    }
}

final class LocationSearchClient {
    private let backend = SparkBackendConfig()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(keyword: String, limit: Int = 20) async throws -> [GeoLocationSuggestion] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let size = max(1, min(limit, 20))
        do {
            guard var components = URLComponents(string: backend.baseURL + "/geo/search") else {
                throw URLError(.badURL)
            }
            components.queryItems = [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "limit", value: "\(size)")
            ]
            guard let url = components.url else {
                throw URLError(.badURL)
            }
            let (data, response) = try await session.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "地点检索失败"
                throw NSError(domain: "LocationSearchClient", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            let decoded = try JSONDecoder().decode(GeoSearchResponse.self, from: data)
            return decoded.items.map { item in
                GeoLocationSuggestion(
                    id: "\(item.adcode)-\(item.longitude)-\(item.latitude)-\(item.name)",
                    name: item.name,
                    province: item.province,
                    city: item.city,
                    district: item.district,
                    detailAddress: item.detailAddress,
                    fullAddress: item.fullAddress,
                    longitude: item.longitude,
                    latitude: item.latitude,
                    timezoneID: item.timezoneId,
                    utcOffsetMinutes: item.utcOffsetMinutes,
                    source: item.source,
                    adcode: item.adcode
                )
            }
        } catch {
            return try await searchViaMapKit(keyword: q, limit: size)
        }
    }

    private func searchViaMapKit(keyword: String, limit: Int) async throws -> [GeoLocationSuggestion] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = keyword
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(limit).map { item in
            let placemark = item.placemark
            let province = placemark.administrativeArea ?? ""
            let city = placemark.locality ?? placemark.subAdministrativeArea ?? ""
            let district = placemark.subLocality ?? ""
            let detail = placemark.thoroughfare ?? placemark.name ?? ""
            let timezoneID = placemark.timeZone?.identifier ?? "Asia/Shanghai"
            let utcOffset = placemark.timeZone?.secondsFromGMT(for: Date()) ?? 8 * 3600
            return GeoLocationSuggestion(
                id: "\(item.placemark.coordinate.longitude)-\(item.placemark.coordinate.latitude)-\(item.name ?? "")",
                name: item.name ?? district,
                province: province,
                city: city,
                district: district,
                detailAddress: detail,
                fullAddress: [
                    province,
                    city,
                    district,
                    detail
                ].filter { !$0.isEmpty }.joined(separator: " "),
                longitude: item.placemark.coordinate.longitude,
                latitude: item.placemark.coordinate.latitude,
                timezoneID: timezoneID,
                utcOffsetMinutes: Int(utcOffset / 60),
                source: "apple_mapkit",
                adcode: ""
            )
        }
    }
}

private struct GeoSearchResponse: Decodable {
    let items: [GeoSearchItem]
}

private struct GeoSearchItem: Decodable {
    let name: String
    let province: String
    let city: String
    let district: String
    let detailAddress: String
    let fullAddress: String
    let longitude: Double
    let latitude: Double
    let adcode: String
    let timezoneId: String
    let utcOffsetMinutes: Int?
    let source: String
}
