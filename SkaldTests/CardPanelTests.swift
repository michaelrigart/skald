import AppKit
import SkaldCore
import Testing
@testable import Skald

@MainActor struct CardPanelTests {
    private let anchor = CGRect(x: 600, y: 500, width: 40, height: 16)
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func models(_ count: Int) -> [IssueCardModel] {
        (0..<count).map { _ in
            IssueCardModel(
                issue: issue(in: "They is ready", revised: "They are ready"), writes: true, clipboard: ClipboardSpy(),
                actions: .init(accept: { _, _ in .replaced }, dismiss: { _ in }, addToDictionary: { _ in }, hide: { _ in })
            )
        }
    }

    private func settle() async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    @Test func everyOpenShowsTheCardsAtTheirSize() async {
        let panel = CardPanel()
        for round in 1...6 {
            panel.show(models(round % 2 == 0 ? 1 : 3), anchor: anchor, screen: screen)
            await settle()
            #expect(panel.frame.width == CardPanel.width, "round \(round): \(panel.frame)")
            #expect(panel.frame.height > 40, "round \(round): \(panel.frame)")
            panel.close()
        }
    }

    @Test func aListReopenedWithTheSameCardsKeepsItsSize() async {
        let panel = CardPanel()
        let cards = models(3)
        var heights: [CGFloat] = []
        for _ in 1...4 {
            panel.show(cards, anchor: anchor, screen: screen)
            await settle()
            heights.append(panel.frame.height)
            panel.close()
        }
        #expect(heights.allSatisfy { $0 > 40 }, "\(heights)")
    }

    @Test func aStatusLineOpensThePanelWithoutCardsAndSurvivesRetainingCards() async {
        let panel = CardPanel()
        panel.showStatus("Checking…", anchor: anchor, screen: screen)
        await settle()
        #expect(panel.isOpen && panel.cards.isEmpty && panel.frame.height > 20)
        panel.retain { _ in false }
        #expect(panel.isOpen)
        panel.clearStatus()
        #expect(!panel.isOpen)
    }

    @Test func cardsReplaceTheStatusLine() async {
        let panel = CardPanel()
        panel.showStatus("Checking…", anchor: anchor, screen: screen)
        panel.show(models(1), anchor: anchor, screen: screen)
        await settle()
        #expect(panel.cards.count == 1 && panel.frame.height > 40)
        panel.clearStatus()
        #expect(panel.isOpen)
        panel.close()
    }
}
