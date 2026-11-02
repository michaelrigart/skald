import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

extension HTTPTransport {
    func body(
        of request: URLRequest,
        mapping failure: (any Error) -> EngineFailure
    ) async throws(EngineFailure) -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw failure(error)
        }
        guard (200..<300).contains(response.statusCode) else { throw .failed }
        return data
    }
}

extension URLRequest {
    static func post(_ url: URL, json: some Encodable, headers: [String: String]) throws(EngineFailure) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            request.httpBody = try JSONEncoder().encode(json)
        } catch {
            throw .failed
        }
        return request
    }
}

extension Error {
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
