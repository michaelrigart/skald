import Testing
@testable import SkaldCore

struct LoginItemRuleTests {
    /// macOS reports a main app it has never seen as not found, not as not registered.
    @Test(arguments: [LoginItemStatus.notRegistered, .notFound])
    func launchingWithTheSwitchOnRegistersAnItemThatIsNotRegistered(status: LoginItemStatus) {
        #expect(LoginItemRule.action(enabled: true, status: status, changed: false) == .register)
    }

    /// A choice made in System Settings shows as requires-approval and stands until the switch changes.
    @Test(arguments: [LoginItemStatus.enabled, .requiresApproval])
    func launchingWithTheSwitchOnLeavesARegisteredItemAlone(status: LoginItemStatus) {
        #expect(LoginItemRule.action(enabled: true, status: status, changed: false) == .none)
    }

    @Test(arguments: [LoginItemStatus.notRegistered, .notFound, .requiresApproval])
    func turningTheSwitchOnRegistersAnItemThatIsNotEnabled(status: LoginItemStatus) {
        #expect(LoginItemRule.action(enabled: true, status: status, changed: true) == .register)
        #expect(LoginItemRule.action(enabled: true, status: .enabled, changed: true) == .none)
    }

    @Test func turningTheSwitchOffUnregistersAnItemThatIsEnabledOrWaitingForApproval() {
        #expect(LoginItemRule.action(enabled: false, status: .enabled, changed: true) == .unregister)
        #expect(LoginItemRule.action(enabled: false, status: .requiresApproval, changed: true) == .unregister)
        #expect(LoginItemRule.action(enabled: false, status: .notRegistered, changed: true) == .none)
        #expect(LoginItemRule.action(enabled: false, status: .notFound, changed: true) == .none)
    }

    @Test func launchingWithTheSwitchOffChangesNothing() {
        for status in [LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound] {
            #expect(LoginItemRule.action(enabled: false, status: status, changed: false) == .none)
        }
    }
}
