import AVFoundation
import Foundation

/// 音频时钟：记录已经送进转写的音频总长和最后一块音频到达的时刻。
/// 采集启动后头一秒左右没有音频，所以不能用"会话开始时刻"去推算延迟。
final class AudioClock: @unchecked Sendable {
    private let sampleRate: Double
    private let lock = NSLock()
    private var frames = 0
    private var lastBufferAt = Date()

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func add(frames count: Int) {
        lock.lock()
        frames += count
        lastBufferAt = Date()
        lock.unlock()
    }

    /// 音频时间轴上 audioMs 这个位置的声音，到现在过去了多少毫秒
    func lagMs(audioMs: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let fedMs = Double(frames) / sampleRate * 1000
        return Int(fedMs - Double(audioMs) + Date().timeIntervalSince(lastBufferAt) * 1000)
    }
}

/// 一场会话的实时管线：采集 → 转写 → 翻译 → 字幕，同时录音和落库。
@MainActor
final class SessionController: ObservableObject {
    @Published var lines: [SubtitleLine] = []
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var status = "未开始"
    @Published var mode: LanguageMode = .enToZh
    @Published var line: ASRLine = .initial {
        didSet { UserDefaults.standard.set(line.rawValue, forKey: "asrLine") }
    }
    @Published var recordMic = true
    @Published var translationNeedsDownload = false

    /// 中间结果的临时翻译最小间隔。本地翻译很快，可以较频繁；大模型线路应调大。
    var provisionalInterval: TimeInterval = 1.0

    private let tap = SystemAudioTap()
    private let mic = MicRecorder()
    private var asr: ASRProvider?
    private var translator: TranslationProvider?
    private var systemRecorder: AudioFileRecorder?
    private var store: Store?
    private var sessionID: Int64 = -1
    private var audioStartedAt = Date()
    private var clock = AudioClock(sampleRate: 48_000)

    private var eventsTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var translationTasks: [Task<Void, Never>] = []
    private var nextLineID = 0
    private var openLineID: Int?
    private var lastProvisionalAt = Date.distantPast
    private var provisionalInFlight = false
    private var partialLagsMs: [Int] = []
    private let maxLinesInMemory = 60

    // MARK: - 启动与停止

    func start() async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = "正在准备…"
        lines = []
        openLineID = nil

        do {
            if store == nil { store = try Store(url: AppPaths.database) }

            // 翻译：语言包没装时仍然可以只转写
            let appleTranslator = AppleTranslator(source: mode.sourceLanguage, target: mode.targetLanguage)
            switch await appleTranslator.prepare() {
            case .ready:
                translator = appleTranslator
                translationNeedsDownload = false
            case .needsDownload:
                translator = nil
                translationNeedsDownload = true
                Log.write("翻译语言包未安装，本次只转写。请在主窗口点\"下载翻译语言包\"。")
            case .unsupported:
                translator = nil
                Log.write("系统不支持该语言对的本地翻译，本次只转写。")
            }

            let asr: ASRProvider
            if let account = line.keyAccount {
                guard let key = KeyStore.get(account) else {
                    throw AppError("还没有填写\(line.title)的 API Key，请在主窗口填入并保存")
                }
                status = "正在连接云端转写…"
                switch line {
                case .deepgram: asr = DeepgramASR(apiKey: key)
                case .assemblyai: asr = AssemblyAIASR(apiKey: key)
                default: asr = AliyunASR(apiKey: key)
                }
            } else {
                status = "正在加载转写模型(首次可能要一分钟)…"
                asr = AppleSpeechASR()
            }
            Log.write("转写线路：\(line.title)")
            try await asr.start(locale: mode.sourceLocale)
            self.asr = asr

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let dir = AppPaths.sessions.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            sessionID = store?.createSession(mode: mode.rawValue, dir: dir.path) ?? -1

            // 系统声音：采集后同时送去录音和转写
            // 放到后台线程：系统权限弹窗没处理时，这一步会阻塞很久
            status = "正在启动系统声音采集(如有权限弹窗请点允许)…"
            let tap = self.tap
            let format = try await Task.detached { try tap.start() }.value
            let recorder = try AudioFileRecorder(url: dir.appendingPathComponent("system.m4a"), format: format)
            systemRecorder = recorder
            audioStartedAt = Date()
            let clock = AudioClock(sampleRate: format.sampleRate)
            self.clock = clock
            tap.onBuffer = { buffer in
                clock.add(frames: Int(buffer.frameLength))
                recorder.write(buffer)
                asr.feed(buffer)
            }
            Log.write("系统声音采集已启动：\(Int(format.sampleRate)) Hz，\(format.channelCount) 声道")

            // 麦克风：只录音
            var micStartedAt: Date?
            if recordMic {
                if await MicRecorder.requestPermission() {
                    do {
                        try mic.start(url: dir.appendingPathComponent("mic.m4a"))
                        micStartedAt = mic.startedAt
                    } catch {
                        Log.write("麦克风录音未启动：\(error)")
                    }
                } else {
                    Log.write("没有麦克风权限，本次不录麦克风")
                }
            }
            store?.setAudioStart(session: sessionID, system: audioStartedAt, mic: micStartedAt)

            eventsTask = Task { [weak self] in
                for await event in asr.events { self?.handle(event) }
            }
            // 每 5 秒检查一次音量，长时间静音时提醒(可能是没授权，或对方确实没说话)
            levelTask = Task { [weak self] in
                var silentChecks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    let peak = self.tap.takePeak()
                    if peak >= 0.0005 {
                        silentChecks = 0
                    } else {
                        silentChecks += 1
                        // 连续 15 秒静音时提醒一次
                        if silentChecks == 3 {
                            Log.write("系统声道已连续 15 秒静音。如果对方正在说话，请到 系统设置 → 隐私与安全性 → "
                                      + "屏幕与系统音频录制 里允许本应用录制系统音频，然后重新开始。")
                            self.status = "没有采到声音，请检查系统音频录制权限"
                        }
                    }
                }
            }
            isRunning = true
            status = translator == nil ? "正在听(仅转写)" : "正在听译"
            Log.write("会话开始：\(mode.title)，目录 \(dir.lastPathComponent)")
        } catch {
            status = "启动失败：\(error)"
            Log.write("启动失败：\(error)")
            await teardown()
        }
    }

    func stop() async {
        guard isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = "正在结束…"
        await teardown()
        isRunning = false
        status = "已结束"
        Log.write("会话结束")
    }

    private func teardown() async {
        levelTask?.cancel()
        levelTask = nil
        let tap = self.tap
        await Task.detached { tap.stop() }.value
        tap.onBuffer = nil
        mic.stop()
        await asr?.stop()            // 收尾，吐出最后的定稿结果
        await eventsTask?.value
        for task in translationTasks { await task.value }
        translationTasks = []
        eventsTask = nil
        asr = nil
        systemRecorder?.close()
        systemRecorder = nil
        if sessionID >= 0 { store?.endSession(sessionID) }
        sessionID = -1
    }

    // MARK: - 转写事件

    private func handle(_ event: ASREvent) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch event.kind {
        case .partial:
            guard !text.isEmpty else { return }
            if event.endMs >= 0 { partialLagsMs.append(clock.lagMs(audioMs: event.endMs)) }
            if let id = openLineID, let index = lines.firstIndex(where: { $0.id == id }) {
                lines[index].source = text
            } else {
                openLineID = appendLine(source: text)
                Log.write("首个中间结果 [音频位置 \(event.startMs)–\(event.endMs) ms] \(text)")
            }
            translateProvisionally()

        case .final:
            let lineID: Int
            if let id = openLineID, lines.contains(where: { $0.id == id }) {
                lineID = id
            } else if !text.isEmpty {
                lineID = appendLine(source: text)
            } else {
                return
            }
            openLineID = nil
            guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
            if text.isEmpty {
                lines.remove(at: index)
                return
            }
            lines[index].source = text
            lines[index].isFinal = true

            let segmentID = store?.insertSegment(session: sessionID, channel: "system",
                                                 startMs: event.startMs, endMs: event.endMs,
                                                 lang: mode.sourceLanguage.minimalIdentifier, text: text) ?? -1
            lines[index].segmentID = segmentID

            // 定稿延迟：这句话说完到定稿结果出来过了多久
            let lagMs = clock.lagMs(audioMs: event.endMs)
            // 中间结果延迟：原文上屏比说话慢多少(取本句各次中间结果的中位数)
            let sorted = partialLagsMs.sorted()
            let partialLag = sorted.isEmpty ? "无" : "\(sorted[sorted.count / 2]) ms"
            partialLagsMs = []
            Log.write("定稿 [\(event.startMs)–\(event.endMs) ms，定稿延迟 \(lagMs) ms，中间结果延迟 \(partialLag)] \(text)")
            translateFinal(lineID: lineID, segmentID: segmentID, text: text)
        }
    }

    private func appendLine(source: String) -> Int {
        let id = nextLineID
        nextLineID += 1
        lines.append(SubtitleLine(id: id, source: source))
        if lines.count > maxLinesInMemory { lines.removeFirst(lines.count - maxLinesInMemory) }
        return id
    }

    // MARK: - 翻译

    /// 定稿句段的翻译：结果上屏后不再改动
    private func translateFinal(lineID: Int, segmentID: Int64, text: String) {
        guard let translator else { return }
        let started = Date()
        let task = Task { [weak self] in
            do {
                let translation = try await translator.translate(text)
                guard let self else { return }
                if let index = self.lines.firstIndex(where: { $0.id == lineID }) {
                    self.lines[index].translation = translation
                    self.lines[index].translationIsProvisional = false
                }
                if segmentID >= 0 { self.store?.setTranslation(segment: segmentID, translation: translation) }
                Log.write("译文 [耗时 \(Int(Date().timeIntervalSince(started) * 1000)) ms] \(translation)")
            } catch {
                Log.write("翻译失败：\(error)")
            }
        }
        translationTasks.append(task)
        translationTasks.removeAll { $0.isCancelled }
        if translationTasks.count > 200 { translationTasks.removeFirst(100) }
    }

    /// 句子还没说完时的临时翻译：淡色显示，定稿后被正式译文替换
    private func translateProvisionally() {
        guard let translator, !provisionalInFlight,
              Date().timeIntervalSince(lastProvisionalAt) >= provisionalInterval,
              let lineID = openLineID,
              let line = lines.first(where: { $0.id == lineID }) else { return }
        let text = line.source
        // 只有一两个词时翻出来多半是错的(例如 "Let" 被译成"擦网球")，等内容多一点再翻
        let enough = mode == .enToZh ? text.split(separator: " ").count >= 3 : text.count >= 4
        guard enough else { return }
        provisionalInFlight = true
        lastProvisionalAt = Date()
        Task { [weak self] in
            let translation = try? await translator.translate(text)
            guard let self else { return }
            self.provisionalInFlight = false
            guard let translation,
                  let index = self.lines.firstIndex(where: { $0.id == lineID }),
                  !self.lines[index].isFinal else { return }
            if self.lines[index].translation.isEmpty { Log.write("临时译文 \(translation)") }
            self.lines[index].translation = translation
            self.lines[index].translationIsProvisional = true
        }
    }
}
