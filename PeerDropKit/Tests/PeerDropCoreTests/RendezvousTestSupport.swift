import XCTest
import CryptoKit
import PeerDropSecurity
import PeerDropTransport
import PeerDropProtocol
@testable import PeerDropCore

// Shared fakes for the Project E rendezvous tests (no network, no WebRTC, no keychain).

@MainActor
func rvWaitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                 _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("condition not met within \(timeout)s", file: file, line: line); return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

// MARK: - WebSocket

@MainActor
final class FakeRVSocket: RendezvousWebSocket {
    let url: URL
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private(set) var sent: [String] = []
    private(set) var closedByClient = false
    /// Optional hub hook (see `FakeRVRoomHub`).
    var onSend: ((String) -> Void)?
    var onClientClose: (() -> Void)?

    init(url: URL) { self.url = url }

    func send(text: String) {
        sent.append(text)
        onSend?(text)
    }
    func close() {
        closedByClient = true
        onClientClose?()
    }
    func deliver(_ text: String) { onText?(text) }
    func remoteClose() { onClose?() }
}

@MainActor
final class FakeRVSocketFactory: RendezvousWebSocketFactory {
    private(set) var sockets: [FakeRVSocket] = []
    var onMake: ((FakeRVSocket) -> Void)?
    func makeSocket(url: URL) -> RendezvousWebSocket {
        let s = FakeRVSocket(url: url)
        sockets.append(s)
        onMake?(s)
        return s
    }
}

// MARK: - HTTP / PoW

final class FakeRVHTTP: RendezvousHTTPPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(URL, Data)] = []
    var result: Result<(Data, Int), Error>
    init(result: Result<(Data, Int), Error> = .success((Data(#"{"iceServers":[]}"#.utf8), 200))) { self.result = result }
    var requests: [(URL, Data)] { lock.lock(); defer { lock.unlock() }; return _requests }
    func post(url: URL, body: Data) async throws -> (Data, Int) {
        lock.lock(); _requests.append((url, body)); let r = result; lock.unlock()
        return try r.get()
    }
}

/// POST that hangs until cancelled; records whether it saw cancellation.
final class GatedRVHTTP: RendezvousHTTPPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?
    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func post(url: URL, body: Data) async throws -> (Data, Int) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                _started = true
                if _cancelled { lock.unlock(); c.resume() } else { waiter = c; lock.unlock() }
            }
        } onCancel: {
            lock.lock(); _cancelled = true; let w = waiter; waiter = nil; lock.unlock()
            w?.resume()
        }
        throw CancellationError()
    }
}

struct FailingRVSolver: RendezvousPoWSolving {
    struct Boom: Error {}
    func solve(token: Data, hour: Int) async throws -> String { throw Boom() }
}

final class CountingRVSolver: RendezvousPoWSolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func solve(token: Data, hour: Int) async throws -> String {
        lock.lock(); _calls += 1; lock.unlock()
        return try await DetachedRendezvousPoWSolver().solve(token: token, hour: hour)
    }
}

/// The first solve (the first frame) runs at once; later solves wait for `release()`.
final class GatedRVSolver: RendezvousPoWSolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func release() {
        lock.lock(); released = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }
    func solve(token: Data, hour: Int) async throws -> String {
        lock.lock(); _calls += 1; let n = _calls; lock.unlock()
        if n > 1 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
            }
        }
        return try await DetachedRendezvousPoWSolver().solve(token: token, hour: hour)
    }
}

// MARK: - Scripted peer (holds the other half of the DH)

final class RVPeer {
    let identity: RendezvousTestIdentity
    var provider: IdentityRendezvousSecretProvider { IdentityRendezvousSecretProvider(identity: identity) }
    var key: Data { identity.raw }
    private(set) var handshake: RendezvousSignalingHandshake?
    private(set) var cipher: RendezvousSignalingCipher?

    init(identity: RendezvousTestIdentity = RendezvousTestIdentity()) { self.identity = identity }

    /// Starts a handshake towards `localKey` and returns our hello frame.
    func hello(towards localKey: Data, day: Int) throws -> String {
        let h = try RendezvousSignalingHandshake(provider: provider, peerKey: localKey, day: day)
        handshake = h
        cipher = nil
        return h.helloFrame
    }

    func accept(_ helloFrame: String) throws {
        cipher = try handshake!.accept(peerHelloFrame: helloFrame)
    }

    func sealFrame(_ plaintext: Data) throws -> String {
        let wire = try cipher!.seal(plaintext)
        return #"{"t":"sig","c":""# + RendezvousToken.encodeBase64URL(wire) + #""}"#
    }

    func open(_ frame: String) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
              obj["t"] as? String == "sig", let c = obj["c"] as? String,
              let wire = RendezvousSignalingClient.decodeBase64URLAnyLength(c) else { return nil }
        return try? cipher?.open(wire)
    }
}

// MARK: - Transport / negotiator fakes for the manager

final class FakeRVTransport: TransportProtocol {
    var onStateChange: ((TransportState) -> Void)?
    private(set) var closed = false
    let label: String
    init(label: String) { self.label = label }
    func send(_ message: PeerMessage) async throws {}
    func receive() async throws -> PeerMessage { throw CancellationError() }
    func close() { closed = true }
    var isReady: Bool { !closed }
}
