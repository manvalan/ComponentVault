import Foundation

struct LCSCProvider: ComponentDataProvider {
    let source: DataSource = .lcsc

    private static let localArchivePath = "/Users/michelebigi/LCSC/json_full_data"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(lcscCode: String) async throws -> ComponentRecord {
        let code = lcscCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.hasPrefix("C"), code.count >= 4 else {
            throw ProviderError.invalidCode
        }

        do {
            return try await fetchLive(lcscCode: code)
        } catch ProviderError.parseFailure {
            if let local = Self.loadLocalArchive(lcscCode: code) {
                return local
            }
            throw ProviderError.parseFailure
        }
    }

    private func fetchLive(lcscCode: String) async throws -> ComponentRecord {
        let url = URL(string: "https://www.lcsc.com/product-detail/\(lcscCode).html")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("it-IT,it;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure("Risposta non valida")
        }
        guard http.statusCode == 200 else {
            if let local = Self.loadLocalArchive(lcscCode: lcscCode) {
                return local
            }
            throw ProviderError.notFound(lcscCode)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.parseFailure
        }

        return try LCSCParser.parse(html: html, lcscCode: lcscCode)
    }

    private static func loadLocalArchive(lcscCode: String) -> ComponentRecord? {
        let path = "\(localArchivePath)/\(lcscCode).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let record = try? JSONDecoder().decode(ComponentRecord.self, from: data) else {
            return nil
        }
        return record
    }
}
