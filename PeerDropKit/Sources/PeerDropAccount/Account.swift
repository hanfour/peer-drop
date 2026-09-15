import Foundation

public struct Account: Codable, Equatable, Sendable {
    public let accountId: AccountID
    public var nickname: String?
    public var mailboxId: String
    public let createdAt: Date

    public init(accountId: AccountID, nickname: String?, mailboxId: String, createdAt: Date) {
        self.accountId = accountId
        self.nickname = nickname
        self.mailboxId = mailboxId
        self.createdAt = createdAt
    }
}
