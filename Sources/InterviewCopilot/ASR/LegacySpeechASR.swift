import AVFoundation
import Speech

/// macOS 27 以前的本地转写：系统的 SFSpeechRecognizer，尽量走本机离线识别。
/// 它一次识别请求只适合一小段话(官方建议一分钟以内)，所以在停顿处或满 50 秒时结束当前请求、马上开下一个，
/// 每个请求的结果就是一句字幕：识别中途发中间结果，请求结束时发最终结果。
final class LegacySpeechASR: ASRProvider {
    let events: AsyncStream<ASREvent>
    private let continuation: AsyncStream<ASREvent>.Continuation
    private let terms: [String]

    private var recognizer: SFSpeechRecognizer?
    private let queue = DispatchQueue(label: "copilot.asr.legacy", qos: .userInteractive)
    // 下面这些只在 queue 上读写
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 已经结束音频、还在等最终结果的请求；得留着引用，提前释放会被系统当成取消
    private var finishing: [ObjectIdentifier: SFSpeechRecognitionTask] = [:]
    private var requestStartMs = 0      // 当前请求开始时的音频位置
    private var requestBegan = Date()
    private var fedMs = 0.0             // 已经喂进去的音频总时长
    private var lastText = ""
    private var lastChange = Date()
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(terms: [String]) {
        self.terms = terms
        (events, continuation) = AsyncStream<ASREvent>.makeStream()
    }

    func start(locale: Locale) async throws {
        let locale = locale.singleLanguage
        let status = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard status == .authorized else { throw AppError(L("没有语音识别权限：请在系统设置 › 隐私与安全性 › 语音识别里允许千人千面")) }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppError("本地转写不支持语言 \(locale.identifier)")
        }
        recognizer.defaultTaskHint = .dictation
        self.recognizer = recognizer
        Log.write("本地转写：SFSpeechRecognizer，\(recognizer.supportsOnDeviceRecognition ? "本机离线" : "需要联网")")
        queue.sync { beginRequest() }

        // 每 0.3 秒看一次：说话停了 1.2 秒或这一段满 50 秒，就结束这一句
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let pause = !self.lastText.isEmpty && Date().timeIntervalSince(self.lastChange) > 1.2
            if pause || Date().timeIntervalSince(self.requestBegan) > 50 { self.rotate() }
        }
        timer.resume()
        self.timer = timer
    }

    /// 在 queue 上调用：开一个新的识别请求
    private func beginRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.contextualStrings = Array(terms.prefix(100))
        let startMs = Int(fedMs)
        requestStartMs = startMs
        requestBegan = Date()
        lastText = ""
        lastChange = Date()
        self.request = request
        var latest = ""          // 这个请求最近一次的中间结果
        var done = false
        var newTask: SFSpeechRecognitionTask?
        newTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, !done else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let segments = result.bestTranscription.segments
                let begin = startMs + Int((segments.first?.timestamp ?? 0) * 1000)
                let end = startMs + Int(((segments.last.map { $0.timestamp + $0.duration }) ?? 0) * 1000)
                if result.isFinal {
                    done = true
                    self.continuation.yield(ASREvent(kind: .final, text: text, startMs: begin, endMs: end))
                } else {
                    latest = text
                    self.queue.async {
                        if text != self.lastText { self.lastText = text; self.lastChange = Date() }
                    }
                    self.continuation.yield(ASREvent(kind: .partial, text: text, startMs: begin, endMs: end))
                }
            } else if error != nil {
                // 这一段没人说话也会报错，是正常的；有半句的话按半句定稿
                done = true
                if !latest.isEmpty {
                    self.continuation.yield(ASREvent(kind: .final, text: latest, startMs: startMs, endMs: Int(self.fedMs)))
                }
            }
            if done, let finished = newTask {
                self.queue.async { self.finishing[ObjectIdentifier(finished)] = nil }
            }
        }
        task = newTask
    }

    /// 在 queue 上调用：结束当前请求(它会发出最终结果)，后面的音频喂给新请求
    private func rotate() {
        request?.endAudio()
        request = nil
        if let task { finishing[ObjectIdentifier(task)] = task }
        task = nil
        if !stopped { beginRequest() }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.request?.append(buffer)
            self.fedMs += Double(buffer.frameLength) / buffer.format.sampleRate * 1000
        }
    }

    func stop() async {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            request?.endAudio()
            request = nil
        }
        // 等最后一句的结果，最多 3 秒
        for _ in 0..<30 {
            if queue.sync(execute: { (task?.state == .completed || task == nil) && finishing.isEmpty }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        queue.sync {
            task?.cancel(); task = nil
            finishing.values.forEach { $0.cancel() }
            finishing = [:]
        }
        continuation.finish()
    }
}
