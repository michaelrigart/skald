import AppKit
import SkaldCore
import Testing
@testable import Skald

private let mail = "com.example.mail"
private let terminal = "com.apple.Terminal"

@MainActor private final class Recorder {
    var calls: [String] = []

    var actions: StatusItemController.Actions {
        .init(
            pauseForAnHour: { [self] in calls.append("pause") },
            resume: { [self] in calls.append("resume") },
            setApp: { [self] in calls.append("\($0) \($1.rawValue)") },
            grantAccess: { [self] in calls.append("grant") },
            openSettings: { [self] in calls.append("settings") }
        )
    }
}

@MainActor private func menu(
    for app: StatusItemController.FrontApp?, state: StatusState = .onThisMac, _ recorder: Recorder
) -> (NSMenu, StatusItemController) {
    let controller = StatusItemController(actions: recorder.actions, frontApp: { app })
    controller.show(state, sendingToClaude: false)
    let menu = NSMenu()
    controller.menuNeedsUpdate(menu)
    return (menu, controller)
}

@MainActor private func front(_ bundleID: String, _ mode: AppMode, claudeTyping: Bool = false) -> StatusItemController.FrontApp {
    .init(bundleID: bundleID, name: "App", mode: mode, claudeTyping: claudeTyping)
}

@MainActor private func choose(_ title: String, in menu: NSMenu) throws {
    let item = try #require(menu.items.first { $0.title == title })
    _ = try #require(item.target).perform(try #require(item.action), with: item)
}

@MainActor struct StatusMenuTests {
    @Test func turnOnPutsAnAppThatShipsOffOrAnyAppWhileClaudeIsOnBackOnThisMacOnly() throws {
        let cases: [(StatusItemController.FrontApp, String)] = [
            (front(terminal, .off), "\(terminal) thisMacOnly"),
            (front(mail, .off, claudeTyping: true), "\(mail) thisMacOnly"),
            (front(mail, .off), "\(mail) on"),
        ]
        for (app, expected) in cases {
            let recorder = Recorder()
            let (menu, controller) = menu(for: app, recorder)
            try choose("Turn On for App", in: menu)
            #expect(recorder.calls == [expected])
            _ = controller
        }
    }

    @Test func turnOffSetsOff() throws {
        let recorder = Recorder()
        let (menu, controller) = menu(for: front(mail, .thisMacOnly), recorder)
        try choose("Turn Off for App", in: menu)
        #expect(recorder.calls == ["\(mail) off"])
        _ = controller
    }

    @Test func keepIsTickedWhenThisMacOnlyAndTickingAndUntickingSwitchTheMode() throws {
        let recorder = Recorder()
        let (on, onController) = menu(for: front(mail, .on), recorder)
        let unticked = try #require(on.items.first { $0.title == "Keep App on This Mac" })
        #expect(unticked.state == .off)
        try choose("Keep App on This Mac", in: on)

        let (kept, keptController) = menu(for: front(mail, .thisMacOnly), recorder)
        let ticked = try #require(kept.items.first { $0.title == "Keep App on This Mac" })
        #expect(ticked.state == .on)
        try choose("Keep App on This Mac", in: kept)
        #expect(recorder.calls == ["\(mail) thisMacOnly", "\(mail) on"])
        _ = (onController, keptController)
    }

    @Test func keepIsHiddenWhenTheAppIsOffOrThereIsNone() {
        let recorder = Recorder()
        let (off, offController) = menu(for: front(mail, .off), recorder)
        #expect(!off.items.contains { $0.title.hasPrefix("Keep ") })
        let (none, noneController) = menu(for: nil, recorder)
        #expect(!none.items.contains { $0.title.hasPrefix("Keep ") || $0.title.hasPrefix("Turn ") })
        _ = (offController, noneController)
    }

    @Test func theMenuReadsTheStateThenAFailureLineThenTheAppItems() {
        let recorder = Recorder()
        let (menu, controller) = menu(
            for: front(mail, .on), state: .usingClaude([.nl, .fr], lastFailure: .unreachable), recorder
        )
        #expect(menu.items.prefix(3).map(\.title) == [
            "Dutch and French checks use Claude", "Last check failed: Claude unreachable", "",
        ])
        #expect(menu.items.prefix(2).allSatisfy { !$0.isEnabled })
        #expect(menu.items.map(\.title).filter { !$0.isEmpty } == [
            "Dutch and French checks use Claude", "Last check failed: Claude unreachable",
            "Keep App on This Mac", "Pause for an Hour", "Turn Off for App", "Settings…", "Quit Skald",
        ])
        _ = controller
    }
}
