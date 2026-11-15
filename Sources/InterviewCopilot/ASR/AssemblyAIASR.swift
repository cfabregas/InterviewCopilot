import AVFoundation
import Foundation

/// 海外线路的流式转写：AssemblyAI 实时接口(v3)。
/// 文档：https://www.assemblyai.com/docs/api-reference/streaming-api/streaming-api
final class AssemblyAIASR: ASRProvider {
    let events: AsyncStream<ASREvent>
    private let eventContinuation: AsyncStream<ASREvent>.Continuation

    private let apiKey: String
    private let queue = DispatchQueue(label: "copilot.asr.assemblyai", qos: .userInteractive)
    private let downsampler = PCM16Downsampler()
    private var socket: StreamingSocket?
    private var pending = Data()
    /// 每攒够 50 ms 音频发一次(接口要求每包 20–1000 ms)
    private let chunkBytes = PCM16Downsampler.sampleRate * 2 / 20
    private var separator = " "
    /// 已经定稿的最后一轮，防止同一轮重复定稿
    private var lastFinalTurn = -1

    init(apiKey: String) {
        self.apiKey = apiKey
        (events, eventContinuation) = AsyncStream<ASREvent>.makeStream()
    }

    func start(locale: Locale) async throws {
        let chinese = locale.language.languageCode?.identifier == "zh"
        separator = chinese ? "" : " "
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        components.queryItems = [
            URLQueryItem(name: "speech_model", value: "universal-3-6-pro"),
            URLQueryItem(name: "sample_rate", value: String(PCM16Downsampler.sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
        ]
        // 英文是模型默认语言，不用指定；中文需要显式给语言代码
        if chinese {
            components.queryItems?.append(URLQueryItem(name: "language_codes", value: "[\"zh\"]"))
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let socket = StreamingSocket(request: request)
        socket.onText = { [weak self] text in
            self?.queue.async { self?.handle(text) }
        }
        let began = Date()
        try await socket.open()
        queue.sync { self.socket = socket }
        Log.write("AssemblyAI 已连接，耗时 \(Int(Date().timeIntervalSince(began) * 1000)) ms")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let socket = self.socket else { return }
            self.pending.append(self.downsampler.convert(buffer))
            while self.pending.count >= self.chunkBytes {
                socket.send(self.pending.prefix(self.chunkBytes))
                self.pending.removeFirst(self.chunkBytes)
            }
        }
    }

    func stop() async {
        let socket: StreamingSocket? = queue.sync {
            let socket = self.socket
            if let socket {
                // 剩余不足一包的音频短于接口下限，直接丢弃
                pending = Data()
                socket.send(json: ["type": "Terminate"])
            }
            self.socket = nil
            return socket
        }
        await socket?.drainAndClose(timeout: 3)
        eventContinuation.finish()
    }

    // MARK: - 结果处理(在 queue 上)

    private func handle(_ text: String) {
        guard let message = parseJSON(text), let type = message["type"] as? String else { return }
        switch type {
        case "Turn":
            let order = (message["turn_order"] as? NSNumber)?.intValue ?? 0
            guard order > lastFinalTurn else { return }
            let words = message["words"] as? [[String: Any]] ?? []
            let startMs = (words.first?["start"] as? NSNumber)?.intValue
            let endMs = (words.last?["end"] as? NSNumber)?.intValue ?? -1
            let transcript = (message["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)

            if message["end_of_turn"] as? Bool == true {
                let utterance = (message["utterance"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let final = utterance.isEmpty ? transcript : utterance
                guard !final.isEmpty else { return }
                lastFinalTurn = order
                eventContinuation.yield(ASREvent(kind: .final, text: final, startMs: startMs ?? 0, endMs: endMs))
            } else {
                // 中间结果用全部词(含还没定稿的)，这样上屏最快
                let running = words.compactMap { $0["text"] as? String }.joined(separator: separator)
                let partial = running.isEmpty ? transcript : running
                guard !partial.isEmpty else { return }
                eventContinuation.yield(ASREvent(kind: .partial, text: partial, startMs: startMs ?? 0, endMs: endMs))
            }
        case "Begin", "Termination", "SpeechStarted":
            break
        default:
            // 报错等其他消息原样记下，方便排查参数问题
            Log.write("AssemblyAI 消息：\(text.prefix(300))")
        }
    }
}
