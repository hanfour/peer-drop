import Foundation
import PeerDropDiary

/// User-facing text for every `DiaryError` case (spec §5.2's "錯誤文案
/// `DiaryError.userMessage`"), shared by every Diary sheet/view so the
/// wording stays consistent (and localized) across all of them. Mirrors
/// `NotesErrorText.swift`'s pattern.
extension DiaryError {
    func userMessage() -> String {
        switch self {
        case .notMember: return String(localized: "You're no longer a member of this diary.")
        case .notHolder: return String(localized: "It's not your turn to write.")
        case .notOwner: return String(localized: "Only the diary's owner can do that.")
        case .skipSelf: return String(localized: "You can't skip your own turn.")
        case .closed: return String(localized: "This diary is closed.")
        case .badCode: return String(localized: "That invite code isn't valid.")
        case .badRef: return String(localized: "That entry isn't available anymore.")
        case .full: return String(localized: "This diary is full.")
        case .limit: return String(localized: "You've reached the limit of 20 diaries.")
        case .membersFull: return String(localized: "This diary already has the maximum of 12 members.")
        case .exists: return String(localized: "A diary with that ID already exists.")
        case .tooLarge: return String(localized: "That text is too long.")
        case .noKey: return String(localized: "Waiting for the diary key.")
        case .notFound: return String(localized: "This diary couldn't be found.")
        case .badId: return String(localized: "That invite link isn't valid.")
        case .transient: return String(localized: "Network problem. Please try again.")
        case .network: return String(localized: "Something went wrong. Please try again.")
        }
    }
}
