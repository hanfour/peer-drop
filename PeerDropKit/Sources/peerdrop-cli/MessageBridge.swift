import Foundation

/// The contract `AgentSession` and `Entry` use to talk to whatever is behind a
/// PeerDrop conversation: a PTY-wrapped process (`ProcessBridge`) or a headless
/// agent runner (`AgentBridge`). Inbound chat text goes in via `send`; the
/// backing process's output comes back via `onMessage`.
protocol MessageBridge: AnyObject {
    /// Emitted output text (a chat message). Called on an arbitrary queue.
    var onMessage: ((String) -> Void)? { get set }
    /// Backing process ended, with a status. Called on an arbitrary queue.
    var onExit: ((Int32) -> Void)? { get set }

    func start()
    /// Deliver one inbound chat line to the backing process.
    func send(_ line: String)
    func terminate()
}
