import Testing
@testable import Skald

/// A service no real Skald item uses, emptied before and after each test.
private let testStore = KeychainStore(service: "com.michaelrigart.skald.tests", account: "claude-api-key")

@Suite(.serialized) struct KeychainStoreTests {
    init() throws {
        try testStore.delete()
    }

    @Test func aWrittenKeyReadsBackAndADeletedOneIsGone() throws {
        defer { try? testStore.delete() }
        #expect(testStore.read() == nil)
        #expect(!testStore.containsValue())
        try testStore.write("sk-test-one")
        #expect(testStore.read() == "sk-test-one")
        #expect(testStore.containsValue())
        try testStore.delete()
        #expect(testStore.read() == nil)
        #expect(!testStore.containsValue())
    }

    @Test func writingAgainReplacesTheKey() throws {
        defer { try? testStore.delete() }
        try testStore.write("sk-test-one")
        try testStore.write("sk-test-two")
        #expect(testStore.read() == "sk-test-two")
    }

    @Test func deletingAMissingKeyIsNoError() throws {
        try testStore.delete()
        try testStore.delete()
        #expect(testStore.read() == nil)
    }

    @Test func theAppsStoreUsesTheServiceAndAccountFromTheConstraints() {
        #expect(KeychainStore.claudeKey.service == "com.michaelrigart.skald")
        #expect(KeychainStore.claudeKey.account == "claude-api-key")
    }
}
