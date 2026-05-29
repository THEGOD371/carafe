import Foundation

// MARK: - Public response models

struct SteamGridDBGame: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let releaseDate: Int?
    let verified: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case releaseDate = "release_date"
        case verified
    }
}

struct SteamGridDBGrid: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let score: Int?
    let style: String?
    let url: URL
    let thumb: URL?
    let width: Int?
    let height: Int?
}

// MARK: - Client

/// Minimal SteamGridDB API client. Two endpoints:
///   - GET /api/v2/search/autocomplete/{term}    — search games by name
///   - GET /api/v2/grids/game/{id}?dimensions=…  — cover-art grids for a game
///
/// Auth: `Authorization: Bearer <api-key>` (key lives in the Keychain).
/// Missing key isn't an error — it's a documented degraded mode that
/// `hasAPIKey` exposes so the UI can render a "set up your key" hint.
///
/// FRAGILITY: the response wire formats are stable but the SteamGridDB
/// rate limits, cdn hostnames, and `dimensions` query syntax are not
/// strictly contractual. If we start getting `httpStatus(400)` failures
/// the dimensions filter is the first place to look.
final class SteamGridDBClient: Sendable {

    enum Failure: LocalizedError, Sendable {
        case noAPIKey
        case unauthorized
        case rateLimited
        case network(String)
        case decoding(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:               return "No SteamGridDB API key set. Add one in Settings → API Keys."
            case .unauthorized:           return "SteamGridDB rejected the API key (401). Check that it's pasted correctly."
            case .rateLimited:            return "Rate limited by SteamGridDB. Try again in a minute."
            case .network(let detail):    return "Network error: \(detail)"
            case .decoding(let detail):   return "Couldn't read SteamGridDB response: \(detail)"
            case .http(let code, let m):  return "SteamGridDB HTTP \(code): \(m)"
            }
        }
    }

    private let baseURL = URL(string: "https://www.steamgriddb.com/api/v2")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var hasAPIKey: Bool {
        let key = CarafeKeychain.getString(account: .steamGridDBAPIKey)
        return !(key?.isEmpty ?? true)
    }

    // MARK: - Endpoints

    func search(term: String) async throws -> [SteamGridDBGame] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let url = baseURL.appendingPathComponent("search/autocomplete/\(encoded)")
        let envelope: Envelope<[SteamGridDBGame]> = try await get(url: url)
        return envelope.data ?? []
    }

    func grids(forGameID gameID: Int, portraitOnly: Bool = true) async throws -> [SteamGridDBGrid] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("grids/game/\(gameID)"),
            resolvingAgainstBaseURL: false
        )!
        if portraitOnly {
            // 600×900 is the canonical Steam grid portrait size.
            components.queryItems = [URLQueryItem(name: "dimensions", value: "600x900")]
        }
        guard let url = components.url else {
            throw Failure.network("Couldn't build grids URL")
        }
        let envelope: Envelope<[SteamGridDBGrid]> = try await get(url: url)
        return envelope.data ?? []
    }

    /// Cheap validity probe: a search for "foo" should always 200 for
    /// a valid key, and 401 for a bad one.
    func validateAPIKey(_ key: String) async throws {
        let url = baseURL.appendingPathComponent("search/autocomplete/foo")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (_, response) = try await session.data(for: request)
        try check(response: response)
    }

    /// Download a cover image to a temp file under the system tmp
    /// dir. Caller (GameLibrary.setCoverArt) is responsible for
    /// moving it into the cover-art cache.
    func download(from remote: URL) async throws -> URL {
        var request = URLRequest(url: remote)
        request.timeoutInterval = 30
        do {
            let (tempURL, response) = try await session.download(for: request)
            try check(response: response)
            // download() returns a URL the OS will delete when the
            // task object is deinitialized. Move it into our own tmp
            // path so the caller has time to consume it.
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("carafe-cover-\(UUID().uuidString).\(remote.pathExtension)")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tempURL, to: dst)
            return dst
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.network(error.localizedDescription)
        }
    }

    // MARK: - Internals

    private struct Envelope<T: Codable & Sendable>: Codable, Sendable {
        let success: Bool
        let data: T?
        let errors: [String]?
    }

    private func get<T: Codable & Sendable>(url: URL) async throws -> Envelope<T> {
        guard let apiKey = CarafeKeychain.getString(account: .steamGridDBAPIKey),
              !apiKey.isEmpty else {
            throw Failure.noAPIKey
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        try check(response: response)
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw Failure.decoding(error.localizedDescription)
        }
    }

    private func check(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401:       throw Failure.unauthorized
        case 429:       throw Failure.rateLimited
        default:
            throw Failure.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }
}
