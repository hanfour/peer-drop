import XCTest
import Network
@testable import PeerDrop

/// Integration tests for chat messaging over loopback connection.
/// This simulates real multi-device chat communication on localhost.
final class ChatIntegrationTests: XCTestCase {

    private var listener: NWListener!
    private var listenerPort: UInt16!
    private var serverConnection: NWConnection?

    override func setUp() async throws {
        try await super.setUp()

        let params = NWParameters.peerDrop()
        listener = try NWListener(using: params, on: .any)

        listener.newConnectionHandler = { [weak self] conn in
            self?.serverConnection = conn
            conn.start(queue: .global(qos: .userInitiated))
        }

        let started = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { started.fulfill() }
        }
        listener.start(queue: .global(qos: .userInitiated))

        await fulfillment(of: [started], timeout: 10)
        listenerPort = listener.port?.rawValue
        XCTAssertNotNil(listenerPort, "Listener did not bind to a port")
    }

    override func tearDown() async throws {
        serverConnection?.cancel()
        serverConnection = nil
        listener?.cancel()
        listener = nil
        try await super.tearDown()
    }

    private func makeClient() -> NWConnection {
        let params = NWParameters.peerDrop()
        return NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: listenerPort)!,
            using: params
        )
    }

    // Helper to create a text message
    private func createTextMessage(_ text: String, senderID: String) throws -> PeerMessage {
        let payload = TextMessagePayload(text: text)
        return try PeerMessage.textMessage(payload, senderID: senderID)
    }

    // Helper to extract text from a received message
    private func extractText(from message: PeerMessage) -> String? {
        guard message.type == .textMessage,
              let payload = try? message.decodePayload(TextMessagePayload.self) else {
            return nil
        }
        return payload.text
    }

    // MARK: - Chat Message Tests

    /// Test sending a single text chat message
    func testSingleChatMessageRoundTrip() async throws {
        let received = expectation(description: "chat message received")

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        var receivedText: String?
        Task {
            let msg = try await server.receiveMessage()
            XCTAssertEqual(msg.type, .textMessage)
            receivedText = extractText(from: msg)
            received.fulfill()
        }

        // Send chat message
        let chatMessage = try createTextMessage("Hello from Device A!", senderID: "device-a")
        try await client.sendMessage(chatMessage)

        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(receivedText, "Hello from Device A!")
        client.cancel()
    }

    /// Test bidirectional chat conversation
    func testBidirectionalChatConversation() async throws {
        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        // Server (Device B) receives message and replies
        Task {
            let msg = try await server.receiveMessage()
            XCTAssertEqual(msg.type, .textMessage)
            XCTAssertEqual(extractText(from: msg), "Hi Device B!")

            // Reply back
            let reply = try createTextMessage("Hello Device A! Nice to meet you!", senderID: "device-b")
            try await server.sendMessage(reply)
        }

        // Client (Device A) sends initial message
        let greeting = try createTextMessage("Hi Device B!", senderID: "device-a")
        try await client.sendMessage(greeting)

        // Client receives reply
        let reply = try await client.receiveMessage()
        XCTAssertEqual(reply.type, .textMessage)
        XCTAssertEqual(extractText(from: reply), "Hello Device A! Nice to meet you!")
        XCTAssertEqual(reply.senderID, "device-b")

        client.cancel()
    }

    /// Test multiple chat messages in sequence
    func testMultipleChatMessages() async throws {
        let allReceived = expectation(description: "all messages received")
        var receivedMessages: [String] = []

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        Task {
            for _ in 0..<5 {
                let msg = try await server.receiveMessage()
                if let text = extractText(from: msg) {
                    receivedMessages.append(text)
                }
            }
            allReceived.fulfill()
        }

        // Send 5 chat messages
        for i in 1...5 {
            let msg = try createTextMessage("Message #\(i)", senderID: "sender")
            try await client.sendMessage(msg)
        }

        await fulfillment(of: [allReceived], timeout: 10)
        XCTAssertEqual(receivedMessages.count, 5)
        XCTAssertEqual(receivedMessages, ["Message #1", "Message #2", "Message #3", "Message #4", "Message #5"])
        client.cancel()
    }

    /// Test full chat conversation with back-and-forth messages
    func testFullChatConversation() async throws {
        let conversationComplete = expectation(description: "conversation complete")

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        var serverReceivedMessages: [String] = []
        var clientReceivedMessages: [String] = []

        // Server conversation loop
        Task {
            // Receive greeting
            let msg1 = try await server.receiveMessage()
            serverReceivedMessages.append(extractText(from: msg1) ?? "")

            // Reply
            try await server.sendMessage(try createTextMessage("Hi! How are you?", senderID: "device-b"))

            // Receive response
            let msg2 = try await server.receiveMessage()
            serverReceivedMessages.append(extractText(from: msg2) ?? "")

            // Final reply
            try await server.sendMessage(try createTextMessage("Great! Talk to you later!", senderID: "device-b"))
        }

        // Client conversation
        // 1. Send greeting
        try await client.sendMessage(try createTextMessage("Hello!", senderID: "device-a"))

        // 2. Receive reply
        let reply1 = try await client.receiveMessage()
        clientReceivedMessages.append(extractText(from: reply1) ?? "")

        // 3. Send response
        try await client.sendMessage(try createTextMessage("I'm doing great, thanks!", senderID: "device-a"))

        // 4. Receive final message
        let reply2 = try await client.receiveMessage()
        clientReceivedMessages.append(extractText(from: reply2) ?? "")

        // Verify conversation
        XCTAssertEqual(serverReceivedMessages, ["Hello!", "I'm doing great, thanks!"])
        XCTAssertEqual(clientReceivedMessages, ["Hi! How are you?", "Great! Talk to you later!"])

        conversationComplete.fulfill()
        await fulfillment(of: [conversationComplete], timeout: 10)
        client.cancel()
    }

    /// Test chat message with special characters and emojis
    func testChatMessageWithSpecialCharacters() async throws {
        let received = expectation(description: "special message received")

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        let specialMessage = "Hello! 你好！🎉🚀 Special chars: <>&\"'\\n\\t"
        var receivedText: String?

        Task {
            let msg = try await server.receiveMessage()
            receivedText = extractText(from: msg)
            received.fulfill()
        }

        try await client.sendMessage(try createTextMessage(specialMessage, senderID: "sender"))

        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(receivedText, specialMessage)
        client.cancel()
    }

    /// Test long chat message
    func testLongChatMessage() async throws {
        let received = expectation(description: "long message received")

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        // Create a 10KB message
        let longMessage = String(repeating: "This is a long message. ", count: 500)
        var receivedText: String?

        Task {
            let msg = try await server.receiveMessage()
            receivedText = extractText(from: msg)
            received.fulfill()
        }

        try await client.sendMessage(try createTextMessage(longMessage, senderID: "sender"))

        await fulfillment(of: [received], timeout: 10)
        XCTAssertEqual(receivedText, longMessage)
        XCTAssertEqual(receivedText?.count, longMessage.count)
        client.cancel()
    }

    /// Test rapid chat message exchange
    func testRapidChatExchange() async throws {
        let allDone = expectation(description: "rapid exchange complete")

        let client = makeClient()
        client.start(queue: .global(qos: .userInitiated))
        try await client.waitReady()

        try await Task.sleep(nanoseconds: 200_000_000)
        guard let server = serverConnection else {
            XCTFail("No server connection accepted")
            return
        }

        var serverReceived = 0
        var clientReceived = 0
        let messageCount = 10

        // Server receives and echoes
        Task {
            for _ in 0..<messageCount {
                let msg = try await server.receiveMessage()
                serverReceived += 1
                // Echo back
                let echoText = "Echo: \(extractText(from: msg) ?? "")"
                try await server.sendMessage(try createTextMessage(echoText, senderID: "server"))
            }
        }

        // Client sends and receives
        for i in 1...messageCount {
            try await client.sendMessage(try createTextMessage("Msg \(i)", senderID: "client"))
            let echo = try await client.receiveMessage()
            if extractText(from: echo)?.starts(with: "Echo:") == true {
                clientReceived += 1
            }
        }

        XCTAssertEqual(serverReceived, messageCount)
        XCTAssertEqual(clientReceived, messageCount)

        allDone.fulfill()
        await fulfillment(of: [allDone], timeout: 15)
        client.cancel()
    }
}
