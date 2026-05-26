import Foundation

/// Decoder for committed JSON test-vector fixtures. The fixtures are
/// stored under `PeerDropTests/CryptoTestKit/TestVectors/` and are
/// expected to be in the test bundle as resources. If `Bundle.url(forResource:withExtension:)`
/// returns `nil` at runtime, the project.yml's test target may need an
/// explicit resource-path declaration for the TestVectors subdirectory.
public enum TestVectorLoader {

    public enum LoadError: Error {
        case fileNotFound(URL)
        case decodeFailed(Error)
    }

    /// Load and decode a single fixture file.
    public static func load<T: Decodable>(from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LoadError.decodeFailed(error)
        }
    }

    /// Load all `.json` files in a bundle subdirectory, sorted by filename
    /// so vector ordering is stable across runs.
    public static func loadAll<T: Decodable>(matching subdirectory: String, in bundle: Bundle) throws -> [T] {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: subdirectory) ?? []
        return try urls
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .map { try load(from: $0) as T }
    }
}
