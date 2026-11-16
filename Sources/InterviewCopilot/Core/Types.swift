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

/// 听译方向。本地转写一次只支持一种语言，中英混合留给云端线路。
enum LanguageMode: String, CaseIterable, Identifiable {
    case enToZh
    case zhToEn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enToZh: return L("英文 → 中文")
        case .zhToEn: return L("中文 → 英文")
        }
    }

    var sourceLocale: Locale {
        Locale(identifier: self == .enToZh ? "en-US" : "zh-CN")
    }

    var sourceLanguage: Locale.Language {
        Locale.Language(identifier: self == .enToZh ? "en" : "zh-Hans")
    }

    var targetLanguage: Locale.Language {
        Locale.Language(identifier: self == .enToZh ? "zh-Hans" : "en")
    }
}

/// 转写线路。本地离线可用但延迟高；云端需要各自的 API Key。
enum ASRLine: String, CaseIterable, Identifiable {
    case auto
    case local
    case deepgram
    case assemblyai
    case aliyun

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
        return ASRLine(rawValue: UserDefaults.standard.string(forKey: "asrLine") ?? "") ?? .local
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
