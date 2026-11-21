import AppKit
import SkaldCore
import Testing
@testable import Skald

@MainActor struct ClaudeStatusRelayTests {
    @Test func theHookReturnsOnlyOnceTheMenuBarShowsTheCloud() async throws {
        let controller = StatusItemController(
            actions: .init(pause: { _ in }, resume: {}, setApp: { _, _ in }, grantAccess: {}, openSettings: {}),
            frontApp: { nil }
        )
        let plain = try #require(NSImage(named: StatusState.glyphName)?.tiffRepresentation)
        let cloud = try #require(NSImage(named: StatusState.cloudGlyphName)?.tiffRepresentation)
        #expect(controller.item.button?.image?.tiffRepresentation == plain)

        let relay = ClaudeStatusRelay()
        relay.show = { status in
            controller.show(.usingClaude([.nl], lastFailure: status.trouble), sendingToClaude: status.sending)
        }
        let hook = relay.hook
        await Task.detached { await hook(ClaudeStatus(sending: true, trouble: nil)) }.value
        #expect(controller.item.button?.image?.tiffRepresentation == cloud)
    }
}
