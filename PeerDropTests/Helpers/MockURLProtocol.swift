import Foundation

/// Test-only URLProtocol that returns canned responses/errors.
/// Register with `URLProtocol.registerClass(MockURLProtocol.self)` in test setup;
/// unregister in teardown. Configure response via the static properties before
/// making requests.
final class MockURLProtocol: URLProtocol {

    /// Canned bytes to return as the response body. Defaults to empty.
    static var responseData: Data?
    /// Canned response status code. Defaults to 200.
    static var responseStatusCode: Int = 200
    /// If set, the request fails with this error instead of returning a response.
    static var responseError: Error?
    /// Whether the protocol intercepts all requests. Set to false to bypass.
    static var enabled = true

    /// Reset all canned values to defaults.
    static func reset() {
        responseData = nil
        responseStatusCode = 200
        responseError = nil
        enabled = true
    }

    override class func canInit(with request: URLRequest) -> Bool { enabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if let err = MockURLProtocol.responseError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: MockURLProtocol.responseStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let data = MockURLProtocol.responseData {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
