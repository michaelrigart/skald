#if DEBUG
import Foundation

/// A write the probe made earlier in this run, carried into later sessions on the same field.
struct PriorWrite: Sendable {
    var start: WriteStart
    var undoPresses: Int
}

/// The fields the probe wrote in this run: each field is written once per run. A field is known by its identity, or,
/// when the app hands back the element under a new hash, by a value equal to the text before a write in the same app.
/// The texts stay in memory and are never logged.
struct WrittenFields {
    struct Match {
        var identity: String
        var prior: PriorWrite
    }

    private struct Entry {
        var identity: String
        var pid: pid_t
        var prior: PriorWrite
    }

    private var entries: [Entry] = []

    func prior(identity: String, pid: pid_t, value: String?) -> Match? {
        let entry = entries.first { $0.identity == identity }
            ?? value.flatMap { value in entries.first { $0.pid == pid && $0.prior.start.original == value } }
        return entry.map { Match(identity: $0.identity, prior: $0.prior) }
    }

    mutating func record(_ prior: PriorWrite, for identity: String, pid: pid_t) {
        entries.removeAll { $0.identity == identity }
        entries.append(Entry(identity: identity, pid: pid, prior: prior))
    }
}
#endif
