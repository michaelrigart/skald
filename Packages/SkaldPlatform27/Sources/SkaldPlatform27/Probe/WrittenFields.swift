/// A write the probe made earlier in this run, carried into later sessions on the same field.
struct PriorWrite: Sendable {
    var start: WriteStart
    var undoPresses: Int
}

/// The fields the probe wrote in this run, by identity: each field is written once per run.
struct WrittenFields {
    private var fields: [String: PriorWrite] = [:]

    func prior(for identity: String) -> PriorWrite? {
        fields[identity]
    }

    mutating func record(_ prior: PriorWrite, for identity: String) {
        fields[identity] = prior
    }
}
