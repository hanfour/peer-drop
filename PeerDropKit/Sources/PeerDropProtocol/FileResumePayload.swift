import Foundation

public struct FileResumePayload: Codable {
    public let fileName: String
    public let fileSize: Int64
    public let sha256Hash: String
    public let resumeOffset: Int64

    public init(fileName: String, fileSize: Int64, sha256Hash: String, resumeOffset: Int64) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.sha256Hash = sha256Hash
        self.resumeOffset = resumeOffset
    }
}

public struct FileResumeAckPayload: Codable {
    public let accepted: Bool
    public let resumeOffset: Int64

    public init(accepted: Bool, resumeOffset: Int64) {
        self.accepted = accepted
        self.resumeOffset = resumeOffset
    }
}
