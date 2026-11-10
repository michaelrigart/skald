import Foundation
@testable import SkaldCore

actor StubTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(status: Int, body: Data)
        case failure(any Error)
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    init(status: Int = 200, json: String) {
        self.init([.response(status: status, body: Data(json.utf8))])
    }

    init(failure: any Error) {
        self.init([.failure(failure)])
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case let .failure(error):
            throw error
        case let .response(status, body):
            let url = request.url ?? URL(string: "https://stub.invalid")!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (body, response)
        }
    }
}
