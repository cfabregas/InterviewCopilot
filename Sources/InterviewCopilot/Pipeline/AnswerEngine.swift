import Foundation

/// 悬浮窗上的答案卡
struct AnswerCard {
    var question: String
    var text = ""
    var isStreaming = true
    var error: String?

    /// 答案分两部分，用单独一行的 --- 隔开：中文要点、可以照着说的回答
    var points: String { parts.0 }
    var script: String { parts.1 }

    private var parts: (String, String) {
        if let range = text.range(of: "\n---") {
            return (String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "-\n ")))
        }
        // 模型有时会漏掉分隔线：开头连续的"- "行算要点，其余算回答
        let lines = text.components(separatedBy: "\n")
        var pointCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.isEmpty { pointCount += 1 } else { break }
        }
        return (lines[..<pointCount].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                lines[pointCount...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 问题检测和答案生成：
/// - 把面试官连续说的几句合并成"一轮发言"(停顿超过 1.2 秒算一轮结束)；
/// - 句子一看就是问题时不等这一轮结束，立刻开始生成答案(预启动)；
/// - 一轮结束后用小模型确认是不是问题：不是就撤掉预启动的答案，是而没预启动的就补上；
/// - 快捷键可以随时对上一轮发言强制生成答案。
@MainActor
final class AnswerEngine: ObservableObject {
    @Published var card: AnswerCard?
    @Published var enabled = UserDefaults.standard.object(forKey: "answersEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "answersEnabled") }
    }
    @Published var llmLine: LLMLine = .saved {
        didSet { UserDefaults.standard.set(llmLine.rawValue, forKey: "llmLine") }
    }

    let resume: ResumeStore
    /// 一个问题的答案生成完毕(问题、答案、问题结束时的音频位置)
    var onAnswered: ((String, String, Int) -> Void)?

    private var llm: LLMClient?
    private var mode: LanguageMode = .enToZh
    private var systemPrompt = ""

    private var turn: [String] = []
    private var turnEndMs = 0
    private var speaking = false
    private var turnTimer: Task<Void, Never>?
    private var lastTurn = ""
    /// 当前这一轮里已经预启动了答案的问题文本
    private var prestarted: String?

    private var generation: Task<Void, Never>?
    private var generationID = 0
    private var asked: [String] = []
    private let turnGap: TimeInterval = 1.2

    init(resume: ResumeStore) {
        self.resume = resume
    }

    // MARK: - 会话生命周期

    func sessionStarted(mode: LanguageMode) {
        self.mode = mode
        turn = []
        lastTurn = ""
        prestarted = nil
        asked = []
        card = nil
        llm = llmLine.makeClient()
        systemPrompt = Self.makeSystemPrompt(mode: mode, resume: resume.text(for: mode), jd: resume.jd)
        guard enabled else { return }
        if llm == nil {
            Log.write("实时答案未启用：还没有填写\(llmLine.title)的密钥")
        } else {
            Log.write("实时答案：\(llmLine.title)，快档 \(LLMModels.name(llmLine, .fast))，强档 \(LLMModels.name(llmLine, .strong))，\(resume.describeChoice(for: mode))")
        }
    }

    func sessionEnded() {
        turnTimer?.cancel()
        // 让正在生成的答案写完，方便结束后还能看到
    }

    // MARK: - 来自转写的输入

    func heardPartial() {
        speaking = true
    }

    func heardFinal(_ text: String, endMs: Int) {
        speaking = false
        turn.append(text)
        if endMs >= 0 { turnEndMs = endMs }
        guard enabled, llm != nil else { armTurnTimer(); return }

        // 预启动：这句话一看就是问题，不等这一轮结束
        if Self.looksLikeQuestion(text) {
            let question = joinSpeech(turn)
            prestarted = question
            Log.write("问题预启动：\(question)")
            startAnswer(question: question, heardAt: Date())
        }
        armTurnTimer()
    }

    private func armTurnTimer() {
        turnTimer?.cancel()
        turnTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(1.2 * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.speaking {
                // 对方还在说，这一轮没结束；等下一句定稿再判断
                return
            }
            await self.closeTurn()
        }
    }

    private func closeTurn() async {
        let text = joinSpeech(turn)
        let already = prestarted
        turn = []
        prestarted = nil
        guard !text.isEmpty else { return }
        lastTurn = text
        guard enabled, let llm else { return }

        // 太短的一轮(寒暄、应答)不值得问模型
        let tooShort = mode.resolved(for: text) == .enToZh ? text.split(separator: " ").count < 4 : text.count < 6
        if tooShort, already == nil { return }

        let isQuestion = await classify(text, using: llm)
        guard !Task.isCancelled else { return }
        switch (isQuestion, already != nil) {
        case (true, false):
            Log.write("问题检出(分类)：\(text)")
            startAnswer(question: text, heardAt: Date())
        case (false, true):
            Log.write("分类判定不是问题，撤掉预启动的答案：\(text)")
            cancelAnswer()
        default:
            break
        }
    }

    /// 快捷键：对上一轮发言(或正在进行的这一轮)强制生成答案
    func answerLastTurn() {
        let current = joinSpeech(turn)
        let question = current.isEmpty ? lastTurn : current
        guard !question.isEmpty else {
            Log.write("还没有听到可以回答的内容")
            return
        }
        guard llm != nil else {
            Log.write("无法生成答案：还没有填写\(llmLine.title)的密钥")
            return
        }
        Log.write("手动触发答案：\(question)")
        startAnswer(question: question, heardAt: Date())
    }

    func dismissCard() {
        cancelAnswer()
    }

    // MARK: - 判断是不是问题

    /// 不调用模型的快速判断：问号结尾，或者是明显的提问/要求讲述的句式
    static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return false }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return true }
        let lower = trimmed.lowercased()
        let starts = ["tell me", "describe", "explain", "walk me through", "talk about", "give me an example",
                      "could you", "can you", "would you", "how ", "what ", "why ", "which ", "do you", "did you",
                      "have you"]
        if starts.contains(where: { lower.hasPrefix($0) }) { return true }
        let chinese = ["什么", "怎么", "如何", "为什么", "请介绍", "介绍一下", "讲讲", "说说", "谈谈", "讲一下", "说一下"]
        return chinese.contains(where: { trimmed.contains($0) })
    }

    private func classify(_ text: String, using llm: LLMClient) async -> Bool {
        let system = """
        你在帮候选人听面试。判断面试官下面这段话，是否在向候选人提问，或者要求候选人讲述、解释、举例、设计方案。
        寒暄、过渡语、面试官自己的陈述或介绍，都不算。
        只输出一个词：question 或 other。
        """
        do {
            let reply = try await llm.complete(system: system, user: text, tier: .fast)
            return reply.lowercased().contains("question")
        } catch {
            Log.write("问题分类失败：\(error)")
            // 分类失败时保持现状：预启动的继续，没预启动的不补
            return prestartedFallback(text)
        }
    }

    private func prestartedFallback(_ text: String) -> Bool {
        Self.looksLikeQuestion(text)
    }

    // MARK: - 答案生成

    private func cancelAnswer() {
        generationID += 1
        generation?.cancel()
        generation = nil
        card = nil
    }

    private func startAnswer(question: String, heardAt: Date) {
        guard let llm else { return }
        generation?.cancel()
        generationID += 1
        let id = generationID
        card = AnswerCard(question: question)
        let previous = asked.suffix(4)
        let user = (previous.isEmpty ? "" : "本场面试已经问过的问题：\n" + previous.map { "- \($0)" }.joined(separator: "\n") + "\n\n")
            + "面试官刚才说：\n\(question)"
        let system = systemPrompt
        let endMs = turnEndMs

        generation = Task { [weak self] in
            var gotFirst = false
            var full = ""
            do {
                for try await piece in llm.stream(system: system + L10n.shared.promptNote, user: user, tier: .strong) {
                    guard let self, self.generationID == id else { return }
                    if !gotFirst {
                        gotFirst = true
                        Log.write("答案首字延迟 \(Int(Date().timeIntervalSince(heardAt) * 1000)) ms")
                    }
                    full += piece
                    self.card?.text = full
                }
                guard let self, self.generationID == id else { return }
                self.card?.isStreaming = false
                self.asked.append(question)
                Log.write("答案完成(\(Int(Date().timeIntervalSince(heardAt) * 1000)) ms，\(full.count) 字)：\n\(full)")
                self.onAnswered?(question, full, endMs)
            } catch {
                guard let self, self.generationID == id, !Task.isCancelled else { return }
                self.card?.isStreaming = false
                self.card?.error = "\(error)"
                Log.write("答案生成失败：\(error)")
            }
        }
    }

    static func makeSystemPrompt(mode: LanguageMode, resume: String, jd: String) -> String {
        let script = switch mode {
        case .enToZh: "用英文写一段口语化的回答，100–150 个单词"
        case .zhToEn: "用中文写一段口语化的回答，200–300 个字"
        case .auto: "用面试官这段话所用的语言写一段口语化的回答：面试官说中文就用中文写 200–300 个字，说英文就用英文写 100–150 个单词"
        }
        return """
        你是候选人的面试提词助手。面试官刚说了一段话，你要根据候选人的简历，给出候选人可以直接照着说的回答。

        输出格式(严格遵守，不要输出任何其他内容)：
        先输出 3–5 条中文要点，每条单独一行、以"- "开头、不超过 20 个字，让候选人扫一眼就知道要说什么；
        然后单独一行输出 ---；
        然后\(script)，第一人称，可以直接照着念。

        规则：
        - 只引用简历里真实存在的经历、项目和数字，不得编造。只有在简历里完全找不到相关经历、回答必须靠候选人自己补充时，才把第一条要点写成"需结合自身情况"并给出通用的回答框架；简历里有相关经历时不要写这一条。
        - 不要给简历里的事实添加细节：不要补充简历没写的活动名称、时间、数字、工具用途或结果(例如简历只写"大促"，就不要说成某个具体的购物节；简历没写"零停机"，就不要说)。宁可说得笼统，也不要说错。
        - 每件事都要说对是在哪家公司、哪个项目里做的，不要把一家公司的数字或做法安到另一家头上；简历里已经结束的工作用过去时。
        - 不要虚构具体的冲突、对话或决策过程。问到简历没有记录的情境(比如和同事的分歧、遇到过的具体问题)时，回答里只讲简历里有的事实，缺少的具体情节用方括号占位让候选人自己填，例如"[补充：当时的分歧是什么]"。
        - "---"之后的回答是候选人要直接念给面试官听的话：不要出现"简历""需结合自身情况"这类字眼，不要对候选人说话，不要解释你在做什么。
        - 要点一律用中文写(技术名词除外)。
        - 行为类问题按"情境、任务、行动、结果"组织。
        - 算法或系统设计题给出思路、关键取舍和复杂度。
        - 寒暄或很简单的问题，简短回答即可。
        - 技术名词、产品名保留原文，不要翻译。

        <resume>
        \(resume.isEmpty ? "(候选人没有提供简历)" : resume)
        </resume>

        <jd>
        \(jd.isEmpty ? "(没有提供岗位描述)" : jd)
        </jd>
        """
    }
}
