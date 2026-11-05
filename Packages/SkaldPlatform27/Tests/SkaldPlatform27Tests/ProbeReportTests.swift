import Testing
@testable import SkaldPlatform27

private func fullLine() -> ProbeLine {
    ProbeLine(
        app: "com.example.editor", role: "AXTextArea", subrole: "",
        canRead: true, rangedRead: true, canReadSelection: true, canBound: true, boundsStable: true,
        canWrite: true, undoExact: true, undoEarlierHistory: true, formattingKept: true, writeMethod: .paste,
        notifications: ["AXSelectedTextChanged", "AXValueChanged"],
        cpuIdle: 0.4, cpuTyping: 12.34, cpuIdleForced: nil, cpuTypingForced: 20
    )
}

@Test func renderIsOneTabSeparatedLine() {
    #expect(fullLine().render() == [
        "com.example.editor", "AXTextArea", "-",
        "true", "true", "true", "true", "true", "true", "true", "true", "true", "paste",
        "AXSelectedTextChanged,AXValueChanged",
        "0.4", "12.3", "-", "20.0",
    ].joined(separator: "\t"))
}

@Test func renderLeavesUnknownFormattingAndEmptyNotificationsAsDashes() {
    var line = fullLine()
    line.formattingKept = nil
    line.notifications = []
    let columns = line.render().split(separator: "\t", omittingEmptySubsequences: false)
    #expect(columns[11] == "-")
    #expect(columns[13] == "-")
}

@Test func renderNamesTheWriteMethodOrADashWhenNoWriteWasAttempted() {
    var line = fullLine()
    line.writeMethod = .ax
    #expect(line.render().split(separator: "\t")[12] == "ax")
    line.writeMethod = nil
    #expect(line.render().split(separator: "\t")[12] == "-")
}

@Test func secureFieldRendersEveryCapabilityFalse() {
    var byRole = fullLine()
    byRole.role = "AXSecureTextField"
    var bySubrole = fullLine()
    bySubrole.subrole = "AXSecureTextField"
    for line in [byRole, bySubrole] {
        let columns = line.render().split(separator: "\t", omittingEmptySubsequences: false)
        #expect(columns[3...10].allSatisfy { $0 == "false" })
        #expect(columns[11] == "-")
        #expect(columns[12] == "-")
        #expect(columns[13] == "-")
        #expect(!line.cleanWrite)
    }
}

@Test func cleanWriteNeedsWriteExactUndoAndHistory() {
    #expect(fullLine().cleanWrite)

    var lostHistory = fullLine()
    lostHistory.undoEarlierHistory = false
    #expect(!lostHistory.cleanWrite)

    var lostFormatting = fullLine()
    lostFormatting.formattingKept = false
    #expect(!lostFormatting.cleanWrite)

    var unknownFormatting = fullLine()
    unknownFormatting.formattingKept = nil
    #expect(unknownFormatting.cleanWrite)
}
