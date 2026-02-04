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
        guard let url = URL(string: backend.baseURL + "/profiles") else { return }
        let payload = BackendProfilePayload(from: profile, userId: userId)
        guard let data = try? JSONEncoder().encode(payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        Task {
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
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
        guard var components = URLComponents(string: backend.baseURL + "/profiles/\(id.uuidString)") else { return }
        components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        Task {
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
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
    let solar: String
    let lunar: String
    let trueSolar: String

    init(from profile: UserProfile, userId: String?) {
        id = profile.id.uuidString
        self.userId = userId
        name = profile.name
        gender = profile.gender.rawValue
        location = "\(profile.location.province)\(profile.location.city)\(profile.location.district)"
        solar = formatDateComponents(profile.birthInfo.solarComponents)
        lunar = formatDateComponents(profile.birthInfo.lunarComponents)
        trueSolar = formatDateComponents(profile.trueSolarComponents)
    }
}

private var currentUserId: String? {
    let value = UserDefaults.standard.string(forKey: "userId") ?? ""
    return value.isEmpty ? nil : value
}
