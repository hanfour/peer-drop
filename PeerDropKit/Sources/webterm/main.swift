import Foundation
import Hummingbird
import HummingbirdWebSocket

let router = Router()
router.get("/") { _, _ in "webterm spike ok" }

let wsRouter = Router(context: BasicWebSocketRequestContext.self)
wsRouter.ws("/ws") { _, _ in .upgrade([:]) } onUpgrade: { inbound, outbound, _ in
    for try await frame in inbound.messages(maxSize: 1 << 20) {
        if case .binary(let buffer) = frame {
            try await outbound.write(.binary(buffer))   // echo
        } else if case .text(let text) = frame {
            try await outbound.write(.text(text))
        }
    }
}

var app = Application(
    router: router,
    server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
    configuration: .init(address: .hostname("127.0.0.1", port: 7681))
)
try await app.runService()
