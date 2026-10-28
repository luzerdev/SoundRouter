import Foundation

/// Stores the configuration as JSON in ~/Library/Application Support/SoundRouter/config.json.
enum Persistence {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SoundRouter", isDirectory: true)
    }

    static var configURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else { return AppConfig() }
        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            let backup = directory.appendingPathComponent("config-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: configURL, to: backup)
            NSLog("SoundRouter: could not read config (\(error)); backed up to \(backup.path)")
            return AppConfig()
        }
    }

    static func save(_ config: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(config).write(to: configURL, options: .atomic)
        } catch {
            NSLog("SoundRouter: could not save config: \(error)")
        }
    }

    static func export(_ config: AppConfig, to url: URL) throws {
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    static func importConfig(from url: URL) throws -> AppConfig {
        try decoder.decode(AppConfig.self, from: Data(contentsOf: url))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
