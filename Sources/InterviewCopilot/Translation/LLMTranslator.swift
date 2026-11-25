import Foundation

/// 系统翻译用不了时(macOS 26 以前)的替代：用当前大模型线路的快档逐句翻译，需要密钥和网络。
struct LLMTranslator: TranslationProvider {
    let client: LLMClient
    let mode: LanguageMode

    /// 没填大模型密钥时返回 nil
    static func make(mode: LanguageMode) -> LLMTranslator? {
        guard mode.translates else { return nil }
        return LLMLine.saved.makeClient().map { LLMTranslator(client: $0, mode: mode) }
    }

    func translate(_ text: String) async throws -> String {
        let (source, target) = mode == .enToZh ? ("英文", "简体中文") : ("中文", "英文")
        let system = "你是同声传译。把用户给的一句\(source)口语翻译成自然的\(target)，只输出译文，不要解释，不要加引号。"
        var result = ""
        for try await piece in client.stream(system: system, user: text, tier: .fast) { result += piece }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
