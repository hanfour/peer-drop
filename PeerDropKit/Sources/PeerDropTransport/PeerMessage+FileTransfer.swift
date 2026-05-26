import Foundation
import PeerDropProtocol

extension PeerMessage {
    /// File transfer offer: announces an incoming file/directory with
    /// metadata (name, size, hash). Recipient responds with `.fileAccept`
    /// or `.fileReject`.
    static func fileOffer(metadata: TransferMetadata, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(metadata)
        return PeerMessage(type: .fileOffer, payload: data, senderID: senderID)
    }

    /// Batch transfer start: announces a multi-file group with batch
    /// metadata (file count, total size). Individual `.fileOffer` messages
    /// follow.
    static func batchStart(metadata: BatchMetadata, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(metadata)
        return PeerMessage(type: .batchStart, payload: data, senderID: senderID)
    }
}
