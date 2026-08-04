import Foundation

/// The Swift face of the shared model manifest (Resources/models.json — the
/// same file the web imports via web/src/models/adapters.ts). All per-model
/// knowledge comes from here: catalog entries, capabilities, validation quirks.
struct ManifestModel: Decodable {
    struct Display: Decodable {
        let name: String
        let size: String
        let note: String
        let recommended: Bool
    }

    struct Validate: Decodable {
        let echoMarkers: [String]?
        let maxGrowth: Double?
    }

    let id: String
    let file: String
    let url: URL
    let display: Display
    let capabilities: [String]
    let languages: [String]?
    let license: String
    let validate: Validate?
}

enum ModelManifest {
    private struct Root: Decodable { let models: [ManifestModel] }

    /// Loaded once from the resource bundle; empty on a malformed manifest
    /// (which would also break the web build, so it can't drift silently).
    static let models: [ManifestModel] = {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(Root.self, from: data) else {
            print("⚠️ models.json missing or malformed — catalog empty")
            return []
        }
        return root.models
    }()

    static func byID(_ id: String) -> ManifestModel? {
        models.first { $0.id == id }
    }

    static func byFile(_ file: String) -> ManifestModel? {
        models.first { $0.file == file }
    }
}
