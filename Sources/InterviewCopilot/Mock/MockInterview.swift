import AVFoundation
import Foundation

/// 模拟面试的设置
struct MockConfig {
    enum Level: String, CaseIterable, Identifiable {
        case junior = "初级", mid = "中级", senior = "高级", staff = "资深或负责人"
        var id: String { rawValue }
    }

    var chinese = false          // 面试语言：false 英文，true 中文
    var level: Level = .senior
    var questionCount = 5
    var maxFollowUps = 2         // 每道题最多追问几轮
    var pauseAfterFeedback = true
}

/// 一问一答。追问也是一个回合，挂在它所属的那道题下面。
struct MockTurn: Identifiable {
    let id: Int
    var number: Int              // 第几道题(从 1 开始)
    var followUp: Int            // 0 是主问题，1、2 是第几轮追问
    var kind: String
    var question: String
    var answer = ""
    var feedback = ""
}

/// 模拟面试：出题 → 朗读 → 听我回答 → 点评并追问 → 下一题，结束后走会后处理生成复盘。
@MainActor
final class MockInterview: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, asking, answering, reviewing, waiting, wrappingUp, finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = ""
    @Published private(set) var turns: [MockTurn] = []
    @Published private(set) var liveAnswer = ""
    @Published private(set) var total = 0
    @Published private(set) var sessionID: Int64?
    @Published private(set) var reviewReady = false
    @Published var config = MockConfig()

    var isActive: Bool { phase != .idle && phase != .finished }

    private let answers: AnswerEngine
    private let resume: ResumeStore
    private let post: PostProcessor
    /// 真实面试正在进行时不能开始模拟面试
    var realSessionRunning: () -> Bool = { false }
    /// 沿用主窗口选的转写线路
    var asrLine: () -> ASRLine = { .auto }

    /// 自测用：不开麦克风和转写，按顺序把这些文字当作我的回答
    var scriptedAnswers: [String]?
    private var scriptedIndex = 0

    private let synth = SpeechSynth()
    private let engine = AVAudioEngine()
    private var recorder: AudioFileRecorder?
    private var asr: ASRProvider?
    private var eventsTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var startedAt = Date()
    private var dir: URL?
    private var clips: [(startMs: Int, clip: SpeechSynth.Clip)] = []
    private var prefetched: [String: Task<SpeechSynth.Clip?, Never>] = [:]

    // 当前这次作答
    private var finals: [String] = []
    private var partial = ""
    private var answerStartMs = 0
    private var finishSignal: CheckedContinuation<Void, Never>?
    private var continueSignal: CheckedContinuation<Void, Never>?
    private var skipRequested = false
    private var endRequested = false

    init(answers: AnswerEngine, resume: ResumeStore, post: PostProcessor) {
        self.answers = answers
        self.resume = resume
        self.post = post
    }

    private var mode: LanguageMode { config.chinese ? .zhToEn : .enToZh }
    private var nowMs: Int { Int(Date().timeIntervalSince(startedAt) * 1000) }
    private var languageName: String { config.chinese ? "中文" : "英文" }

    // MARK: - 对外的操作

    func start() {
        guard !isActive else { return }
        guard !realSessionRunning() else {
            status = "真实面试正在进行，结束后才能开始模拟面试"
            return
        }
        guard let llm = answers.llmLine.makeClient() else {
            status = "还没有填写\(answers.llmLine.title)的密钥，无法出题"
            return
        }
        turns = []
        scriptedIndex = 0
        liveAnswer = ""
        clips = []
        prefetched = [:]
        skipRequested = false
        endRequested = false
        reviewReady = false
        sessionID = nil
        phase = .preparing
        runTask = Task { await run(llm) }
    }

    /// 这道题答完了
    func finishAnswer() {
        guard phase == .answering else { return }
        finishSignal?.resume()
        finishSignal = nil
    }

    /// 跳过当前这道题(连同它的追问)
    func skip() {
        guard phase == .answering || phase == .asking else { return }
        skipRequested = true
        synth.stop()
        finishAnswer()
    }

    /// 看完点评，继续
    func proceed() {
        continueSignal?.resume()
        continueSignal = nil
    }

    /// 重新朗读当前的问题
    func repeatQuestion() {
        guard phase == .answering, let turn = turns.last else { return }
        Task {
            await speak(turn.question, record: false)
            // 重听期间麦克风收到的是朗读声，作答从现在重新算起
            resetAnswer()
        }
    }

    /// 回到开始前的设置页
    func reset() {
        guard phase == .finished else { return }
        turns = []
        status = ""
        phase = .idle
    }

    /// 提前结束整场模拟面试
    func end() {
        guard isActive, phase != .wrappingUp else { return }
        endRequested = true
        synth.stop()
        finishSignal?.resume()
        finishSignal = nil
        proceed()
    }

    // MARK: - 主流程

    private func run(_ llm: LLMClient) async {
        do {
            status = "正在出题…"
            let questions = try await makeQuestions(llm)
            total = questions.count
            Log.write("模拟面试：\(languageName)，\(config.level.rawValue)，出题 \(questions.count) 道")

            status = "正在打开麦克风和转写…"
            try await startAudio()
            // 提前把后面几道题的语音合成好，问的时候不用等
            for (question, _) in questions { prefetch(question) }

            for (index, item) in questions.enumerated() where !endRequested {
                var turn = MockTurn(id: turns.count, number: index + 1, followUp: 0, kind: item.kind, question: item.question)
                while !endRequested {
                    turns.append(turn)
                    let answer = await ask(turn.question)
                    if skipRequested || endRequested {
                        skipRequested = false
                        break
                    }
                    turns[turns.count - 1].answer = answer
                    phase = .reviewing
                    status = "正在点评…"
                    let thread = turns.filter { $0.number == turn.number }
                    let review = await self.review(llm, thread: thread, canFollowUp: turn.followUp < config.maxFollowUps)
                    turns[turns.count - 1].feedback = review.feedback
                    Log.write("模拟面试 第 \(turn.number) 题\(turn.followUp > 0 ? " 追问 \(turn.followUp)" : "")：回答 \(answer.count) 字，\(review.followUp.isEmpty ? "不追问" : "追问")")
                    if !review.followUp.isEmpty { prefetch(review.followUp) }
                    if config.pauseAfterFeedback, !endRequested {
                        phase = .waiting
                        status = "看完点评后点\"继续\""
                        await withCheckedContinuation { continueSignal = $0 }
                    }
                    guard !review.followUp.isEmpty else { break }
                    turn = MockTurn(id: turns.count, number: turn.number, followUp: turn.followUp + 1, kind: turn.kind,
                                    question: review.followUp)
                }
            }
            await wrapUp()
        } catch {
            Log.write("模拟面试出错：\(error)")
            status = "出错了：\(error)"
            await stopAudio()
            phase = .idle
        }
    }

    /// 朗读问题，然后等用户答完，返回转写出来的回答
    private func ask(_ question: String) async -> String {
        phase = .asking
        status = "面试官正在提问…"
        liveAnswer = ""
        if let id = sessionID {
            _ = Store.shared?.insertSegment(session: id, channel: "system", startMs: nowMs, endMs: nowMs,
                                            lang: config.chinese ? "zh" : "en", text: question)
        }
        await speak(question, record: true)
        guard !skipRequested, !endRequested else { return "" }

        resetAnswer()
        phase = .answering
        if let scripted = scriptedAnswers, !scripted.isEmpty {
            liveAnswer = scripted[scriptedIndex % scripted.count]
            scriptedIndex += 1
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return liveAnswer
        }
        status = "请作答，答完点\"答完了\"或按回车"
        await withCheckedContinuation { finishSignal = $0 }
        guard !skipRequested, !endRequested else { return "" }

        // 最后半句可能还没定稿：最多等 1.5 秒
        status = "正在收尾…"
        for _ in 0..<15 where !partial.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
        return currentAnswer()
    }

    private func resetAnswer() {
        finals = []
        partial = ""
        liveAnswer = ""
        answerStartMs = nowMs
    }

    private func currentAnswer() -> String {
        (finals + (partial.isEmpty ? [] : [partial])).joined(separator: config.chinese ? "" : " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prefetch(_ text: String) {
        guard prefetched[text] == nil, let key = KeyStore.get(LLMLine.qwen.keyAccount) else { return }
        let chinese = config.chinese
        prefetched[text] = Task.detached {
            do { return try await SpeechSynth.synthesize(text, chinese: chinese, apiKey: key) } catch {
                Log.write("语音合成失败，改用系统语音：\(error)")
                return nil
            }
        }
    }

    /// 读一段话。record 为 true 时把这段语音记进面试官的音轨。
    private func speak(_ text: String, record: Bool) async {
        prefetch(text)
        if let clip = await prefetched[text]?.value {
            if record { clips.append((nowMs, clip)) }
            await synth.play(clip)
        } else {
            await synth.speakWithSystemVoice(text, chinese: config.chinese)
        }
    }

    // MARK: - 大模型：出题、点评和追问

    private var background: String {
        let resumeText = resume.text(for: mode)
        return """
        <resume>
        \(resumeText.isEmpty ? "(候选人没有提供简历)" : resumeText)
        </resume>

        <jd>
        \(resume.jd.isEmpty ? "(没有提供岗位描述，按简历里最近的岗位方向出题)" : resume.jd)
        </jd>
        """
    }

    private func makeQuestions(_ llm: LLMClient) async throws -> [(question: String, kind: String)] {
        let system = """
        你是一位经验丰富的面试官，要面试一位\(config.level.rawValue)级别的候选人。根据简历和岗位描述出 \(config.questionCount) 道面试题。
        要求：
        - 题目用\(languageName)，像面试官当面说话那样自然，每道题一两句话，不要带编号和题型前缀。
        - 题型搭配：行为题、技术题、项目深挖都要有；题目数量够多时加一道系统设计题。难度符合候选人级别。
        - 项目深挖题要点名简历里的具体项目或经历；技术题围绕岗位描述和简历里出现的技术。
        - 第一题用自我介绍或最近的项目开场。
        只输出一个 JSON 数组，每项是 {"q": "题目", "kind": "行为|技术|系统设计|项目"}，不要输出其他内容。
        """
        let reply = try await llm.complete(system: system, user: background, tier: .strong)
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"),
              let data = String(reply[start...end]).data(using: .utf8),
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AppError("出题结果无法解析：\(reply.prefix(120))")
        }
        let questions = items.compactMap { item -> (String, String)? in
            guard let q = (item["q"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return nil }
            return (q, item["kind"] as? String ?? "其他")
        }
        guard !questions.isEmpty else { throw AppError("没有出到题") }
        return Array(questions.prefix(config.questionCount))
    }

    private func review(_ llm: LLMClient, thread: [MockTurn], canFollowUp: Bool) async -> (feedback: String, followUp: String) {
        let system = """
        你是一位\(languageName)面试的面试官，同时也是候选人的面试教练。候选人是\(config.level.rawValue)级别。
        下面是一道题目前为止的问答，回答来自语音识别，可能有同音错字，不要把识别错误当成表达问题。
        做两件事：
        1. 针对最后一次回答写点评，用中文，三到五句：先说答得好的地方，再说最主要的问题，最后给一条具体的改进办法。回答是空的就直说没有听到回答。
        2. \(canFollowUp ? "像真实面试官那样决定要不要追问：回答里有值得深挖的细节、含糊的地方或没说到的关键点就追问一句，用\(languageName)，一两句话；答得已经充分或者没有回答就不追问。" : "这道题不再追问，followup 留空。")
        只输出一个 JSON 对象：{"feedback": "点评", "followup": "追问的问题，不追问就是空字符串"}，不要输出其他内容。
        """
        let dialogue = thread.map { "面试官：\($0.question)\n候选人：\($0.answer.isEmpty ? "(没有回答)" : $0.answer)" }.joined(separator: "\n\n")
        do {
            let reply = try await llm.complete(system: system, user: background + "\n\n<dialogue>\n\(dialogue)\n</dialogue>", tier: .strong)
            guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
                  let object = parseJSON(String(reply[start...end])) else {
                return (reply.trimmingCharacters(in: .whitespacesAndNewlines), "")
            }
            let followUp = canFollowUp ? (object["followup"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return (object["feedback"] as? String ?? "", followUp)
        } catch {
            return ("点评生成失败：\(error)", "")
        }
    }

    // MARK: - 麦克风和转写

    private func makeASR() -> ASRProvider {
        let terms = Terms.load()
        let makeLocal: () -> ASRProvider = { AppleSpeechASR(terms: terms) }
        // 主窗口选了具体的云端线路就用它；选"自动"时中文优先阿里云，英文优先海外线路
        var order: [ASRLine] = config.chinese ? [.aliyun, .assemblyai, .deepgram] : [.deepgram, .assemblyai, .aliyun]
        let chosen = asrLine()
        if chosen == .local { return makeLocal() }
        if chosen != .auto { order = [chosen] }
        for line in order {
            guard let account = line.keyAccount, let key = KeyStore.get(account) else { continue }
            Log.write("模拟面试转写线路：\(line.title)")
            return ResilientASR(name: line.title, makePrimary: {
                switch line {
                case .deepgram: return DeepgramASR(apiKey: key, terms: terms)
                case .assemblyai: return AssemblyAIASR(apiKey: key, terms: terms)
                default: return AliyunASR(apiKey: key)
                }
            }, makeFallback: makeLocal)
        }
        Log.write("模拟面试转写线路：本地")
        return makeLocal()
    }

    private func startAudio() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = AppPaths.sessions.appendingPathComponent(formatter.string(from: Date()) + "-mock", isDirectory: true)
        if scriptedAnswers != nil {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.dir = dir
            startedAt = Date()
            createSession(dir)
            return
        }
        guard await MicRecorder.requestPermission() else {
            throw AppError("没有麦克风权限，请在 系统设置 › 隐私与安全性 › 麦克风 里允许面试助手")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir

        let asr = makeASR()
        try await asr.start(locale: mode.sourceLocale)
        self.asr = asr
        eventsTask = Task { [weak self] in
            for await event in asr.events { self?.handle(event) }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppError("没有可用的麦克风输入") }
        let recorder = try AudioFileRecorder(url: dir.appendingPathComponent("mic.m4a"), format: format)
        self.recorder = recorder
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder.write(buffer)
            asr.feed(buffer)
        }
        try engine.start()
        startedAt = Date()

        createSession(dir)
    }

    private func createSession(_ dir: URL) {
        guard let store = Store.shared else { return }
        let id = store.createSession(mode: mode.rawValue, dir: dir.path)
        store.setAudioStart(session: id, system: startedAt, mic: startedAt)
        sessionID = id
    }

    private func stopAudio() async {
        synth.stop()
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recorder?.close()
        recorder = nil
        await asr?.stop()
        asr = nil
        eventsTask?.cancel()
        eventsTask = nil
    }

    private func handle(_ event: ASREvent) {
        guard phase == .answering || status == "正在收尾…" else { return }
        // 朗读问题时麦克风也在收音：开始作答之前的内容不算
        if event.endMs >= 0, event.endMs < answerStartMs { return }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch event.kind {
        case .partial:
            partial = text
        case .final:
            if !text.isEmpty { finals.append(text) }
            partial = ""
        }
        liveAnswer = currentAnswer()
    }

    // MARK: - 收尾：写录音，走会后处理

    private func wrapUp() async {
        phase = .wrappingUp
        status = "正在保存录音…"
        let totalMs = nowMs
        await stopAudio()
        guard let id = sessionID, let dir, let store = Store.shared else {
            phase = .finished
            return
        }
        store.endSession(id)
        let clips = self.clips
        do {
            try await Task.detached {
                try SpeechSynth.writeTrack(clips, totalMs: totalMs, to: dir.appendingPathComponent("system.m4a"))
            }.value
        } catch {
            Log.write("模拟面试：面试官音轨写入失败：\(error)")
        }
        let answered = turns.filter { !$0.answer.isEmpty }.count
        Log.write("模拟面试结束：共 \(turns.count) 个回合，其中作答 \(answered) 个，时长 \(totalMs / 1000) 秒")
        guard answered > 0 else {
            store.setTitle(session: id, title: "模拟面试(没有作答)")
            status = "没有作答，不生成复盘"
            phase = .finished
            return
        }
        status = "正在生成复盘(重新转写、翻译、评价和纪要)…"
        await post.process(id)
        // 标题前面标明是模拟面试，和真实面试区分开
        let title = store.session(id)?.title ?? ""
        store.setTitle(session: id, title: title.isEmpty ? "模拟面试" : "模拟 · " + title)
        reviewReady = store.jobs(session: id)[.analyze]?.status == "done"
        status = reviewReady ? "复盘已生成" : "复盘没有全部完成，可以在历史与复盘里继续处理"
        phase = .finished
    }
}
