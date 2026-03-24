import Foundation

struct FileResumePayload: Codable {
    let fileName: String
    let fileSize: Int64
    let sha256Hash: String
    let resumeOffset: Int64

    init(fileName: String, fileSize: Int64, sha256Hash: String, resumeOffset: Int64) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.sha256Hash = sha256Hash
        self.resumeOffset = resumeOffset
    }
}

struct FileResumeAckPayload: Codable {
    let accepted: Bool
    let resumeOffset: Int64

    init(accepted: Bool, resumeOffset: Int64) {
        self.accepted = accepted
        self.resumeOffset = resumeOffset
    }
}
