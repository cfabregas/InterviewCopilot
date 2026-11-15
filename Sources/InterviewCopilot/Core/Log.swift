import Foundation

/// 应用数据目录：~/Library/Application Support/InterviewCopilot
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("InterviewCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let sessions: URL = {
        let dir = root.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let database = root.appendingPathComponent("copilot.sqlite")
    static let logFile = root.appendingPathComponent("app.log")
}

enum Log {
    static var sink: ((String) -> Void)?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let queue = DispatchQueue(label: "copilot.log")

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: AppPaths.logFile) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: AppPaths.logFile, atomically: true, encoding: .utf8)
            }
        }
        DispatchQueue.main.async { sink?(line) }
    }
}
