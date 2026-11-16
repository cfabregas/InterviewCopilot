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
    private var finished: CheckedContinuation<Void, Never>?

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

    /// 播放一段合成好的语音，播完才返回
    func play(_ clip: Clip) async {
        stop()
        guard let player = try? AVAudioPlayer(data: clip.wav) else { return }
        self.player = player
        player.delegate = self
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finished = continuation
            if !player.play() { finish() }
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
