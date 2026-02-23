import Foundation

final class LocationStore: ObservableObject {
    @Published private(set) var provinces: [ProvinceOption] = []

    private let session: URLSession
    private let cacheURL: URL
    private let backend = SparkBackendConfig()

    /// 请求超时时间（秒）。若后端未启动或地址错误会得到 NSURLErrorDomain -1001（超时），此时会继续使用缓存或默认省列表。
    private static let requestTimeout: TimeInterval = 20

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.requestTimeout
            config.timeoutIntervalForResource = Self.requestTimeout + 10
            self.session = URLSession(configuration: config)
        }
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let folder = baseURL ?? FileManager.default.temporaryDirectory
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        cacheURL = folder.appendingPathComponent("locations.json")
        loadCache()
        if provinces.isEmpty {
            provinces = defaultLocationOptions
        }
    }

    func refresh() async {
        do {
            let decoded: [ProvinceOption] = try await backend.performRequest { baseURL in
                guard let url = URL(string: baseURL + "/locations") else {
                    throw URLError(.badURL)
                }
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return try JSONDecoder().decode([ProvinceOption].self, from: data)
            }
            guard !decoded.isEmpty else { return }
            await MainActor.run {
                self.provinces = decoded
            }
            if let encoded = try? JSONEncoder().encode(decoded) {
                saveCache(encoded)
            }
        } catch {
            // Ignore network errors; keep cached data.
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([ProvinceOption].self, from: data) else {
            return
        }
        provinces = decoded
    }

    private func saveCache(_ data: Data) {
        try? data.write(to: cacheURL, options: [.atomic])
    }
}
