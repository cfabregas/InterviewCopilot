import AVFoundation
import Foundation

/// 把文字读出来。首选阿里云百炼的语音合成(声音自然)，失败时退回系统自带语音。
/// 文档：https://help.aliyun.com/zh/model-studio/qwen-tts
@MainActor
final class SpeechSynth: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    /// 合成好的一段语音：24 kHz 单声道 16 位 PCM
    struct Clip {
        let wav: Data
        var pcm: Data { SpeechSynth.pcm(fromWAV: wav) }
        var seconds: Double { Double(pcm.count) / 2 / SpeechSynth.sampleRate }
    }

    nonisolated static let sampleRate = 24_000.0
    nonisolated static let model = "qwen3-tts-flash"

    private var player: AVAudioPlayer?
    private let system = AVSpeechSynthesizer()
    /// 把系统语音渲染成音频数据，不直接出声
    private let renderer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?
    /// 接在录音用的音频引擎上的播放器，见 attach(to:)
    private weak var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    /// 每次播放的编号：停掉旧的播放时，它迟到的结束回调不会误结束新的播放
    private var playID = 0

    override init() {
        super.init()
        system.delegate = self
    }

    /// 合成一段语音。chinese 决定音色和语种。
    nonisolated static func synthesize(_ text: String, chinese: Bool, apiKey: String) async throws -> Clip {
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": ["text": text, "voice": chinese ? "Cherry" : "Ethan", "language_type": chinese ? "Chinese" : "English"],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [String: Any],
              let audio = output["audio"] as? [String: Any],
              let link = audio["url"] as? String,
              // 返回的是 http 地址，系统默认不允许明文下载，换成 https
              let url = URL(string: link.replacingOccurrences(of: "http://", with: "https://")) else {
            throw AppError("语音合成返回 HTTP \(status)：\(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        let (wav, _) = try await URLSession.shared.data(from: url)
        guard wav.count > 44 else { throw AppError("语音合成没有返回音频") }
        return Clip(wav: wav)
    }

    /// 取出 WAV 文件里的 PCM 数据
    nonisolated static func pcm(fromWAV wav: Data) -> Data {
        guard let range = wav.range(of: Data("data".utf8)), range.upperBound + 4 <= wav.count else { return wav.dropFirst(44) }
        return wav.subdata(in: (range.upperBound + 4)..<wav.count)
    }

    /// 让面试官的声音走录音用的同一个音频引擎播放。
    /// 系统回声消除只把本引擎播放的声音当作参考信号：这样既不会被当成"其他应用的声音"压低音量，
    /// 也能从麦克风里消掉。要在引擎启动前调用。
    func attach(to engine: AVAudioEngine) {
        guard let format = Self.floatFormat else { return }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.engine = engine
        self.node = node
    }

    /// 播放一段合成好的语音，播完才返回
    func play(_ clip: Clip) async {
        stop()
        if let node, let engine, engine.isRunning, let buffer = Self.floatBuffer(clip) {
            let id = playID
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finished = continuation
                node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                    Task { @MainActor in if self.playID == id { self.finish() } }
                }
                node.play()
            }
            return
        }
        guard let player = try? AVAudioPlayer(data: clip.wav) else { return }
        self.player = player
        player.delegate = self
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finished = continuation
            if !player.play() { finish() }
        }
    }

    /// 用系统自带语音把一段话渲染成音频(不出声)，渲染不出来时返回 nil
    func systemVoiceClip(_ text: String, chinese: Bool) async -> Clip? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: chinese ? "zh-CN" : "en-US")
        let collector = BufferCollector()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Clip?, Never>) in
            collector.onDone = { buffers in continuation.resume(returning: SpeechSynth.clip(from: buffers)) }
            renderer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { collector.finish() } else { collector.append(pcm) }
            }
            // 万一系统没有发结束信号，最多等 20 秒
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { collector.finish() }
        }
    }

    /// 用系统自带语音读，读完才返回
    func speakWithSystemVoice(_ text: String, chinese: Bool) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: chinese ? "zh-CN" : "en-US")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finished = continuation
            system.speak(utterance)
        }
    }

    func stop() {
        playID += 1
        node?.stop()
        player?.stop()
        player = nil
        if system.isSpeaking { system.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated static let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)

    /// 16 位 PCM 转成播放器要的浮点缓冲
    nonisolated static func floatBuffer(_ clip: Clip) -> AVAudioPCMBuffer? {
        let pcm = clip.pcm
        let count = pcm.count / 2
        guard count > 0, let format = floatFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count { channel[i] = Float(samples[i]) / 32768 }
        }
        return buffer
    }

    /// 系统语音渲染出来的若干段音频，统一转成 24 kHz 单声道 16 位，包成 Clip
    nonisolated static func clip(from buffers: [AVAudioPCMBuffer]) -> Clip? {
        guard let first = buffers.first,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: first.format, to: target) else { return nil }
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let capacity = AVAudioFrameCount(Double(frames) * sampleRate / first.format.sampleRate) + 4096
        guard frames > 0, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var index = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard index < buffers.count else { inputStatus.pointee = .endOfStream; return nil }
            inputStatus.pointee = .haveData
            index += 1
            return buffers[index - 1]
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        return Clip(wav: wav(fromPCM: Data(bytes: samples, count: Int(output.frameLength) * 2)))
    }

    /// 给 24 kHz 单声道 16 位 PCM 加上 WAV 文件头
    nonisolated static func wav(fromPCM pcm: Data) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        text("data"); u32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// 把面试官说过的每一段语音按时间排进一条音轨，写成录音文件(复盘时回放用)
    nonisolated static func writeTrack(_ clips: [(startMs: Int, clip: Clip)], totalMs: Int, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AppError("无法创建音轨格式")
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var written = 0
        func write(_ samples: [Float]) throws {
            var offset = 0
            while offset < samples.count {
                let count = min(48_000, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else { return }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + offset, count: count) }
                try file.write(from: buffer)
                offset += count
            }
            written += samples.count
        }
        for (startMs, clip) in clips.sorted(by: { $0.startMs < $1.startMs }) {
            let startFrame = Int(Double(startMs) / 1000 * sampleRate)
            if startFrame > written { try write([Float](repeating: 0, count: startFrame - written)) }
            let pcm = clip.pcm
            let samples: [Float] = pcm.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
            }
            try write(samples)
        }
        let totalFrames = Int(Double(totalMs) / 1000 * sampleRate)
        if totalFrames > written { try write([Float](repeating: 0, count: totalFrames - written)) }
    }
}

/// 收集系统语音渲染回调送来的音频，结束时只回调一次
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var done = false
    var onDone: (([AVAudioPCMBuffer]) -> Void)?

    func append(_ buffer: AVAudioPCMBuffer) {
        // 系统可能复用缓冲，拷一份
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            if let src = from.mData, let dst = to.mData { memcpy(dst, src, min(bytes, Int(from.mDataByteSize))) }
        }
        lock.lock(); if !done { buffers.append(copy) }; lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let result = buffers
        lock.unlock()
        onDone?(result)
    }
}
