import AppKit
import Foundation
import PDFKit

/// 简历分中文、英文两份，各自独立导入和清除
enum ResumeSlot: String, CaseIterable, Identifiable {
    case en
    case zh

    var id: String { rawValue }
    var title: String { self == .en ? L("英文简历") : L("中文简历") }
    fileprivate var file: URL { AppPaths.root.appendingPathComponent("resume-\(rawValue).txt") }
    fileprivate var nameKey: String { "resumeFileName.\(rawValue)" }
    fileprivate var termsKey: String { "resumeTerms.\(rawValue)" }
}

/// 简历和岗位描述(JD)。提取出的文字存在应用数据目录，作为答案生成的固定背景；
/// 另外用大模型从中抽出热词，提高转写对公司名、技术名词的准确率。
@MainActor
final class ResumeStore: ObservableObject {
    @Published private(set) var texts: [ResumeSlot: String] = [:]
    @Published private(set) var fileNames: [ResumeSlot: String] = [:]
    @Published private(set) var terms: [ResumeSlot: [String]] = [:]
    @Published private(set) var analyzing: Set<ResumeSlot> = []
    @Published var jd = "" {
        didSet { if jd != oldValue { try? jd.write(to: Self.jdFile, atomically: true, encoding: .utf8) } }
    }

    /// 两份简历的热词合并后存在这里，转写启动时读取
    static let termsDefaultsKey = "resumeTerms"
    private static let jdFile = AppPaths.root.appendingPathComponent("jd.txt")
    private static let legacyFile = AppPaths.root.appendingPathComponent("resume.txt")

    init() {
        let defaults = UserDefaults.standard
        migrateLegacy()
        for slot in ResumeSlot.allCases {
            guard let text = try? String(contentsOf: slot.file, encoding: .utf8), !text.isEmpty else { continue }
            texts[slot] = text
            fileNames[slot] = defaults.string(forKey: slot.nameKey) ?? ""
            terms[slot] = (defaults.string(forKey: slot.termsKey) ?? "").split(separator: "\n").map(String.init)
        }
        jd = (try? String(contentsOf: Self.jdFile, encoding: .utf8)) ?? ""
    }

    /// 早期版本只有一份简历：按内容是中文还是英文放进对应的位置
    private func migrateLegacy() {
        guard let text = try? String(contentsOf: Self.legacyFile, encoding: .utf8), !text.isEmpty else { return }
        let defaults = UserDefaults.standard
        let chinese = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let slot: ResumeSlot = chinese * 5 > text.count ? .zh : .en
        if !FileManager.default.fileExists(atPath: slot.file.path) {
            try? text.write(to: slot.file, atomically: true, encoding: .utf8)
            defaults.set(defaults.string(forKey: "resumeFileName") ?? "", forKey: slot.nameKey)
            defaults.set(defaults.string(forKey: Self.termsDefaultsKey) ?? "", forKey: slot.termsKey)
        }
        try? FileManager.default.removeItem(at: Self.legacyFile)
        defaults.removeObject(forKey: "resumeFileName")
    }

    /// 生成答案时用哪份简历：英文面试优先英文简历，中文面试优先中文简历；只有另一种语言的也照用
    func text(for mode: LanguageMode) -> String {
        // 自动识别：不知道会用哪种语言问，两份都给
        if mode == .auto, let en = texts[.en], let zh = texts[.zh] {
            return "【英文简历】\n\(en)\n\n【中文简历】\n\(zh)"
        }
        let preferred: ResumeSlot = mode == .enToZh ? .en : .zh
        let other: ResumeSlot = preferred == .en ? .zh : .en
        return texts[preferred] ?? texts[other] ?? ""
    }

    func describeChoice(for mode: LanguageMode) -> String {
        if mode == .auto, texts[.en] != nil, texts[.zh] != nil {
            return L("中英文简历都用(%@，%@)", length(.en), length(.zh))
        }
        let preferred: ResumeSlot = mode == .enToZh ? .en : .zh
        let other: ResumeSlot = preferred == .en ? .zh : .en
        if texts[preferred] != nil { return "\(preferred.title) \(length(preferred))" }
        if texts[other] != nil { return L("没有%@，改用%@ %@", "\(preferred.title)", "\(other.title)", "\(length(other))") }
        return L("未导入简历(只能给通用回答)")
    }

    /// 简历长度：英文按单词数，中文按字数(不算空白)
    func length(_ slot: ResumeSlot) -> String {
        let text = texts[slot] ?? ""
        if slot == .en {
            return L("%@ 词", "\(text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }.count)")
        }
        return L("%@ 字", "\(text.filter { !$0.isWhitespace }.count)")
    }

    func summary(_ slot: ResumeSlot) -> String {
        guard texts[slot] != nil else { return L("未导入") }
        return L("%@(%@，热词 %@ 个)", fileNames[slot] ?? "", length(slot), "\(terms[slot]?.count ?? 0)")
    }

    /// 从文件读出文字。支持 PDF、Word、RTF 和纯文本。
    static func extractText(from url: URL) throws -> String {
        let content: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), let string = document.string else {
                throw AppError(L("读不出这个 PDF 的文字(可能是扫描件)"))
            }
            content = string
        } else if ["txt", "md"].contains(url.pathExtension.lowercased()) {
            content = try String(contentsOf: url, encoding: .utf8)
        } else {
            content = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 50 else { throw AppError(L("文件里几乎没有文字")) }
        return trimmed
    }

    /// 导入简历，覆盖该位置上原有的那份。persist 为 false 时只在本次运行里生效(自测用)。
    func load(from url: URL, slot: ResumeSlot, persist: Bool = true) throws {
        let text = try Self.extractText(from: url)
        texts[slot] = text
        fileNames[slot] = url.lastPathComponent
        terms[slot] = []
        if persist {
            try text.write(to: slot.file, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(url.lastPathComponent, forKey: slot.nameKey)
            saveTerms(slot)
        }
        Log.write("\(slot.title)已导入：\(url.lastPathComponent)，\(length(slot))")
    }

    /// 清除一份简历：文字、文件名和它带来的热词一起删掉
    func clear(_ slot: ResumeSlot) {
        texts[slot] = nil
        fileNames[slot] = nil
        terms[slot] = nil
        try? FileManager.default.removeItem(at: slot.file)
        UserDefaults.standard.removeObject(forKey: slot.nameKey)
        saveTerms(slot)
        Log.write("\(slot.title)已清除")
    }

    /// 手动编辑某份简历的热词
    func setTerms(_ slot: ResumeSlot, _ list: [String]) {
        guard texts[slot] != nil else { return }
        terms[slot] = list
        saveTerms(slot)
    }

    private func saveTerms(_ slot: ResumeSlot) {
        let defaults = UserDefaults.standard
        defaults.set((terms[slot] ?? []).joined(separator: "\n"), forKey: slot.termsKey)
        let merged = ResumeSlot.allCases.flatMap { terms[$0] ?? [] }
        defaults.set(merged.joined(separator: "\n"), forKey: Self.termsDefaultsKey)
    }

    /// 用大模型从这份简历和 JD 里抽热词
    func extractTerms(_ slot: ResumeSlot, using llm: LLMClient, persist: Bool = true) async {
        guard let text = texts[slot] else { return }
        analyzing.insert(slot)
        defer { analyzing.remove(slot) }
        let system = """
        你在为语音识别准备热词表。从下面的简历和岗位描述里，抽出面试中可能被提到、且语音识别容易听错的专有名词：\
        公司名、产品名、项目名、技术名词、框架、工具、缩写。不要抽普通词汇。最多 40 个。
        只输出一个 JSON 字符串数组，不要输出其他内容。
        """
        let user = "<resume>\n\(text)\n</resume>\n\n<jd>\n\(jd)\n</jd>"
        do {
            // 抽热词只在导入简历时做一次，不赶时间，用强模型
            let reply = try await llm.complete(system: system, user: user, tier: .strong)
            guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"),
                  let data = String(reply[start...end]).data(using: .utf8),
                  let raw = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                Log.write("热词抽取结果无法解析：\(reply.prefix(120))")
                return
            }
            // 模型有时不听话，返回的是 {"name": ...} 对象数组，也一并接受
            let list = raw.compactMap { item -> String? in
                if let text = item as? String { return text }
                guard let object = item as? [String: Any] else { return nil }
                return ["name", "term", "word", "value"].compactMap { object[$0] as? String }.first
            }
            guard texts[slot] == text else { return }   // 抽取期间简历被换掉或清除了
            let found = Array(list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(40))
            terms[slot] = found
            if persist { saveTerms(slot) }
            Log.write("从\(slot.title)抽出热词 \(found.count) 个：\(found.prefix(10).joined(separator: "、"))\(found.count > 10 ? "…" : "")")
        } catch {
            Log.write("热词抽取失败：\(error)")
        }
    }
}
