import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import SkaldCore
import struct SkaldCore.TextRange

/// The paste write's order as a pure machine: each input is what the last step found, and the answer is the
/// steps to take next. Before ⌘V any abort restores the clipboard; after it only the expected paragraph does.
struct PastePlan {
    enum Mismatch: String, Sendable, Equatable {
        case notFrontmost = "the app is no longer frontmost"
        case otherField = "the focused element changed"
        case paragraphChanged = "the paragraph changed"
        case selectionMoved = "the selection left the range"
        case turnedOff = "the app was turned off"

        /// What the write reports when it stops for this reason before ⌘V.
        var outcome: ReplaceOutcome {
            switch self {
            case .paragraphChanged: .refusedChanged
            case .turnedOff: .unsupported
            case .notFrontmost, .otherField, .selectionMoved: .failed
            }
        }
    }

    enum SelectionStart: Sendable, Equatable {
        /// The app was asked to select the range.
        case requested
        case rejected
        /// The reader can't address the range (text markers beyond their reach); nothing was asked.
        case unreachable
        /// Task 13's checks failed before anything was selected.
        case refused(Mismatch)
    }

    /// What the field shows after ⌘V.
    enum Read: Sendable, Equatable {
        /// The paragraph with the replacement applied.
        case expected
        case original
        case other
        case unreadable
    }

    /// The checks right before ⌘V and the post, made in one `AXQueue` job so nothing runs between them.
    enum RecheckPost: Sendable, Equatable {
        case mismatch(Mismatch)
        /// Every check passed; false when the key events could not be created.
        case posted(Bool)
    }

    enum Input: Sendable, Equatable {
        case clipboard(restorable: Bool)
        case quiet(QuietPeriod.Outcome)
        case selection(SelectionStart)
        case covered(Bool, waited: Duration)
        case staged(PasteboardSwap.Staging)
        /// Main actor, right before the recheck: the clipboard no longer holds the stage (the user copied).
        case clipboardChangedBeforePaste
        case rechecked(RecheckPost)
        case read(Read, elapsed: Duration)
        case cancelled
    }

    enum Step: Sendable, Equatable {
        /// Main actor: snapshot the clipboard.
        case snapshot
        case watchQuiet
        /// `AXQueue`: Task 13's checks, then ask the app to select the range.
        case select
        case checkSelection(after: Duration)
        /// Main actor: put the replacement on the clipboard.
        case stage
        /// Main actor: cancelled, or the clipboard no longer holds the stage? Then one `AXQueue` job: the app is
        /// frontmost, the focused element is the field, the range is selected, then ⌘V.
        case recheckAndPost
        case poll(after: Duration)
        case restoreClipboard
        case restoreCaret(WriteEnd)
        /// Leave the replacement on the clipboard until the field shows it.
        case awaitProof
        case finish(ReplaceOutcome)
    }

    static let selectionWait: Duration = .milliseconds(500)
    static let pollInterval: Duration = .milliseconds(25)
    static let confirmWait: Duration = .seconds(3)

    /// Why the write stopped before ⌘V, as a fixed kind.
    private(set) var abortReason: String?
    private let changesText: Bool
    private let hasText: Bool
    private var selected = false
    private var stageRequested = false
    private var recheckRequested = false
    private var postRequested = false
    private var finished = false

    /// `changesText` is false when the replacement equals the text at the range: the field would show the expected
    /// paragraph before the paste lands, so it could never prove the paste. `hasText` is false for an empty
    /// replacement, which the core never sends: a paste of nothing would stage an empty clipboard.
    init(changesText: Bool = true, hasText: Bool = true) {
        self.changesText = changesText
        self.hasText = hasText
    }

    mutating func start() -> [Step] {
        guard hasText else { return abort(.failed, "the replacement is empty") }
        return changesText ? [.snapshot] : abort(.failed, "the replacement equals the text at the range")
    }

    mutating func next(_ input: Input) -> [Step] {
        guard !finished else { return [] }
        switch input {
        case .clipboard(let restorable):
            return restorable ? [.watchQuiet] : abort(.clipboardBusy, "the clipboard holds concealed or promised content")
        case .quiet(.quiet):
            return [.select]
        case .quiet(.tooLong):
            return abort(.unsupported, "the field is longer than 20,000 units")
        case .quiet(.unreadable):
            return abort(.failed, "the field could not be read")
        case .quiet(.keptChanging):
            return abort(.failed, "the field kept changing")
        case .quiet(.turnedOff):
            return abort(Mismatch.turnedOff.outcome, Mismatch.turnedOff.rawValue)
        case .quiet(.cancelled), .cancelled:
            return abort(.failed, "cancelled")
        case .selection(.requested):
            selected = true
            return [.checkSelection(after: .zero)]
        case .selection(.rejected):
            selected = true
            return abort(.failed, "the selection was rejected")
        case .selection(.unreachable):
            return abort(.unsupported, "the range is beyond the text markers' reach")
        case .selection(.refused(let mismatch)):
            return abort(mismatch.outcome, mismatch.rawValue)
        case .covered(true, _):
            stageRequested = true
            return [.stage]
        case .covered(false, let waited):
            return waited < Self.selectionWait
                ? [.checkSelection(after: Self.pollInterval)] : abort(.failed, "the selection did not cover the range")
        case .staged(.staged):
            guard !recheckRequested else { return [] }
            recheckRequested = true
            return [.recheckAndPost]
        case .staged(.changedSinceSnapshot):
            return abort(.failed, "the clipboard changed since the snapshot")
        case .staged(.unrestorable):
            return abort(.clipboardBusy, "the clipboard holds concealed or promised content")
        case .clipboardChangedBeforePaste:
            return abort(.failed, "the clipboard changed before the paste", restoreClipboard: false)
        case .rechecked(let result):
            guard recheckRequested, !postRequested else { return [] }
            switch result {
            case .mismatch(let mismatch):
                return abort(mismatch.outcome, mismatch.rawValue)
            case .posted(false):
                return abort(.failed, "the key events could not be created")
            case .posted(true):
                postRequested = true
                return [.poll(after: .zero)]
            }
        case .read(.expected, _):
            guard postRequested else { return [] }
            finished = true
            return [.restoreClipboard, .restoreCaret(.confirmed), .finish(.replaced)]
        case .read(.other, _):
            return postRequested ? unconfirmed() : []
        case .read(_, let elapsed):
            guard postRequested else { return [] }
            return elapsed < Self.confirmWait ? [.poll(after: Self.pollInterval)] : unconfirmed()
        }
    }

    /// Nothing has pasted yet, so the clipboard goes back at once and a moved selection is put back. Once ⌘V
    /// is posted there is no abort: only the expected paragraph restores the clipboard.
    /// A clipboard that changed since the stage holds the user's new copy and is left alone.
    private mutating func abort(_ outcome: ReplaceOutcome, _ reason: String, restoreClipboard: Bool = true) -> [Step] {
        guard !postRequested else { return unconfirmed() }
        finished = true
        abortReason = reason
        var steps: [Step] = []
        if stageRequested, restoreClipboard { steps.append(.restoreClipboard) }
        if selected { steps.append(.restoreCaret(.abortedAfterSelecting)) }
        return steps + [.finish(outcome)]
    }

    private mutating func unconfirmed() -> [Step] {
        finished = true
        return [.awaitProof, .finish(.unconfirmed)]
    }
}

/// The Accessibility side of one paste write; each call hops to `AXQueue`.
protocol PasteTarget: Sendable {
    func state() async -> QuietPeriod.Read
    /// False when the replacement equals the text at the range.
    var changesText: Bool { get }
    /// Task 13's checks, then the user's selection and a request to select the range.
    func select() async -> (start: PastePlan.SelectionStart, user: TextRange?)
    func covers() async -> Bool
    /// The checks right before ⌘V and the post, in one `AXQueue` job with nothing queued between them.
    func recheckAndPost(keyCode: CGKeyCode) async -> PastePlan.RecheckPost
    func read() async -> PastePlan.Read
    func restoreCaret(_ end: WriteEnd, user: TextRange?) async
}

/// A paste write's Accessibility calls on its field, each run as one `AXQueue` job by `QueuedPasteTarget`.
protocol PasteJobs: Sendable {
    var changesText: Bool { get }
    func state() -> QuietPeriod.Read
    func select() -> (start: PastePlan.SelectionStart, user: TextRange?)
    func covers() -> Bool
    func recheckAndPost(keyCode: CGKeyCode) -> PastePlan.RecheckPost
    func read() -> PastePlan.Read
    func restoreCaret(_ end: WriteEnd, user: TextRange?)
}

/// Runs each of a paste write's jobs on `AXQueue` while the app's switch is on, asked again inside every job: an
/// app turned off mid-write is neither read nor written again. Before ⌘V the write aborts and the clipboard goes
/// back; after it the fix stays on the clipboard, since the paste may still land.
struct QueuedPasteTarget<Jobs: PasteJobs>: PasteTarget {
    let queue: AXQueue
    let jobs: Jobs
    let isOn: @Sendable () -> Bool

    var changesText: Bool { jobs.changesText }

    func state() async -> QuietPeriod.Read {
        await queue.run(while: isOn, otherwise: .turnedOff) { [jobs] in jobs.state() }
    }

    func select() async -> (start: PastePlan.SelectionStart, user: TextRange?) {
        await queue.run(while: isOn, otherwise: (.refused(.turnedOff), nil)) { [jobs] in jobs.select() }
    }

    func covers() async -> Bool {
        await queue.run(while: isOn, otherwise: false) { [jobs] in jobs.covers() }
    }

    /// One `AXQueue` job, so no queued callback or read runs between the last check and ⌘V.
    func recheckAndPost(keyCode: CGKeyCode) async -> PastePlan.RecheckPost {
        await queue.run(while: isOn, otherwise: .mismatch(.turnedOff)) { [jobs] in jobs.recheckAndPost(keyCode: keyCode) }
    }

    func read() async -> PastePlan.Read {
        await queue.run(while: isOn, otherwise: .unreadable) { [jobs] in jobs.read() }
    }

    func restoreCaret(_ end: WriteEnd, user: TextRange?) async {
        await queue.run(while: isOn, otherwise: ()) { [jobs] in jobs.restoreCaret(end, user: user) }
    }
}

/// An unconfirmed paste's clipboard: it goes back only when its field reads the expected paragraph, and only
/// while the clipboard still holds the replacement. No deadline, no restore at quit.
@MainActor
final class PendingRestore {
    let swap: PasteboardSwap
    let target: any PasteTarget

    init(swap: PasteboardSwap, target: any PasteTarget) {
        self.swap = swap
        self.target = target
    }
}

/// Writes by paste for `.paste` apps: one write at a time per app, pasteboard work on the main actor, the
/// quiet interval and every wait on the injected clock.
@MainActor
final class PasteWriter {
    private struct Report {
        var restarts: Int?
        var selectionWait: Duration?
        var confirmedAfter: Duration?
        var restoration: PasteboardSwap.Restoration?
        var kept = false
    }

    private let clock: PasteClock
    private let changes: ValueChanges
    private let pasteboardName: NSPasteboard.Name
    private var writing: Set<String> = []
    private var pending: [FieldID: PendingRestore] = [:]

    nonisolated init(clock: PasteClock, changes: ValueChanges, pasteboardName: NSPasteboard.Name = .general) {
        self.clock = clock
        self.changes = changes
        self.pasteboardName = pasteboardName
    }

    func write(_ replacement: String, in field: FieldID, target: some PasteTarget) async -> ReplaceOutcome {
        guard writing.insert(field.app).inserted else {
            PlatformLog.access.notice("paste write: \(field.app, privacy: .public): another paste write is running")
            return .failed
        }
        defer { writing.remove(field.app) }

        var plan = PastePlan(changesText: target.changesText, hasText: !replacement.isEmpty)
        var steps = plan.start()
        var report = Report()
        var swap: PasteboardSwap?
        var user: TextRange?
        var keyCode = CommandV.fallback
        var selectedAt = Duration.zero
        var postedAt = Duration.zero
        while !steps.isEmpty {
            let step = steps.removeFirst()
            var input: PastePlan.Input?
            switch step {
            case .snapshot:
                let snapshot = PasteboardSwap(NSPasteboard(name: pasteboardName))
                swap = snapshot
                input = .clipboard(restorable: snapshot.canRestoreFaithfully)
            case .watchQuiet:
                let outcome = await QuietWatch(field: field, changes: changes, clock: clock).run { await target.state() }
                if case .quiet(let restarts) = outcome { report.restarts = restarts }
                input = .quiet(outcome)
            case .select:
                let selection = await target.select()
                user = selection.user
                selectedAt = clock.now()
                input = .selection(selection.start)
            case .checkSelection(let delay):
                guard await pause(delay) else {
                    input = .cancelled
                    break
                }
                let covered = await target.covers()
                let waited = clock.now() - selectedAt
                if covered { report.selectionWait = waited }
                input = .covered(covered, waited: waited)
            case .stage:
                keyCode = CommandV.keyCode()
                input = swap.map { .staged($0.stage(replacement)) } ?? .cancelled
            case .recheckAndPost:
                if Task.isCancelled {
                    input = .cancelled
                } else if swap?.holdsStage != true {
                    input = .clipboardChangedBeforePaste
                } else {
                    postedAt = clock.now()
                    input = .rechecked(await target.recheckAndPost(keyCode: keyCode))
                }
            case .poll(let delay):
                guard await pause(delay) else {
                    input = .cancelled
                    break
                }
                let read = await target.read()
                let elapsed = clock.now() - postedAt
                if read == .expected { report.confirmedAfter = elapsed }
                input = .read(read, elapsed: elapsed)
            case .restoreClipboard:
                report.restoration = swap?.restore()
            case .restoreCaret(let end):
                await target.restoreCaret(end, user: user)
            case .awaitProof:
                if let swap {
                    pending[field] = PendingRestore(swap: swap, target: target)
                    report.kept = true
                }
            case .finish(let outcome):
                log(outcome, report: report, abort: plan.abortReason, app: field.app)
                return outcome
            }
            if let input { steps += plan.next(input) }
        }
        return .failed
    }

    /// A value change or a refocus of `field`: an unconfirmed paste there restores the clipboard once the field
    /// reads the expected paragraph. Returns what happened to the clipboard, nil while it waits.
    @discardableResult
    func fieldChanged(_ field: FieldID) async -> PasteboardSwap.Restoration? {
        guard let waiting = pending[field] else { return nil }
        guard waiting.swap.holdsStage else {
            pending[field] = nil
            PlatformLog.access.notice("pending restore: \(field.app, privacy: .public): the clipboard changed since the paste, left alone")
            return .leftAlone
        }
        let read = await waiting.target.read()
        guard pending[field] === waiting, read == .expected else { return nil }
        pending[field] = nil
        let restoration = waiting.swap.restore()
        PlatformLog.access.notice("pending restore: \(field.app, privacy: .public): the field shows the paste, \(Self.describe(restoration), privacy: .public)")
        return restoration
    }

    private func pause(_ delay: Duration) async -> Bool {
        guard delay > .zero else { return true }
        do {
            try await clock.sleep(delay)
            return true
        } catch {
            return false
        }
    }

    private func log(_ outcome: ReplaceOutcome, report: Report, abort: String?, app: String) {
        func ms(_ duration: Duration?) -> String {
            duration.map { "\(Int($0 / .milliseconds(1))) ms" } ?? "-"
        }
        let clipboard = report.kept ? "kept the fix" : report.restoration.map(Self.describe) ?? "untouched"
        PlatformLog.access.notice(
            "paste write: \(app, privacy: .public): \(String(describing: outcome), privacy: .public); quiet restarts \(report.restarts.map(String.init) ?? "-", privacy: .public), selection after \(ms(report.selectionWait), privacy: .public), value change after \(ms(report.confirmedAfter), privacy: .public), abort \(abort ?? "-", privacy: .public), clipboard \(clipboard, privacy: .public)"
        )
    }

    private static func describe(_ restoration: PasteboardSwap.Restoration) -> String {
        restoration == .restored ? "restored" : "left alone (changed since)"
    }
}

/// The single synthetic keystroke Skald posts: ⌘V, to the target app's pid only.
enum CommandV {
    static let fallback = CGKeyCode(kVK_ANSI_V)

    /// The key that types "v" with ⌘ held in the current keyboard layout, else the ANSI V key.
    @MainActor
    static func keyCode() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            (0 ..< 128).first { typesV(UInt16($0), layout: layout) }.map { CGKeyCode($0) } ?? fallback
        }
    }

    static func post(to pid: pid_t, keyCode: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private static func typesV(_ code: UInt16, layout: UnsafePointer<UCKeyboardLayout>) -> Bool {
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters
        )
        return status == noErr && length == 1 && characters[0] == UniChar(UInt8(ascii: "v"))
    }
}
