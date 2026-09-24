import Foundation

final class TestURLProtocol: URLProtocol {
    struct Stub { let status: Int; let body: Data }
    static var queue: [Stub] = []
    static var requests: [URLRequest] = []
    static func reset() { queue = []; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(Self.materialized(request))
        let stub = Self.queue.isEmpty ? Stub(status: 500, body: Data()) : Self.queue.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands request bodies to a registered URLProtocol as
    /// `httpBodyStream`, not `httpBody` — even for a plain `session.data(for:)`
    /// call where the caller set `request.httpBody` directly. Read the stream
    /// back into `httpBody` on the recorded copy so tests can assert on the
    /// sent JSON the ordinary way (`request.httpBody`).
    private static func materialized(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var copy = request
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        copy.httpBody = data
        return copy
    }
}
