import Foundation

/// 会后处理管线：重新转写 → 回声去重 → 全文翻译 → 问答配对、评价和纪要。
/// 每个任务做完都在数据库里记一笔，中途退出后再处理时从没做完的那一步接着做。
@MainActor
final class PostProcessor: ObservableObject {
    /// 正在处理的会话
    @Published private(set) var running: Int64?
    @Published private(set) var stage = ""
    /// 数据有变化时加一，复盘页据此刷新
    @Published private(set) var revision = 0

    private let answers: AnswerEngine
    private var store: Store? { Store.shared }

    init(answers: AnswerEngine) {
        self.answers = answers
    }

    /// 处理一场面试。force 为 true 时丢掉之前的结果从头再来。
    func process(_ id: Int64, force: Bool = false) async {
        guard running == nil else {
            Log.write("会后处理：已有一场正在处理，请等它结束")
            return
        }
        guard let store, let session = store.session(id) else { return }
        running = id
        defer {
            running = nil
            stage = ""
            revision += 1
        }
        if force { store.clearPostResults(session: id) }
        let began = Date()
        Log.write("会后处理开始：\(session.displayTitle)(录音 \(session.durationSeconds) 秒)")

        for task in PostTask.allCases {
            if store.jobs(session: id)[task]?.status == "done" { continue }
            stage = task.title
            let started = Date()
            do {
                let detail: String
                switch task {
                case .transcribe: detail = try await transcribe(session)
                case .dedupe: detail = dedupe(session)
                case .translate: detail = try await translate(session)
                case .analyze: detail = try await analyze(session)
                }
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                store.setJob(session: id, task: task, status: detail.hasPrefix("跳过") ? "skipped" : "done",
                             detail: "\(detail)，用时 \(seconds) 秒")
                Log.write("会后处理 · \(task.title)：\(detail)，用时 \(seconds) 秒")
            } catch {
                store.setJob(session: id, task: task, status: "failed", detail: "\(error)")
                Log.write("会后处理 · \(task.title)失败：\(error)")
                return
            }
            revision += 1
        }
        Log.write("会后处理完成，总用时 \(Int(Date().timeIntervalSince(began))) 秒")
    }

    // MARK: - 1. 重新转写

    private func transcribe(_ session: SessionInfo) async throws -> String {
        guard let store else { return "跳过" }
        let files = FileManager.default
        guard files.fileExists(atPath: session.systemFile.path) else { throw AppError("找不到系统声音的录音文件") }
        let hasMic = files.fileExists(atPath: session.micFile.path)
        let terms = Terms.load()
        // --post-local：自测时强制走本地转写
        let key = CommandLine.arguments.contains("--post-local") ? nil : KeyStore.get("asr.assemblyai")
        let locale = session.mode.sourceLocale
        let chinese = session.mode == .zhToEn

        // 有 AssemblyAI 密钥就用云端(更准，还能分说话人)；没有密钥或云端失败时用本地
        @Sendable func run(_ file: URL, _ name: String, report: @escaping @Sendable (String) -> Void) async throws -> ([PostTranscriber.Piece], String) {
            if let key {
                do {
                    let pieces = try await PostTranscriber.cloud(file: file, apiKey: key, chinese: chinese, terms: terms,
                                                                 progress: report)
                    return (pieces, "云端")
                } catch {
                    Log.write("会后转写(\(name))：云端失败(\(error))，改用本地")
                }
            }
            report("本地转写中")
            return (try await PostTranscriber.local(file: file, locale: locale, terms: terms), "本地")
        }
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.stage = "重新转写 · \(text)" }
        }
        async let systemResult = run(session.systemFile, "系统声音", report: report)
        async let micResult: ([PostTranscriber.Piece], String)? = hasMic ? try? run(session.micFile, "麦克风", report: { _ in }) : nil
        let (system, route) = try await systemResult
        let mic = await micResult?.0 ?? []

        store.run("DELETE FROM utterance WHERE session_id = ?", [session.id])
        let speakers = Set(system.compactMap(\.speaker))
        for piece in system {
            let speaker = speakers.count > 1 ? "面试官 \(piece.speaker ?? "")" : "面试官"
            store.insertUtterance(session: session.id, channel: "system", speaker: speaker,
                                  startMs: piece.startMs, endMs: piece.endMs, text: piece.text)
        }
        // 麦克风录音开始得比系统声音晚一点，换算到同一条时间轴上
        let offset = session.micOffsetMs
        for piece in mic {
            store.insertUtterance(session: session.id, channel: "mic", speaker: "我",
                                  startMs: piece.startMs + offset, endMs: piece.endMs + offset, text: piece.text)
        }
        return "\(route)，面试官 \(system.count) 段(\(max(speakers.count, 1)) 位说话人)，我 \(mic.count) 段"
    }

    // MARK: - 2. 回声去重

    /// 不戴耳机时麦克风会把对方的声音也录进去：麦克风里和系统声音同一时间、内容基本相同的发言删掉
    private func dedupe(_ session: SessionInfo) -> String {
        guard let store else { return "跳过" }
        let all = store.utterances(session: session.id)
        let system = all.filter { $0.channel == "system" }
        var removed = 0
        for mine in all where mine.channel == "mic" {
            let nearby = system.filter { $0.startMs < mine.endMs + 2000 && $0.endMs > mine.startMs - 2000 }
            guard !nearby.isEmpty else { continue }
            let theirs = Self.tokens(nearby.map(\.text).joined(separator: " "))
            // 一段发言里可能前半是回声、后半是我自己说的，所以逐句判断
            let sentences = Self.sentences(mine.text)
            let kept = sentences.filter { sentence in
                let tokens = Self.tokens(sentence)
                guard tokens.count >= 4 else { return true }
                return Double(Self.commonSubsequence(tokens, theirs)) / Double(tokens.count) < 0.8
            }
            guard kept.count < sentences.count else { continue }
            // 剩下的只有零碎的短句(不到 4 个词)时，整段都算回声
            if kept.allSatisfy({ Self.tokens($0).count < 4 }) {
                store.run("DELETE FROM utterance WHERE id = ?", [mine.id])
            } else {
                store.run("UPDATE utterance SET text = ? WHERE id = ?",
                          [kept.joined(separator: session.mode == .enToZh ? " " : ""), mine.id])
            }
            removed += sentences.count - kept.count
        }
        return "删除回声 \(removed) 句"
    }

    /// 按句末标点切成句子(标点留在句子里)
    nonisolated static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!。？！".contains(character) {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result.filter { !$0.isEmpty }
    }

    /// 英文按单词、中文按字切开，忽略大小写和标点
    nonisolated static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if character.unicodeScalars.first.map({ $0.value >= 0x2E80 }) == true {
                    if !word.isEmpty { result.append(word); word = "" }
                    result.append(String(character))
                } else {
                    word.append(character)
                }
            } else if !word.isEmpty {
                result.append(word)
                word = ""
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    /// 最长公共子序列的长度
    nonisolated static func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - 3. 全文翻译

    private func translate(_ session: SessionInfo) async throws -> String {
        guard let store else { return "跳过" }
        guard let llm = answers.llmLine.makeClient() else { return "跳过：没有填写大模型密钥" }
        let utterances = store.utterances(session: session.id)
        guard !utterances.isEmpty else { return "跳过：没有内容" }
        let target = session.mode == .enToZh ? "简体中文" : "英文"
        let terms = Terms.load()
        let system = """
        你在翻译一场面试的文字记录。把用户给出的每一行翻译成\(target)。
        规则：
        - 每行以"编号|"开头。输出时每行也是"编号|译文"，编号和输入一一对应，不要合并、拆分或漏掉任何一行。
        - 技术名词、产品名、公司名、缩写保留原文，不要翻译。
        - 口语里的填充词(um、you know、那个)省略，译文要通顺。
        - 只输出译文行，不要输出其他内容。
        \(terms.isEmpty ? "" : "下面这些专有名词如果在原文里出现，请保持原样；原文里没有的不要换进去：\(terms.prefix(60).joined(separator: "、"))")
        """
        // 按字数分批，几批同时翻
        var batches: [[(Int, Utterance)]] = [[]]
        var size = 0
        for (index, utterance) in utterances.enumerated() {
            if size > 2500 || batches[batches.count - 1].count >= 25 {
                batches.append([])
                size = 0
            }
            batches[batches.count - 1].append((index, utterance))
            size += utterance.text.count
        }
        let total = batches.count
        var finished = 0
        var translated = 0
        try await withThrowingTaskGroup(of: [(Int64, String)].self) { group in
            var next = 0
            func addNext() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask {
                    let user = batch.map { "\($0.0)|\($0.1.text.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
                    let reply = try await llm.complete(system: system, user: user, tier: .strong)
                    var byIndex: [Int: String] = [:]
                    for line in reply.split(separator: "\n") {
                        guard let bar = line.firstIndex(of: "|"),
                              let index = Int(line[..<bar].trimmingCharacters(in: .whitespaces)) else { continue }
                        byIndex[index] = line[line.index(after: bar)...].trimmingCharacters(in: .whitespaces)
                    }
                    return batch.compactMap { item in byIndex[item.0].map { (item.1.id, $0) } }
                }
            }
            for _ in 0..<3 { addNext() }
            for try await pairs in group {
                for (id, text) in pairs where !text.isEmpty {
                    store.run("UPDATE utterance SET translation = ? WHERE id = ?", [text, id])
                    translated += 1
                }
                finished += 1
                stage = "全文翻译 \(finished)/\(total)"
                addNext()
            }
        }
        return "翻译 \(translated)/\(utterances.count) 段"
    }

    // MARK: - 4. 问答配对、评价、纪要

    private func analyze(_ session: SessionInfo) async throws -> String {
        guard let store else { return "跳过" }
        guard let llm = answers.llmLine.makeClient() else { return "跳过：没有填写大模型密钥" }
        let utterances = store.utterances(session: session.id)
        guard !utterances.isEmpty else { return "跳过：没有内容" }
        let transcript = utterances.enumerated().map { "[\($0.offset)] \($0.element.speaker)：\($0.element.text)" }.joined(separator: "\n")
        let hasMine = utterances.contains { $0.channel == "mic" }

        // 第一步：配对
        stage = "问答配对"
        let pairingSystem = """
        下面是一场面试的文字记录，每行格式是"[编号] 说话人：内容"。"我"是候选人，其余是面试官。
        找出其中所有的问答：面试官向候选人提的问题(包括追问)，以及候选人向面试官提的问题(反问环节)。寒暄和过渡语不算；面试官问"你有什么想问我们的吗"这类邀请候选人提问的话也不算一道题，它只是反问环节的开场。
        只输出一个 JSON 数组，不要输出其他内容。每个元素是：
        {"q": "问题原文，整理成一句通顺的话，保持原来的语言", "kind": "行为|技术|系统设计|项目|反问|其他", "q_at": 提问所在行的编号, "a_from": 回答开始行的编号, "a_to": 回答结束行的编号}
        没有人回答的问题，a_from 和 a_to 都写 -1。
        """
        let pairingReply = try await llm.complete(system: pairingSystem, user: transcript, tier: .strong)
        guard let open = pairingReply.firstIndex(of: "["), let close = pairingReply.lastIndex(of: "]"),
              let data = String(pairingReply[open...close]).data(using: .utf8),
              let pairs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AppError("问答配对的结果无法解析：\(pairingReply.prefix(160))")
        }

        struct Pair {
            var question: String
            var kind: String
            var askedMs: Int
            var answer: String
            var suggested: String
        }
        let realtime = store.realtimeQA(session: session.id)
        func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? -1 }
        let prepared: [Pair] = pairs.compactMap { item in
            guard let question = item["q"] as? String, !question.isEmpty else { return nil }
            let kind = item["kind"] as? String ?? "其他"
            let at = min(max(number(item["q_at"]), 0), utterances.count - 1)
            let from = number(item["a_from"]), to = number(item["a_to"])
            var answer = ""
            if from >= 0, to >= from, from < utterances.count {
                let range = utterances[from...min(to, utterances.count - 1)]
                // 普通问题只取我说的话；反问取面试官的回答
                let wanted = kind == "反问" ? range.filter { $0.channel == "system" } : range.filter { $0.channel == "mic" }
                answer = wanted.map(\.text).joined(separator: session.mode == .enToZh ? " " : "")
            }
            // 会中给过的建议答案：按时间找离这个问题最近的一条
            let asked = utterances[at]
            let suggested = realtime
                .filter { $0.askedMs >= asked.startMs - 3000 && $0.askedMs <= asked.endMs + 15000 }
                .min { abs($0.askedMs - asked.endMs) < abs($1.askedMs - asked.endMs) }?.suggested ?? ""
            return Pair(question: question, kind: kind, askedMs: asked.startMs, answer: answer, suggested: suggested)
        }

        // 第二步：逐题评价，几题同时进行
        let resume = answers.resume.text(for: session.mode)
        let jd = answers.resume.jd
        let language = session.mode == .enToZh ? "英文" : "中文"
        let evaluationSystem = """
        你是资深面试教练，在帮候选人复盘一场面试。下面给出一个面试问题、候选人当时的回答，以及候选人的简历。
        文字记录来自语音识别，可能有同音错字(尤其是专有名词)：按最合理的意思理解，不要把识别错误当成候选人的发音或表达问题。
        严格按下面四个小标题输出，不要输出其他内容：
        ## 评分
        一个 1 到 5 的整数(5 最好)。候选人没有回答时写 0。
        ## 评价
        用中文，2–4 句话，具体指出回答的优点和问题(内容是否切题、结构、深度、有没有用上简历里的亮点)。候选人没有回答时写"没有录到回答"。
        ## 改进建议
        用中文，2–4 条，每条一行，以"- "开头，要具体可执行。
        ## 参考答案
        用\(language)写一段候选人可以直接说的回答(\(session.mode == .enToZh ? "120–180 个单词" : "250–350 个字"))，第一人称。
        只引用简历里真实存在的经历、项目和数字，不得编造，每件事都要说对是在哪家公司做的；简历里没有的具体情节用方括号占位，例如"[补充：当时的分歧是什么]"。

        <resume>
        \(resume.isEmpty ? "(候选人没有提供简历)" : resume)
        </resume>

        <jd>
        \(jd.isEmpty ? "(没有提供岗位描述)" : jd)
        </jd>
        """
        var items = [QAItem?](repeating: nil, count: prepared.count)
        var finished = 0
        await withTaskGroup(of: (Int, QAItem).self) { group in
            var next = 0
            func addNext() {
                guard next < prepared.count else { return }
                let index = next
                let pair = prepared[index]
                next += 1
                group.addTask {
                    var item = QAItem(id: 0, idx: index, question: pair.question, kind: pair.kind, askedMs: pair.askedMs,
                                      myAnswer: pair.answer, suggested: pair.suggested, evaluation: "", reference: "", score: 0)
                    // 反问不评价
                    guard pair.kind != "反问" else { return (index, item) }
                    let user = "面试问题：\n\(pair.question)\n\n候选人的回答：\n\(pair.answer.isEmpty ? "(没有录到回答)" : pair.answer)"
                    do {
                        let reply = try await llm.complete(system: evaluationSystem + L10n.shared.promptNote, user: user, tier: .strong)
                        let sections = Self.sections(reply)
                        item.score = Int(sections["评分"]?.filter(\.isNumber).prefix(1) ?? "") ?? 0
                        let advice = sections["改进建议"] ?? ""
                        item.evaluation = (sections["评价"] ?? "") + (advice.isEmpty ? "" : "\n\n**改进建议**\n\(advice)")
                        item.reference = sections["参考答案"] ?? ""
                    } catch {
                        Log.write("第 \(index + 1) 题评价失败：\(error)")
                        item.evaluation = "评价生成失败：\(error)"
                    }
                    return (index, item)
                }
            }
            for _ in 0..<4 { addNext() }
            for await (index, item) in group {
                items[index] = item
                finished += 1
                stage = "逐题评价 \(finished)/\(prepared.count)"
                addNext()
            }
        }
        store.run("DELETE FROM qa_item WHERE session_id = ?", [session.id])
        let done = items.compactMap { $0 }
        for item in done { store.insertQAItem(session: session.id, item) }

        // 第三步：纪要
        stage = "生成纪要"
        let summarySystem = """
        你是资深面试教练，在帮候选人复盘一场面试。根据下面的面试记录和逐题评分，用中文写一份复盘纪要。
        第一行输出"标题：" 加一个不超过 20 个字的标题，写出岗位和主要话题(例如"前端工程师：BI 平台与性能优化")，不要带"复盘""纪要"这类字眼。
        之后用 Markdown，按这几个二级标题写，每部分用简短的列表：
        ## 面试概要
        ## 表现亮点
        ## 主要问题
        ## 待跟进事项
        只根据记录里实际出现的内容写，不要编造。记录来自语音识别，可能有同音错字：按最合理的意思理解，不要把识别错误当成候选人的发音或表达问题，也不要在纪要里提识别错误。\(hasMine ? "" : "这场没有录到候选人自己的发言，只总结面试官问了什么，并在主要问题一节里说明这一点。")
        """
        let scores = done.filter { $0.kind != "反问" }.map { "- [\($0.kind)] \($0.question)(评分 \($0.score == 0 ? "无" : String($0.score)))" }
            .joined(separator: "\n")
        let summaryReply = try await llm.complete(system: summarySystem + L10n.shared.promptNote,
                                                  user: "<transcript>\n\(transcript)\n</transcript>\n\n<scores>\n\(scores)\n</scores>",
                                                  tier: .strong)
        var lines = summaryReply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("标题") {
            let title = first.drop { $0 != "：" && $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            if !title.isEmpty, session.title.isEmpty { store.setTitle(session: session.id, title: title) }
            lines.removeFirst()
        }
        store.setSummary(session: session.id, markdown: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        return "问答 \(done.count) 组，纪要已生成"
    }

    /// 把"## 小标题"分隔的回复拆成 [小标题: 内容]
    nonisolated static func sections(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var buffer: [String] = []
        func flush() {
            if let current { result[current] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                current = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }
}
