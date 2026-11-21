#if DEBUG
import Foundation

/// Remembers elements a lookup found nothing for, per app, until the app's focus changes.
struct NegativeLookupCache<Element> {
    private struct Entry {
        let hash: Int
        let element: Element
    }

    private let limitPerPid: Int
    private var entries: [pid_t: [Entry]] = [:]

    init(limitPerPid: Int = 8) {
        self.limitPerPid = limitPerPid
    }

    func contains(_ element: Element, hash: Int, pid: pid_t, isSame: (Element, Element) -> Bool) -> Bool {
        entries[pid]?.contains { $0.hash == hash && isSame($0.element, element) } ?? false
    }

    mutating func remember(_ element: Element, hash: Int, pid: pid_t, isSame: (Element, Element) -> Bool = { _, _ in false }) {
        if contains(element, hash: hash, pid: pid, isSame: isSame) { return }
        var kept = entries[pid, default: []]
        kept.append(Entry(hash: hash, element: element))
        if kept.count > limitPerPid { kept.removeFirst(kept.count - limitPerPid) }
        entries[pid] = kept
    }

    mutating func clear(pid: pid_t) {
        entries[pid] = nil
    }
}

final class FocusedSearchCache: @unchecked Sendable { // reason: the cache is only touched under the lock
    static let shared = FocusedSearchCache()

    private let lock = NSLock()
    private var cache = NegativeLookupCache<AXElement>()

    func isKnownEmpty(_ webArea: AXElement, pid: pid_t) -> Bool {
        lock.withLock { cache.contains(webArea, hash: webArea.hash, pid: pid, isSame: { $0.isSame(as: $1) }) }
    }

    func rememberEmpty(_ webArea: AXElement, pid: pid_t) {
        lock.withLock { cache.remember(webArea, hash: webArea.hash, pid: pid, isSame: { $0.isSame(as: $1) }) }
    }

    func clear(pid: pid_t) {
        lock.withLock { cache.clear(pid: pid) }
    }
}
#endif
