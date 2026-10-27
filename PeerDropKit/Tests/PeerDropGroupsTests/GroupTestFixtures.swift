import Foundation
import CryptoKit
import PeerDropAccount
import PeerDropSecurity
import PeerDropGroups

enum GroupTestFixtures {
    static let groupId = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let memberId = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    static let eventId = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    static let accountId = "PDRP0001"

    static func json(_ string: String, status: Int = 200) -> GroupTestURLProtocol.Stub {
        GroupTestURLProtocol.Stub(status: status, body: Data(string.utf8))
    }

    static func makeClient() -> GroupClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroupTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let account = AccountClient(
            baseURL: URL(string: "https://worker.test")!,
            session: session,
            authProvider: { request in request.setValue("Bearer test", forHTTPHeaderField: "Authorization") },
            tokenInvalidator: {}
        )
        return GroupClient(account: account)
    }

    static func makeEncryptor() -> ChatDataEncryptor {
        ChatDataEncryptor(testKey: SymmetricKey(size: .bits256))
    }

    static func makeIdGenerator(_ values: [String]) -> () -> String {
        var index = 0
        return {
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }
}

final class GroupTestURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data
        let error: Error?

        init(status: Int, body: Data, error: Error? = nil) {
            self.status = status
            self.body = body
            self.error = error
        }
    }

    static var requests: [URLRequest] = []
    static var handler: ((URLRequest) -> Stub)?

    static func reset() {
        requests = []
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let request = Self.materialized(request)
        Self.requests.append(request)
        let stub = Self.handler?(request) ?? Stub(status: 500, body: Data())
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func materialized(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var copy = request
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        copy.httpBody = data
        return copy
    }
}

struct StubGroupDirectory: GroupDirectory {
    let signingKeys: [String: Data]

    func signingKey(accountId: String) async -> Data? {
        signingKeys[accountId]
    }
}
