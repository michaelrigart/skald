import AppKit
import SkaldCore
import SwiftUI

/// The panel's window. It may become key, since the user opened it with the hotkey; the close button and
/// Escape go through the controller.
final class PanelWindow: NSObject, PanelPresenting, NSWindowDelegate {
    private let panel: NSPanel
    var onClose: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: PanelView.width, height: 240),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        super.init()
        panel.title = "Skald"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
    }

    func attach(_ controller: PanelController) {
        panel.contentView = NSHostingView(rootView: PanelView(controller: controller))
    }

    func show() {
        if !panel.isVisible { place() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }

    /// Upper middle of the screen with the pointer.
    private func place() {
        let pointer = NSEvent.mouseLocation
        guard let screen = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setFrameOrigin(CGPoint(x: screen.midX - size.width / 2, y: screen.maxY - screen.height / 4 - size.height))
    }
}

struct PanelView: View {
    static let width: CGFloat = 540
    private static let actions: [(EngineAction, String)] = [
        (.fix, "Fix"), (.clearer, "Clearer"), (.shorter, "Shorter"), (.moreFormal, "More formal"), (.friendlier, "Friendlier"),
    ]

    private static let languages: [(Language, String)] = [(.en, "English"), (.nl, "Dutch"), (.fr, "French")]

    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Self.actions, id: \.0) { action, title in
                    Button(title) { controller.run(action) }
                        .disabled(!controller.canRun)
                }
                Spacer(minLength: 8)
                Picker("Engine", selection: $controller.engine) {
                    ForEach(controller.engines, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if controller.fromClipboard {
                note(PanelController.clipboardLabel)
            }
            ScrollView {
                Text(content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 60, maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            status
            HStack(spacing: 6) {
                Spacer()
                Button("Close") { controller.close() }
                    .keyboardShortcut(.cancelAction)
                if controller.offersCopy {
                    Button(controller.copied ? "Copied" : "Copy") { controller.copy() }
                }
                if controller.offersReplace {
                    Button("Replace") { Task { await controller.replace() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .padding(.top, 8)
        .frame(width: Self.width)
    }

    private var content: AttributedString {
        if case .finished(.revised(_, let edits, _)) = controller.phase {
            return DiffText.attributed(original: controller.original, edits: edits)
        }
        if case .blocked(let notice) = controller.phase {
            return AttributedString(notice)
        }
        return AttributedString(controller.original)
    }

    @ViewBuilder private var status: some View {
        switch controller.phase {
        case .blocked, .ready:
            EmptyView()
        case .choosingLanguage:
            VStack(alignment: .leading, spacing: 6) {
                note("Skald can't tell which language this is. Pick one:")
                HStack(spacing: 6) {
                    ForEach(Self.languages, id: \.0) { language, name in
                        Button(name) { Task { await controller.choose(language) } }
                    }
                }
            }
        case let .running(action, engine):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(Self.title(action)) on \(engine.displayName)…").foregroundStyle(.secondary)
            }
        case .finished(.revised(let text, let edits, let engine)):
            note(controller.reason ?? (edits.isEmpty || text == controller.original
                ? "\(engine.displayName) found nothing to change."
                : "From \(engine.displayName)."))
        case let .finished(.unavailable(engine, reason, alternatives)):
            VStack(alignment: .leading, spacing: 6) {
                note("\(engine.displayName) can't run this: \(reason.explanation).")
                if !alternatives.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(alternatives, id: \.self) { alternative in
                            Button("Use \(alternative.displayName)") { controller.use(alternative) }
                        }
                    }
                }
            }
        case .finished(.failed(let failure)):
            note(Self.explanation(failure))
        case .finished(.needsLanguage):
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func title(_ action: EngineAction) -> String {
        actions.first { $0.0 == action }?.1 ?? "Working"
    }

    private static func explanation(_ failure: EngineFailure) -> String {
        switch failure {
        case .unavailable(let reason): "Unavailable: \(reason.explanation)."
        case .refused: "The engine declined this text."
        case .timedOut: "The engine took too long. Try again."
        case .cancelled: "Stopped."
        case .truncated: "The answer was cut off. Try a shorter selection."
        case .failed: "That didn't work. Try again."
        }
    }
}
