import SkaldCore

/// The newest fields by identity: each keeps its element and the read source it was registered with, and is handed
/// out only while its element is still readable, asked at each lookup: an element registered as a text area can turn
/// secure or lose its role later.
struct FieldRegistry<Element, Source> {
    struct Entry {
        let id: FieldID
        let element: Element
        let source: Source
    }

    static var limit: Int { 20 }

    private let isSame: (Element, Element) -> Bool
    private let isReadable: (Element) -> Bool
    /// Oldest first.
    private var entries: [Entry] = []
    private var issued = 0

    init(isSame: @escaping (Element, Element) -> Bool, isReadable: @escaping (Element) -> Bool) {
        self.isSame = isSame
        self.isReadable = isReadable
    }

    /// The focused element's field: the one already registered for it, else a new one when it is a candidate
    /// with a source. `source` is never asked for a non-candidate, so nothing reads it.
    mutating func focus(_ element: Element, app: String, isCandidate: Bool, source: () -> Source?) -> FieldID? {
        guard isCandidate else { return nil }
        if let index = entries.firstIndex(where: { $0.id.app == app && isSame($0.element, element) }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.id
        }
        guard let source = source() else { return nil }
        issued += 1
        let entry = Entry(id: FieldID(app: app, token: String(issued)), element: element, source: source)
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        return entry.id
    }

    func entry(_ id: FieldID) -> Entry? {
        entries.last { $0.id == id }.flatMap(readable)
    }

    func newest(app: String) -> Entry? {
        entries.last { $0.id.app == app }.flatMap(readable)
    }

    private func readable(_ entry: Entry) -> Entry? {
        isReadable(entry.element) ? entry : nil
    }
}
