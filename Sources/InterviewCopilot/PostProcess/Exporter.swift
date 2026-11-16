import AppKit
import Foundation

/// 把一场面试的复盘导出成 Markdown 或 PDF
enum Exporter {
    static func clock(_ ms: Int) -> String {
        let seconds = max(ms, 0) / 1000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func markdown(session: SessionInfo, summary: String, qa: [QAItem], utterances: [Utterance]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(session.displayTitle)\n\n"
        out += L("%@，时长 %@ 分 %@ 秒，%@\n\n", "\(formatter.string(from: session.startedAt))", "\(session.durationSeconds / 60)", "\(session.durationSeconds % 60)", "\(session.mode.title)")
        if !summary.isEmpty { out += summary + "\n\n" }

        if !qa.isEmpty {
            out += L("## 问答复盘\n\n")
            for item in qa {
                let score = item.score > 0 ? L("，评分 %@/5", "\(item.score)") : ""
                out += "### \(item.idx + 1). \(item.question)\n\n"
                out += (item.kind.isEmpty ? "" : L(item.kind) + L("，")) + clock(item.askedMs) + score + "\n\n"
                if !item.myAnswer.isEmpty { out += "**\(item.kind == "反问" ? L("面试官的回答") : L("我的回答"))**\n\n\(item.myAnswer)\n\n" }
                if !item.evaluation.isEmpty { out += L("**评价**\n\n%@\n\n", "\(item.evaluation)") }
                if !item.reference.isEmpty { out += L("**参考答案**\n\n%@\n\n", "\(item.reference)") }
                if !item.suggested.isEmpty { out += L("**会中给出的建议答案**\n\n%@\n\n", "\(item.suggested.replacingOccurrences(of: "\n---", with: "\n"))") }
            }
        }

        if !utterances.isEmpty {
            out += L("## 完整记录\n\n")
            for utterance in utterances {
                out += "**" + clock(utterance.startMs) + " " + Localized.speaker(utterance.speaker) + "**" + L("：") + utterance.text + "\n\n"
                if !utterance.translation.isEmpty { out += "> \(utterance.translation)\n\n" }
            }
        }
        return out
    }

    /// 够用的 Markdown 转 HTML：标题、列表、引用、加粗、段落
    static func html(fromMarkdown markdown: String) -> String {
        func inline(_ text: String) -> String {
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return escaped.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
        }
        var body = ""
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // 列表不用 <ul>：系统把 HTML 转成富文本时会多画一层圆点
            if line.hasPrefix("- ") || line.hasPrefix("* ") { body += "<p class=\"item\">•&nbsp;&nbsp;\(inline(String(line.dropFirst(2))))</p>" }
            else if line.hasPrefix("### ") { body += "<h3>\(inline(String(line.dropFirst(4))))</h3>" }
            else if line.hasPrefix("## ") { body += "<h2>\(inline(String(line.dropFirst(3))))</h2>" }
            else if line.hasPrefix("# ") { body += "<h1>\(inline(String(line.dropFirst(2))))</h1>" }
            else if line.hasPrefix("> ") { body += "<p class=\"quote\">\(inline(String(line.dropFirst(2))))</p>" }
            else { body += "<p>\(inline(line))</p>" }
        }
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 11pt; line-height: 1.5; color: #1d1d1f; }
        h1 { font-size: 19pt; } h2 { font-size: 14pt; margin-top: 18pt; } h3 { font-size: 12pt; margin-top: 14pt; }
        p.quote { color: #6e6e73; margin-left: 12pt; }
        p.item { margin: 2pt 0 2pt 10pt; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// 排成 A4 多页的 PDF
    @MainActor
    static func writePDF(markdown: String, to url: URL) throws {
        guard let data = html(fromMarkdown: markdown).data(using: .utf8),
              let text = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                            documentAttributes: nil) else {
            throw AppError(L("生成 PDF 内容失败"))
        }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 48; info.bottomMargin = 48; info.leftMargin = 48; info.rightMargin = 48
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 595 - 96, height: 842 - 96))
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw AppError(L("写入 PDF 失败")) }
    }
}
