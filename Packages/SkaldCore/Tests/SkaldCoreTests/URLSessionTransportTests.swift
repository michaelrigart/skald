import Foundation
import Testing
@testable import SkaldCore

struct URLSessionTransportTests {
    @Test("the session times out a request after 30 s, the remote engines' bound")
    func requestTimeout() {
        #expect(URLSessionTransport().configuration.timeoutIntervalForRequest == 30)
    }
}
