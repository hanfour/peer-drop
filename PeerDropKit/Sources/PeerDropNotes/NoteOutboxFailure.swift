import Foundation

/// Stable code for a `NoteOutboxEntry.failReason`. The outbox stores the
/// (Traditional Chinese) reason text for diagnostics; UIs map it to this code
/// and show their own localized copy. `reasonText` is the single source of the
/// stored text, shared by the sender and by `init?(reason:)`, so they cannot drift.
public enum NoteOutboxFailure: Equatable, Sendable, CaseIterable {
    case bindingCancelled
    case tooOld
    case blocked
    case inboxFull
    case exhausted
    case recipientNotFound
    case recipientHasNoKeys
    case recipientChanged
    case tooLong
    case noteNotFound

    /// The text stored in `failReason`.
    public var reasonText: String {
        switch self {
        case .bindingCancelled: return "綁定已取消"
        case .tooOld: return "超過 24 小時仍未寄出"
        case .blocked: return "已封鎖此聯絡人，未寄出"
        case .inboxFull: return "對方信箱已滿"
        case .exhausted: return "多次嘗試後仍無法寄出，請稍後重試"
        case .recipientNotFound: return "找不到對方的紙條帳號"
        case .recipientHasNoKeys: return "對方尚未準備好接收紙條"
        case .recipientChanged: return "對方的帳號或金鑰已變更，請重新交換紙條帳號後再試"
        case .tooLong: return "紙條太長"
        case .noteNotFound: return "紙條不存在"
        }
    }

    public init?(reason: String?) {
        guard let reason, let match = Self.allCases.first(where: { $0.reasonText == reason }) else { return nil }
        self = match
    }

    /// False when sending the same note again can never succeed: the user has to
    /// exchange notes again (or the note itself is the problem).
    public var isRetryable: Bool {
        switch self {
        case .bindingCancelled, .recipientChanged, .blocked, .tooLong, .noteNotFound: return false
        case .tooOld, .inboxFull, .exhausted, .recipientNotFound, .recipientHasNoKeys: return true
        }
    }
}
