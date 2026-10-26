import Foundation
import PeerDropAccount

public enum GroupError: Error, Equatable, Sendable {
    case notMember
    case awaitingKey
    case staleEpoch
    case membersChanged
    case notOwner
    case closed
    case banned
    case badCode
    case accountRequired
    case bearerRequired
    case membersFull
    case groupLimit
    case exists
    case tooLarge
    case badSignature
    case notFound
    case badId
    case transient(String)
    case network(String)

    public static func from(_ error: Error) -> GroupError {
        switch error {
        case AccountClientError.forbidden(let code):
            switch code {
            case "not_member": return .notMember
            case "awaiting_key": return .awaitingKey
            case "not_owner": return .notOwner
            case "group_closed": return .closed
            case "banned": return .banned
            case "bad_code": return .badCode
            case "account_required": return .accountRequired
            default: return .network(code)
            }
        case AccountClientError.conflict(let code):
            switch code {
            case "stale_epoch": return .staleEpoch
            case "members_changed": return .membersChanged
            case "group_full_members": return .membersFull
            case "group_limit": return .groupLimit
            case "group_exists": return .exists
            default: return .network(code)
            }
        case AccountClientError.invalid(let code):
            switch code {
            case "bad_sig": return .badSignature
            case "too_large": return .tooLarge
            case "invalid_id": return .badId
            default: return .network(code)
            }
        case AccountClientError.rateLimited:
            return .transient("rate_limited")
        case AccountClientError.unauthorized:
            return .bearerRequired
        case AccountClientError.http(404):
            return .notFound
        case AccountClientError.http(413):
            return .tooLarge
        case AccountClientError.http(let status) where (500...599).contains(status):
            return .transient("http_\(status)")
        case AccountClientError.http(let status):
            return .network("http_\(status)")
        case AccountClientError.insufficientStorage(let code):
            return .transient(code)
        case AccountClientError.invalidResponse:
            return .network("invalid_response")
        case let urlError as URLError:
            return .transient("transport_\(urlError.code.rawValue)")
        default:
            return .network(String(describing: error))
        }
    }
}
