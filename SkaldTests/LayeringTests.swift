import Foundation
import Testing

private let appSources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Skald")

/// The quality bar: Accessibility calls live only in the platform layer.
@Test func theAppTargetMakesNoAccessibilityCalls() throws {
    let walk = try #require(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
    var offending: [String] = []
    var scanned = 0
    for case let url as URL in walk where url.pathExtension == "swift" {
        scanned += 1
        let source = try String(contentsOf: url, encoding: .utf8)
        if source.contains("import ApplicationServices") || source.range(of: #"\bAX[A-Z]\w*\("#, options: .regularExpression) != nil {
            offending.append(url.lastPathComponent)
        }
    }
    #expect(scanned > 20)
    #expect(offending.isEmpty, "app files calling Accessibility: \(offending)")
}
