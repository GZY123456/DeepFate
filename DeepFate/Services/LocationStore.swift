import Foundation

final class LocationStore: ObservableObject {
    @Published private(set) var provinces: [ProvinceOption] = []

    private let session: URLSession
    private let cacheURL: URL
    private let backend = SparkBackendConfig()

    init(session: URLSession = .shared) {
        self.session = session
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
        guard let url = URL(string: backend.baseURL + "/locations") else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            let decoded = try JSONDecoder().decode([ProvinceOption].self, from: data)
            await MainActor.run {
                self.provinces = decoded
            }
            saveCache(data)
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
