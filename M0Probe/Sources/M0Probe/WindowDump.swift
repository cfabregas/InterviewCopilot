import AppKit

/// 导出会议软件当前在屏幕上的窗口列表。
/// 分别在"未共享"和"正在共享"时各导出一次，对比差异，用来设计共享状态检测。
enum WindowDump {
    static let keywords = ["zoom", "腾讯会议", "wemeet", "tencent", "lark", "飞书", "feishu", "teams"]

    static func run() -> (url: URL, count: Int)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var lines: [String] = []
        for info in list {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard keywords.contains(where: { owner.lowercased().contains($0) }) else { continue }
            let name = info[kCGWindowName as String] as? String ?? "(无标题或无权限读取)"
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let sharing = info[kCGWindowSharingState as String] as? Int ?? -1
            var size = ""
            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
               let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double {
                size = "\(Int(w))x\(Int(h)) @ (\(Int(x)),\(Int(y)))"
            }
            lines.append("\(owner) | \(name) | layer=\(layer) | alpha=\(alpha) | sharing=\(sharing) | \(size)")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let url = Log.dir.appendingPathComponent("windows-\(formatter.string(from: Date())).txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return (url, lines.count)
    }
}
