import Foundation

struct MessageReceiptPayload: Codable {
    enum ReceiptType: String, Codable {
        case delivered
        case read
    }

    let messageIDs: [String]
    let receiptType: ReceiptType
    let timestamp: Date
}
