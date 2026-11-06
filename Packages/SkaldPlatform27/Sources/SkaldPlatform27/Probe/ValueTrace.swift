/// Does a ranges field report the typing at all? Numbers from the first keystroke-triggered evaluations of a session
/// whose value has not shown the marker.
struct ValueTrace {
    static let evaluations = 5

    struct Sample: Equatable {
        var valueLength: Int?
        var characterCount: Int?
        var selectionLocation: Int?
    }

    private var samples: [Sample] = []
    private var finished = false

    /// `sample` is nil for an evaluation that does not count; true once, when the fifth counted sample arrives.
    mutating func observe(_ sample: Sample?, containsMarker: Bool) -> Bool {
        guard !finished else { return false }
        if containsMarker {
            finished = true
            return false
        }
        guard let sample else { return false }
        samples.append(sample)
        guard samples.count == Self.evaluations else { return false }
        finished = true
        return true
    }

    func summary(keystrokes: Int) -> String {
        func list(_ value: (Sample) -> Int?) -> String {
            samples.map { value($0).map(String.init) ?? "-" }.joined(separator: ",")
        }
        return "keystrokes \(keystrokes), value lengths \(list(\.valueLength)), characters \(list(\.characterCount)), "
            + "selection locations \(list(\.selectionLocation))"
    }
}
