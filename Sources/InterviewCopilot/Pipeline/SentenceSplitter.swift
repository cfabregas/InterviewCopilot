import Foundation

/// 长句切分：有些线路要等说话人停顿才定稿，一口气说很多句时译文会迟迟不出。
/// 这里在中间结果里找"已经稳定的整句"(连续 3 次中间结果都没变的前缀、以句末标点结束)，
/// 提前当作定稿交给下游翻译；后续结果里把已经交出去的部分去掉。
struct SentenceSplitter {
    /// 当前这一段里已经提前定稿的"有效字符"数(只数字母、数字和汉字，忽略标点和大小写的改写)
    private var emittedCount = 0
    private var history: [String] = []
    private var segmentStartMs: Int?

    /// 一段话超过这么久还没定稿，就允许在逗号处切
    private let forceSplitMs = 12_000
    /// 提前定稿的句子至少要有这么多有效字符，避免把 "How?" 这种还会被改写的短片段切出去
    private let minSentenceCount = 8

    mutating func process(_ event: ASREvent) -> [ASREvent] {
        let rest = Self.dropLeading(event.text, significantCount: emittedCount)
        if segmentStartMs == nil { segmentStartMs = event.startMs }

        switch event.kind {
        case .final:
            let startMs = emittedCount > 0 ? max(event.startMs, 0) : event.startMs
            emittedCount = 0
            history = []
            segmentStartMs = nil
            return [ASREvent(kind: .final, text: rest, startMs: startMs, endMs: event.endMs)]

        case .partial:
            history.append(rest)
            if history.count > 3 { history.removeFirst() }
            if history.count == 3 {
                let stable = Self.commonPrefix(history)
                let tooLong = event.endMs >= 0 && event.endMs - (segmentStartMs ?? event.startMs) > forceSplitMs
                if let cut = Self.sentenceBoundary(in: stable, full: rest, allowClause: tooLong, minCount: minSentenceCount) {
                    let sentence = String(rest[..<cut]).trimmingCharacters(in: .whitespaces)
                    let remaining = String(rest[cut...]).trimmingCharacters(in: .whitespaces)
                    emittedCount += Self.significantCount(sentence)
                    history = []
                    var result = [ASREvent(kind: .final, text: sentence, startMs: event.startMs, endMs: -1)]
                    if !remaining.isEmpty {
                        result.append(ASREvent(kind: .partial, text: remaining, startMs: event.startMs, endMs: event.endMs))
                    }
                    return result
                }
            }
            return rest.isEmpty ? [] : [ASREvent(kind: .partial, text: rest, startMs: event.startMs, endMs: event.endMs)]
        }
    }

    // MARK: - 文本工具

    private static func isSignificant(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func significantCount(_ text: String) -> Int {
        text.reduce(0) { $0 + (isSignificant($1) ? 1 : 0) }
    }

    /// 去掉开头的 count 个有效字符(以及紧跟其后的标点和空格)
    static func dropLeading(_ text: String, significantCount count: Int) -> String {
        guard count > 0 else { return text }
        var seen = 0
        var index = text.startIndex
        while index < text.endIndex, seen < count {
            if isSignificant(text[index]) { seen += 1 }
            index = text.index(after: index)
        }
        while index < text.endIndex, !isSignificant(text[index]) { index = text.index(after: index) }
        return String(text[index...])
    }

    static func commonPrefix(_ texts: [String]) -> String {
        guard var prefix = texts.first else { return "" }
        for text in texts.dropFirst() { prefix = prefix.commonPrefix(with: text) }
        return prefix
    }

    /// 在稳定前缀里找最后一个句子边界，返回它在 full 里的切分位置(边界标点之后)。
    /// 要求边界后面还有内容(说明说话人已经在说下一句)，且前面的句子够长。
    static func sentenceBoundary(in stable: String, full: String, allowClause: Bool, minCount: Int) -> String.Index? {
        let strong: Set<Character> = [".", "?", "!", "。", "？", "！"]
        let clause: Set<Character> = [",", "，", ";", "；"]
        let stableChars = Array(stable)
        let fullChars = Array(full)
        var best: Int?
        var significant = 0
        for (offset, character) in stableChars.enumerated() {
            if isSignificant(character) { significant += 1 }
            guard strong.contains(character) || (allowClause && clause.contains(character)) else { continue }
            let next = offset + 1
            guard next < fullChars.count, significant >= minCount else { continue }
            // 英文句点和逗号后面必须是空格，排除 3.5、e.g. 这类情况
            if character.isASCII, fullChars[next] != " " { continue }
            if fullChars[next...].contains(where: isSignificant) { best = next }
        }
        return best.map { full.index(full.startIndex, offsetBy: $0) }
    }
}
