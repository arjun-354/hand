import Foundation

/// Writes to ~/Library/Logs/Hand so runs can be inspected after the fact.
enum Log {
    static let dir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Hand")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func write(_ text: String, to file: String) {
        try? text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    static func append(_ line: String) {
        let url = dir.appendingPathComponent("hand.log")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[hand] \(message)\n".utf8))
    Log.append(message)
}
