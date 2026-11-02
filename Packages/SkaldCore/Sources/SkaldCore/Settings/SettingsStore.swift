import Foundation

public enum SettingsStoreError: Error {
    case readOnly
}

public final class SettingsStore: @unchecked Sendable { // reason: the only mutable state, readOnly, is guarded by lock
    public enum LoadOutcome {
        case loaded(Settings)
        case fresh(Settings)
        case recoveredFromCorrupt(Settings)
        case futureVersion(Int)
    }

    private struct VersionProbe: Decodable {
        let version: Int?
    }

    private let directory: URL
    private let lock = NSLock()
    private var readOnly = false

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent("settings.json") }
    private var corruptURL: URL { directory.appendingPathComponent("settings.corrupt.json") }

    public func load() -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .fresh(Settings()) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: fileURL)
            let version = try decoder.decode(VersionProbe.self, from: data).version ?? Settings.currentVersion
            if version > Settings.currentVersion {
                setReadOnly(true)
                return .futureVersion(version)
            }
            return .loaded(try decoder.decode(Settings.self, from: data))
        } catch {
            moveCorruptFileAside()
            return .recoveredFromCorrupt(Settings())
        }
    }

    public func save(_ settings: Settings) throws {
        guard !isReadOnly else { throw SettingsStoreError.readOnly }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private var isReadOnly: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readOnly
    }

    private func setReadOnly(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        readOnly = value
    }

    private func moveCorruptFileAside() {
        try? FileManager.default.removeItem(at: corruptURL)
        try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
    }
}
