import Foundation
import SkaldCore

public actor StubTransport: HTTPTransport {
    public enum Reply: Sendable {
        case response(status: Int, body: Data)
        case failure(any Error)
    }

    private var replies: [Reply]
    public private(set) var requests: [URLRequest] = []

    public init(_ replies: [Reply]) {
        self.replies = replies
    }

    public init(status: Int = 200, json: String) {
        self.init([.response(status: status, body: Data(json.utf8))])
    }

    public init(failure: any Error) {
        self.init([.failure(failure)])
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
