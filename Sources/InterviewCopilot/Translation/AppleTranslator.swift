import Foundation
import Translation

/// 本地线路的翻译：系统 Translation 框架，完全离线。需要 macOS 26，更早的系统改用 LLMTranslator。
@available(macOS 26, *)
actor AppleTranslator: TranslationProvider {
    enum Readiness {
        case ready
        case needsDownload   // 系统支持该语言对，但语言包还没下载
        case unsupported
    }

    private let source: Locale.Language
    private let target: Locale.Language
    private var session: TranslationSession?

    init(source: Locale.Language, target: Locale.Language) {
        self.source = source
        self.target = target
    }

    func prepare() async -> Readiness {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            session = TranslationSession(installedSource: source, target: target)
            return .ready
        case .supported:
            return .needsDownload
        default:
            return .unsupported
        }
    }

    func translate(_ text: String) async throws -> String {
        guard let session else { throw AppError("翻译未就绪") }
        return try await session.translate(text).targetText
    }
}
