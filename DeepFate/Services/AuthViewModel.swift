import Foundation
import LocalAuthentication

@MainActor
final class AuthViewModel: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var userId: String?
    @Published private(set) var displayName = ""
    @Published private(set) var hasArchiveRecord: Bool?
    @Published private(set) var needsAccountSetup = false
    @Published private(set) var debugSMSCode: String?
    @Published private(set) var accounts: [LocalAccount] = []
    @Published private(set) var faceIdEnabled = false
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let backend = SparkBackendConfig()
    private let userIdKey = "userId"
    private let accountsKey = "savedAccounts"
    private let faceIdEnabledKey = "faceIdEnabled"
    private let faceIdAccountIdKey = "faceIdAccountId"

    init() {
        accounts = loadAccounts()
        faceIdEnabled = UserDefaults.standard.bool(forKey: faceIdEnabledKey)
        let storedUserId = UserDefaults.standard.string(forKey: userIdKey) ?? ""
        if !storedUserId.isEmpty {
            userId = storedUserId
            if let account = accounts.first(where: { $0.id == storedUserId }) {
                displayName = account.nickname
            }
        }
    }

    func sendSMSCode(to phone: String) async {
        await runAuthFlow {
            let payload = ["phone": phone]
            let response: SMSCodeResponse = try await post(path: "/auth/sms/send", body: payload)
            debugSMSCode = response.code
        }
    }

    func verifySMSCode(phone: String, code: String) async {
        await runAuthFlow {
            let payload = ["phone": phone, "code": code]
            let response: SMSVerifyResponse = try await post(path: "/auth/sms/verify", body: payload)
            needsAccountSetup = !response.userExists
            if response.userExists, let user = response.user {
                applyAuthenticatedUser(user)
            }
        }
    }

    func signInWithPassword(phone: String, password: String) async {
        await runAuthFlow {
            let payload = ["phone": phone, "password": password]
            let response: LoginResponse = try await post(path: "/auth/login", body: payload)
            applyAuthenticatedUser(response.user)
        }
    }

    func registerAccount(phone: String, nickname: String, password: String) async {
        await runAuthFlow {
            let payload = ["phone": phone, "nickname": nickname, "password": password]
            let response: RegisterResponse = try await post(path: "/auth/register", body: payload)
            applyAuthenticatedUser(response.user)
        }
    }

    func resetPassword(phone: String, code: String, newPassword: String) async {
        await runAuthFlow {
            let payload = ["phone": phone, "code": code, "password": newPassword]
            let response: ResetPasswordResponse = try await post(path: "/auth/password/reset", body: payload)
            if response.ok == false {
                throw NSError(domain: "AuthAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "重置失败"])
            }
        }
    }

    func selectAccount(_ account: LocalAccount) {
        isAuthenticated = true
        userId = account.id
        displayName = account.nickname
        needsAccountSetup = false
        UserDefaults.standard.set(account.id, forKey: userIdKey)
    }

    func deleteAccount(id: String) {
        var updated = accounts
        if let account = updated.first(where: { $0.id == id }),
           let path = account.avatarPath {
            removeAvatarFile(path)
        }
        updated.removeAll { $0.id == id }
        accounts = updated
        saveAccounts(updated)

        if userId == id {
            isAuthenticated = false
            userId = nil
            displayName = ""
            hasArchiveRecord = nil
            needsAccountSetup = false
            UserDefaults.standard.removeObject(forKey: userIdKey)
        }
    }

    func updateAvatar(for id: String, data: Data?) {
        var updated = accounts
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        if let data {
            let path = saveAvatarData(id: id, data: data)
            updated[index].avatarPath = path
            updated[index].avatarData = nil
        } else {
            if let path = updated[index].avatarPath {
                removeAvatarFile(path)
            }
            updated[index].avatarPath = nil
            updated[index].avatarData = nil
        }
        accounts = updated
        saveAccounts(updated)
        if userId == id {
            displayName = updated[index].nickname
        }
    }

    func signOut() async {
        isAuthenticated = false
        userId = nil
        displayName = ""
        hasArchiveRecord = nil
        needsAccountSetup = false
        debugSMSCode = nil
        UserDefaults.standard.removeObject(forKey: userIdKey)
    }

    func enableFaceId(for accountId: String) {
        faceIdEnabled = true
        UserDefaults.standard.set(true, forKey: faceIdEnabledKey)
        UserDefaults.standard.set(accountId, forKey: faceIdAccountIdKey)
    }

    func disableFaceId() {
        faceIdEnabled = false
        UserDefaults.standard.set(false, forKey: faceIdEnabledKey)
        UserDefaults.standard.removeObject(forKey: faceIdAccountIdKey)
    }

    func signInWithFaceId(into profileStore: ProfileStore) async {
        guard faceIdEnabled else {
            errorMessage = "未绑定面容 ID 登录"
            return
        }
        guard let accountId = UserDefaults.standard.string(forKey: faceIdAccountIdKey),
              let account = accounts.first(where: { $0.id == accountId }) else {
            errorMessage = "未找到可用账号"
            return
        }
        let success = await authenticateWithBiometrics()
        guard success else { return }
        selectAccount(account)
        await syncArchives(into: profileStore)
    }

    func syncArchives(into profileStore: ProfileStore) async {
        guard let userId else { return }
        do {
            let profiles = try await fetchProfiles(for: userId)
            hasArchiveRecord = !profiles.isEmpty
            profileStore.syncFromRemote(profiles, preferredActiveId: nil)
        } catch {
            errorMessage = "档案同步失败：\(error.localizedDescription)"
        }
    }

    private func applyAuthenticatedUser(_ user: AuthUser) {
        isAuthenticated = true
        userId = user.id
        displayName = user.nickname
        needsAccountSetup = false
        UserDefaults.standard.set(user.id, forKey: userIdKey)
        upsertAccount(LocalAccount(id: user.id, phone: user.phone, nickname: user.nickname))
    }

    private func runAuthFlow(_ action: () async throws -> Void) async {
        errorMessage = nil
        isLoading = true
        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func post<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        guard let url = URL(string: backend.baseURL + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "请求失败"
            throw NSError(domain: "AuthAPI", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func fetchProfiles(for userId: String) async throws -> [UserProfile] {
        guard var components = URLComponents(string: backend.baseURL + "/profiles") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "请求失败"
            throw NSError(domain: "AuthAPI", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let decoder = JSONDecoder()
        let records = try decoder.decode([BackendProfile].self, from: data)
        return records.compactMap(mapBackendProfile)
    }

    private func mapBackendProfile(_ record: BackendProfile) -> UserProfile? {
        guard let solarComponents = parseComponents(record.solar) else { return nil }
        let lunarComponents = parseComponents(record.lunar) ?? solarComponents
        let birthInfo = BirthInfo(inputType: .solar, solarComponents: solarComponents, lunarComponents: lunarComponents)
        let location = parseBirthLocation(record)
        let trueSolar = parseComponents(record.trueSolar) ?? computeTrueSolarComponents(from: solarComponents, longitude: location.longitude) ?? solarComponents
        let createdAt = record.createdAt ?? Date()
        return UserProfile(
            id: record.id,
            name: record.name,
            gender: mapGender(record.gender),
            birthInfo: birthInfo,
            location: location,
            trueSolarComponents: trueSolar,
            createdAt: createdAt
        )
    }

    private func parseComponents(_ text: String?) -> DateComponents? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: text) else { return nil }
        return Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private func parseBirthLocation(_ record: BackendProfile) -> BirthLocation {
        let province = (record.locationProvince ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let city = (record.locationCity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let district = (record.locationDistrict ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (record.locationDetail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let longitude = record.longitude ?? 120.0
        let latitude = record.latitude ?? 0
        let timezoneID = (record.timezoneId ?? "").isEmpty ? "Asia/Shanghai" : (record.timezoneId ?? "Asia/Shanghai")
        let placeSource = (record.placeSource ?? "").isEmpty ? "manual" : (record.placeSource ?? "manual")

        if !province.isEmpty || !city.isEmpty || !district.isEmpty || !detail.isEmpty {
            return BirthLocation(
                province: province,
                city: city,
                district: district,
                detailAddress: detail,
                latitude: latitude,
                longitude: longitude,
                timezoneID: timezoneID,
                utcOffsetMinutesAtBirth: record.utcOffsetMinutes,
                placeSource: placeSource,
                locationAdcode: record.locationAdcode ?? ""
            )
        }

        let trimmed = (record.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "-" || $0 == "·" })
            .map(String.init)
        if parts.isEmpty {
            return BirthLocation(
                province: "未知",
                city: "",
                district: "",
                detailAddress: "",
                latitude: latitude,
                longitude: longitude,
                timezoneID: timezoneID,
                utcOffsetMinutesAtBirth: record.utcOffsetMinutes,
                placeSource: placeSource,
                locationAdcode: record.locationAdcode ?? ""
            )
        }
        let parsedProvince = parts[safe: 0] ?? ""
        let parsedCity = parts[safe: 1] ?? ""
        let parsedDistrict = parts[safe: 2] ?? ""
        return BirthLocation(
            province: parsedProvince,
            city: parsedCity,
            district: parsedDistrict,
            detailAddress: "",
            latitude: latitude,
            longitude: longitude,
            timezoneID: timezoneID,
            utcOffsetMinutesAtBirth: record.utcOffsetMinutes,
            placeSource: placeSource,
            locationAdcode: record.locationAdcode ?? ""
        )
    }

    private func mapGender(_ value: String?) -> Gender {
        if let value, let gender = Gender(rawValue: value) {
            return gender
        }
        return .other
    }

    private func authenticateWithBiometrics() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            errorMessage = "设备未开启面容 ID"
            return false
        }
        let reason = "使用面容 ID 登录"
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                DispatchQueue.main.async {
                    if !success {
                        self.errorMessage = "验证失败，请重试"
                    }
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func upsertAccount(_ account: LocalAccount) {
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == account.id }) {
            let existingAvatar = updated[index].avatarData
            let existingPath = updated[index].avatarPath
            updated[index] = LocalAccount(
                id: account.id,
                phone: account.phone,
                nickname: account.nickname,
                avatarData: existingAvatar,
                avatarPath: existingPath
            )
        } else {
            updated.insert(account, at: 0)
        }
        accounts = updated
        saveAccounts(updated)
    }

    private func loadAccounts() -> [LocalAccount] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else { return [] }
        return (try? JSONDecoder().decode([LocalAccount].self, from: data)) ?? []
    }

    private func saveAccounts(_ accounts: [LocalAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: accountsKey)
    }

    private func saveAvatarData(id: String, data: Data) -> String? {
        do {
            let directory = try avatarDirectory()
            let filename = "avatar_\(id).jpg"
            let url = directory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url.lastPathComponent
        } catch {
            return nil
        }
    }

    private func avatarDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("avatars", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func removeAvatarFile(_ filename: String) {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("avatars", isDirectory: true)
            .appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}

private struct AuthUser: Decodable {
    let id: String
    let phone: String
    let nickname: String
}

private struct SMSCodeResponse: Decodable {
    let ok: Bool
    let expiresIn: Int?
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case expiresIn = "expires_in"
        case code
    }
}

private struct SMSVerifyResponse: Decodable {
    let ok: Bool
    let userExists: Bool
    let user: AuthUser?

    private enum CodingKeys: String, CodingKey {
        case ok
        case userExists = "user_exists"
        case user
    }
}

private struct RegisterResponse: Decodable {
    let ok: Bool
    let user: AuthUser
}

private struct LoginResponse: Decodable {
    let ok: Bool
    let user: AuthUser
}

private struct ResetPasswordResponse: Decodable {
    let ok: Bool
}

private struct BackendProfile: Decodable {
    let id: UUID
    let name: String
    let gender: String?
    let location: String?
    let locationProvince: String?
    let locationCity: String?
    let locationDistrict: String?
    let locationDetail: String?
    let latitude: Double?
    let solar: String?
    let lunar: String?
    let trueSolar: String?
    let longitude: Double?
    let timezoneId: String?
    let utcOffsetMinutes: Int?
    let placeSource: String?
    let locationAdcode: String?
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case gender
        case location
        case locationProvince
        case locationCity
        case locationDistrict
        case locationDetail
        case latitude
        case solar
        case lunar
        case trueSolar
        case longitude
        case timezoneId
        case utcOffsetMinutes
        case placeSource
        case locationAdcode
        case createdAt = "created_at"
    }
}

struct LocalAccount: Identifiable, Codable, Equatable {
    let id: String
    let phone: String
    let nickname: String
    var avatarData: Data?
    var avatarPath: String?
}
