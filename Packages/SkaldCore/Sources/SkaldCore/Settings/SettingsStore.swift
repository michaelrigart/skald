import Foundation

public enum SettingsStoreError: Error {
    case readOnly
}

public final class SettingsStore: @unchecked Sendable { // reason: the only mutable state, readOnly, is guarded by lock
    public enum LoadOutcome: Equatable, Sendable {
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
        setReadOnly(false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .fresh(Settings()) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            setReadOnly(true)
            return .recoveredFromCorrupt(Settings())
        }
        do {
            let version = try decoder.decode(VersionProbe.self, from: data).version ?? Settings.currentVersion
            if version > Settings.currentVersion {
                setReadOnly(true)
                return .futureVersion(version)
            }
            return .loaded(try decoder.decode(Settings.self, from: data))
        } catch {
            if !moveCorruptFileAside() { setReadOnly(true) }
            return .recoveredFromCorrupt(Settings())
        }
    }

    public func save(_ settings: Settings) throws {
        guard !isReadOnly else { throw SettingsStoreError.readOnly }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.fractionalStyle))
        }
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

    private func moveCorruptFileAside() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: corruptURL.path) {
                try FileManager.default.removeItem(at: corruptURL)
            }
            try FileManager.default.moveItem(at: fileURL, to: corruptURL)
            return true
        } catch {
            return false
        }
    }

    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let text = try decoder.singleValueContainer().decode(String.self)
        if let date = try? fractionalStyle.parse(text) { return date }
        return try Date.ISO8601FormatStyle().parse(text)
    }
}
