import Foundation

struct TextMessagePayload: Codable {
    let text: String
    let timestamp: Date

    init(text: String) {
        self.text = text
        self.timestamp = Date()
    }
}
