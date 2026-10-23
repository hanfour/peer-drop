import Foundation

/// Stable code for a `NoteOutboxEntry.failReason`. The outbox stores the
/// (Traditional Chinese) reason text for diagnostics; UIs map it to this code
/// and show their own localized copy. Unknown text maps to `nil`.
public enum NoteOutboxFailure: Equatable, Sendable {
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

    public init?(reason: String?) {
        switch reason {
        case "綁定已取消": self = .bindingCancelled
        case "超過 24 小時仍未寄出": self = .tooOld
        case "已封鎖此聯絡人，未寄出": self = .blocked
        case "對方信箱已滿": self = .inboxFull
        case "多次嘗試後仍無法寄出，請稍後重試": self = .exhausted
        case "找不到對方的紙條帳號": self = .recipientNotFound
        case "對方尚未準備好接收紙條": self = .recipientHasNoKeys
        case "對方的帳號或金鑰已變更，請重新交換紙條帳號後再試": self = .recipientChanged
        case "紙條太長": self = .tooLong
        case "紙條不存在": self = .noteNotFound
        default: return nil
        }
    }
}
