import AVFoundation
import Foundation

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// 最多等待指定秒数。操作按时完成返回 true，超时返回 false(操作本身不会被打断)。
func waitUpTo(_ seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
    let once = Once()
    return await withCheckedContinuation { continuation in
        Task {
            await operation()
            if once.claim() { continuation.resume(returning: true) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { continuation.resume(returning: false) }
        }
    }
}

/// 听译方向。auto 是自动识别中英文、只转写不翻译；本地转写一次只支持一种语言，中英混合留给云端线路。
enum LanguageMode: String, CaseIterable, Identifiable {
    case auto
    case enToZh
    case zhToEn

    var id: String { rawValue }

    /// 上次选的方向，第一次用默认自动
    static var saved: LanguageMode {
        get { UserDefaults.standard.string(forKey: "languageMode").flatMap(LanguageMode.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "languageMode") }
    }

    /// 自测参数：--mode=zh 中文，--mode=auto 自动识别，默认英文
    static var fromArguments: LanguageMode {
        if CommandLine.arguments.contains("--mode=auto") { return .auto }
        return CommandLine.arguments.contains("--mode=zh") ? .zhToEn : .enToZh
    }

    var title: String {
        switch self {
        case .auto: return L("自动识别(只转写)")
        case .enToZh: return L("英文 → 中文")
        case .zhToEn: return L("中文 → 英文")
        }
    }

    var translates: Bool { self != .auto }

    /// 交给转写线路的语言。自动模式用 "mul"，各条线路自己决定怎么做多语言识别。
    var sourceLocale: Locale {
        switch self {
        case .auto: return .multilingual
        case .enToZh: return Locale(identifier: "en-US")
        case .zhToEn: return Locale(identifier: "zh-CN")
        }
    }

    var sourceLanguage: Locale.Language {
        Locale.Language(identifier: self == .zhToEn ? "zh-Hans" : "en")
    }

    var targetLanguage: Locale.Language {
        Locale.Language(identifier: self == .enToZh ? "zh-Hans" : "en")
    }

    /// 自动模式下按这段文字的实际语言换成对应的固定方向，用来挑简历、拼句子、决定回答语言
    func resolved(for text: String) -> LanguageMode {
        guard self == .auto else { return self }
        // 汉字个数和英文单词数比多少：中文里夹几个英文术语仍算中文
        let chinese = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let english = text.split { !$0.isASCII || !$0.isLetter }.count
        return chinese > 0 && chinese >= english ? .zhToEn : .enToZh
    }
}

extension Locale {
    /// 自动识别中英文的占位语言
    static let multilingual = Locale(identifier: "mul")
    var isMultilingual: Bool { identifier == "mul" }
    /// 只能识别一种语言的引擎(本地转写)在自动模式下用中文：中文模型能认出夹杂的英文词，反过来不行
    var singleLanguage: Locale { isMultilingual ? Locale(identifier: "zh-CN") : self }
}

extension String {
    /// 含有汉字
    var hasChinese: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// 繁体转简体(多语言识别有时会把普通话标成粤语、输出繁体)
    var simplifiedChinese: String {
        hasChinese ? (applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? self) : self
    }
}

/// 把几段文字接起来：两边都是英文时加空格，挨着汉字时不加
func joinSpeech(_ parts: [String]) -> String {
    var result = ""
    for part in parts where !part.isEmpty {
        if let last = result.last, let first = part.first, !isCJK(last), !isCJK(first) {
            result += " "
        }
        result += part
    }
    return result
}

private func isCJK(_ c: Character) -> Bool {
    c.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
}

/// 转写线路。本地离线可用但延迟高；云端需要各自的 API Key。
enum ASRLine: String, CaseIterable, Identifiable {
    case auto
    case local
    case aliyun
    case deepgram
    case assemblyai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return L("自动(选最快的云端线路)")
        case .local: return L("本地(离线)")
        case .deepgram: return L("海外：Deepgram")
        case .assemblyai: return L("海外：AssemblyAI")
        case .aliyun: return L("国内：阿里云百炼")
        }
    }

    /// 钥匙串里的条目名；本地线路不需要密钥
    var keyAccount: String? { self == .local || self == .auto ? nil : "asr.\(rawValue)" }

    /// 启动参数 --line=<名字> 优先，其次是上次的选择
    static var initial: ASRLine {
        for argument in CommandLine.arguments where argument.hasPrefix("--line=") {
            if let line = ASRLine(rawValue: String(argument.dropFirst(7))) { return line }
        }
        return ASRLine(rawValue: UserDefaults.standard.string(forKey: "asrLine") ?? "") ?? .aliyun
    }
}

/// 转写事件。endMs 为负数表示供应商没给出时间。partial 会被后续事件改写，final 之后该句段不再变化。
struct ASREvent {
    enum Kind { case partial, final }
    let kind: Kind
    let text: String
    let startMs: Int
    let endMs: Int
}

/// 流式转写供应商。本地和云端实现同一套接口。
protocol ASRProvider: AnyObject {
    var events: AsyncStream<ASREvent> { get }
    func start(locale: Locale) async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    func stop() async
}

/// 翻译供应商。本地和大模型实现同一套接口。
protocol TranslationProvider {
    func translate(_ text: String) async throws -> String
}

/// 悬浮窗上的一条字幕
struct SubtitleLine: Identifiable {
    let id: Int
    var source: String
    var translation = ""
    var isFinal = false
    var translationIsProvisional = false
    var segmentID: Int64?
}
