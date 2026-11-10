#if DEBUG
import ApplicationServices
import Foundation

final class ProbeContext: Sendable {
    weak let probe: Probe?
    let pid: pid_t

    init(probe: Probe, pid: pid_t) {
        self.probe = probe
        self.pid = pid
    }
}

private func deliver(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let context = Unmanaged<ProbeContext>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        context.probe?.received(notification: name, pid: context.pid)
    }
}

final class ProbeObserver: @unchecked Sendable { // reason: state is touched only inside AXQueue closures
    private let pid: pid_t
    private var observer: AXObserver?
    private var field: AXElement?
    private var window: AXElement?

    init(pid: pid_t) {
        self.pid = pid
    }

    func retarget(contextBits: Int) {
        guard let refcon = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
        if observer == nil { attach(refcon: refcon) }
        guard let observer else { return }

        if let field {
            AXObserverRemoveNotification(observer, field.element, "AXValueChanged" as CFString)
            AXObserverRemoveNotification(observer, field.element, "AXSelectedTextChanged" as CFString)
        }
        if let window { AXObserverRemoveNotification(observer, window.element, "AXWindowMoved" as CFString) }
        field = nil
        window = nil

        guard let focused = FieldProbe.focusedField(pid), !FieldProbe.isSecure(focused) else { return }
        AXObserverAddNotification(observer, focused.element, "AXValueChanged" as CFString, refcon)
        AXObserverAddNotification(observer, focused.element, "AXSelectedTextChanged" as CFString, refcon)
        field = focused
        if let focusedWindow = focused.window {
            AXObserverAddNotification(observer, focusedWindow.element, "AXWindowMoved" as CFString, refcon)
            window = focusedWindow
        }
    }

    func detach() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
        field = nil
        window = nil
    }

    private func attach(refcon: UnsafeMutableRawPointer) {
        var created: AXObserver?
        guard AXObserverCreate(pid, deliver, &created) == .success, let created else { return }
        let application = AXElement.application(pid: pid)
        AXObserverAddNotification(created, application.element, "AXFocusedUIElementChanged" as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }
}
#endif
