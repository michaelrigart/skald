import Foundation
import SkaldCore

public enum EvalReplay {
    private struct Recorded: Decodable {
        let id: String
        let output: String?
    }

    public static func load(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            let record = try JSONDecoder().decode(Recorded.self, from: Data(line.utf8))
            if let output = record.output { table[record.id] = output }
        }
        return table
    }
}

public enum EvalOutputLines {
    public static func encode(_ outputs: [EvalOutput]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try outputs.reduce(into: Data()) { data, output in
            data.append(try encoder.encode(output))
            data.append(0x0A)
        }
    }
}

/// The files a run other than `--mode claude` writes: `--out`, and beside it `<out>.raw.jsonl` on the model path.
/// No run overwrites an earlier run's record.
public enum EvalOutputFiles {
    public static func rawPath(_ out: String) -> String {
        out + ".raw.jsonl"
    }

    /// Throws before anything runs when a file the run would write already exists. A claude run keeps its own files.
    public static func requireFresh(_ options: EvalOptions) throws(EvalUsageError) {
        guard options.mode != .claude, let out = options.out else { return }
        for path in [out] + (options.mode.isModelPath ? [rawPath(out)] : []) where FileManager.default.fileExists(atPath: path) {
            throw EvalUsageError(message: exists(path))
        }
    }

    public static func save(_ run: EvalRun, to out: String) throws(EvalUsageError) {
        try write(run.outputs, to: out)
        if !run.raw.isEmpty { try write(run.raw, to: rawPath(out)) }
    }

    private static func write(_ outputs: [EvalOutput], to path: String) throws(EvalUsageError) {
        guard !FileManager.default.fileExists(atPath: path) else { throw EvalUsageError(message: exists(path)) }
        do {
            try EvalOutputLines.encode(outputs).write(to: URL(filePath: path), options: .withoutOverwriting)
        } catch {
            throw EvalUsageError(message: "cannot write \(path): \(error)")
        }
    }

    private static func exists(_ path: String) -> String {
        "\(path) already exists; skald-eval never overwrites an earlier run's output"
    }
}

/// The three files a paid run keeps its record in, created before the first request and never over an earlier run's.
public actor EvalClaudeFiles {
    public nonisolated let out: URL
    public nonisolated let raw: URL
    public nonisolated let usage: URL
    private let outHandle: FileHandle
    private let rawHandle: FileHandle

    public init(out path: String) throws(EvalUsageError) {
        out = URL(filePath: path)
        raw = URL(filePath: path + ".raw.jsonl")
        usage = URL(filePath: path + ".usage.jsonl")
        let urls = [out, raw, usage]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            throw EvalUsageError(message: "\(url.path) already exists; a claude run never overwrites an earlier run's answers")
        }
        var handles: [FileHandle] = []
        for url in urls {
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard descriptor >= 0 else {
                let reason = String(cString: strerror(errno))
                for (handle, created) in zip(handles, urls) {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: created)
                }
                throw EvalUsageError(message: "cannot create \(url.path): \(reason)")
            }
            handles.append(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
        }
        try? handles[2].close()
        outHandle = handles[0]
        rawHandle = handles[1]
    }

    public func append(_ output: EvalOutput, raw rawOutput: EvalOutput?) throws(EvalUsageError) {
        try write([output], to: outHandle, at: out)
        if let rawOutput { try write([rawOutput], to: rawHandle, at: raw) }
    }

    private func write(_ outputs: [EvalOutput], to handle: FileHandle, at url: URL) throws(EvalUsageError) {
        do {
            try handle.write(contentsOf: try EvalOutputLines.encode(outputs))
        } catch {
            throw EvalUsageError(message: "cannot write \(url.path): \(error.localizedDescription)")
        }
    }
}

public struct EvalClaudeSession: Sendable {
    public let engine: ClaudeEngine
    public let tracker: CostTrackingTransport
    public let files: EvalClaudeFiles

    /// Everything that can stop a paid run before its first request: the key, a priced model and the three files.
    public static func open(_ options: EvalOptions, environment: [String: String], transport: any HTTPTransport) throws(EvalUsageError) -> EvalClaudeSession {
        let key = try EvalClaudeKey.read(from: environment)
        guard let model = options.claudeModel, let price = ModelPrice.forModel(model), let maxCost = options.maxCost, let out = options.out else {
            throw EvalUsageError(message: EvalOptions.usage)
        }
        let files = try EvalClaudeFiles(out: out)
        let tracker = CostTrackingTransport(inner: transport, price: price, maxCost: maxCost, usageLog: files.usage)
        let engine = ClaudeEngine(model: model, apiKey: { key }, transport: tracker, options: options.claudeRequest)
        return EvalClaudeSession(engine: engine, tracker: tracker, files: files)
    }
}

public enum EvalClaudeKey {
    public static let variable = "SKALD_EVAL_CLAUDE_KEY"

    public static func read(from environment: [String: String]) throws(EvalUsageError) -> String {
        guard let key = environment[variable], !key.isEmpty else { throw EvalUsageError(message: "set \(variable) to a Claude API key") }
        return key
    }
}
