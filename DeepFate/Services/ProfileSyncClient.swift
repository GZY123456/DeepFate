import Foundation

final class ProfileSyncClient {
    private let backend = SparkBackendConfig()
    private let session = URLSession(configuration: .default)

    func upsert(_ profile: UserProfile) {
        guard backend.isValid else {
            print("[profiles] backend invalid")
            return
        }
        guard let userId = currentUserId else {
            print("[profiles] skip upsert without userId")
            return
        }
        let payload = BackendProfilePayload(from: profile, userId: userId)
        Task {
            do {
                let response: HTTPURLResponse = try await backend.performRequest { baseURL in
                    guard let url = URL(string: baseURL + "/profiles") else {
                        throw URLError(.badURL)
                    }
                    guard let data = try? JSONEncoder().encode(payload) else {
                        throw URLError(.badURL)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = data
                    let (_, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    return http
                }
                let status = response.statusCode
                print("[profiles] upsert status=\(status) id=\(profile.id.uuidString)")
            } catch {
                print("[profiles] upsert failed id=\(profile.id.uuidString) error=\(error.localizedDescription)")
            }
        }
    }

    func delete(id: UUID) {
        guard backend.isValid else {
            print("[profiles] backend invalid")
            return
        }
        guard let userId = currentUserId else {
            print("[profiles] skip delete without userId")
            return
        }
        Task {
            do {
                let response: HTTPURLResponse = try await backend.performRequest { baseURL in
                    guard var components = URLComponents(string: baseURL + "/profiles/\(id.uuidString)") else {
                        throw URLError(.badURL)
                    }
                    components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
                    guard let url = components.url else {
                        throw URLError(.badURL)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "DELETE"
                    let (_, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    return http
                }
                let status = response.statusCode
                print("[profiles] delete status=\(status) id=\(id.uuidString)")
            } catch {
                print("[profiles] delete failed id=\(id.uuidString) error=\(error.localizedDescription)")
            }
        }
    }
}

private struct BackendProfilePayload: Encodable {
    let id: String
    let userId: String?
    let name: String
    let gender: String
    let location: String
    let locationProvince: String
    let locationCity: String
    let locationDistrict: String
    let locationDetail: String
    let latitude: Double
    let longitude: Double
    let timezoneId: String
    let utcOffsetMinutes: Int?
    let placeSource: String
    let locationAdcode: String
    let solar: String
    let lunar: String
    let trueSolar: String

    init(from profile: UserProfile, userId: String?) {
        id = profile.id.uuidString
        self.userId = userId
        name = profile.name
        gender = profile.gender.rawValue
        location = profile.location.fullDisplayText
        locationProvince = profile.location.province
        locationCity = profile.location.city
        locationDistrict = profile.location.district
        locationDetail = profile.location.detailAddress
        latitude = profile.location.latitude
        longitude = profile.location.longitude
        timezoneId = profile.location.timezoneID
        utcOffsetMinutes = profile.location.utcOffsetMinutesAtBirth
        placeSource = profile.location.placeSource
        locationAdcode = profile.location.locationAdcode
        solar = formatDateComponents(profile.birthInfo.solarComponents)
        lunar = formatDateComponents(profile.birthInfo.lunarComponents)
        trueSolar = formatDateComponents(profile.trueSolarComponents)
    }
}

private var currentUserId: String? {
    let value = UserDefaults.standard.string(forKey: "userId") ?? ""
    return value.isEmpty ? nil : value
}
