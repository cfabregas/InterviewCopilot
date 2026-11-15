import AVFoundation
import Foundation

/// 海外线路的流式转写：Deepgram 实时接口。
/// 文档：https://developers.deepgram.com/reference/speech-to-text/listen-streaming
final class DeepgramASR: ASRProvider, DropSimulating {
    let events: AsyncStream<ASREvent>
    private let eventContinuation: AsyncStream<ASREvent>.Continuation

    private let apiKey: String
    private let queue = DispatchQueue(label: "copilot.asr.deepgram", qos: .userInteractive)
    private let downsampler = PCM16Downsampler()
    private var socket: StreamingSocket?
    private var pending = Data()
    /// 每攒够 50 ms 音频发一次
    private let chunkBytes = PCM16Downsampler.sampleRate * 2 / 20

    // 句子拼接状态。Deepgram 按小段定稿，这里拼成整句再交给下游。
    private var committed = ""
    private var sentenceStartMs: Int?
    private var lastEndMs = 0
    private var separator = " "

    private let terms: [String]

    init(apiKey: String, terms: [String] = []) {
        self.apiKey = apiKey
        self.terms = terms
        (events, eventContinuation) = AsyncStream<ASREvent>.makeStream()
    }

    func start(locale: Locale) async throws {
        let chinese = locale.language.languageCode?.identifier == "zh"
        separator = chinese ? "" : " "
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            // 英文用 nova-3；中文用 nova-2(nova-3 对中文的支持不确定)
            URLQueryItem(name: "model", value: chinese ? "nova-2" : "nova-3"),
            URLQueryItem(name: "language", value: chinese ? "zh-CN" : "en"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(PCM16Downsampler.sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
        ]
        // 热词：只有 nova-3 支持 keyterm
        if !chinese {
            components.queryItems?.append(contentsOf: terms.map { URLQueryItem(name: "keyterm", value: $0) })
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let socket = StreamingSocket(request: request)
        socket.onText = { [weak self] text in
            self?.queue.async { self?.handle(text) }
        }
        socket.onClose = { [weak self] in
            self?.queue.async { self?.connectionClosed() }
        }
        let began = Date()
        try await socket.open()
        queue.sync { self.socket = socket }
        Log.write("Deepgram 已连接，耗时 \(Int(Date().timeIntervalSince(began) * 1000)) ms")
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
                if !pending.isEmpty { socket.send(pending) }
                pending = Data()
                socket.send(json: ["type": "CloseStream"])   // 服务端吐完剩余结果后关闭连接
            }
            self.socket = nil
            return socket
        }
        await socket?.drainAndClose(timeout: 3)
        queue.sync { flush() }
        eventContinuation.finish()
    }


    /// 连接意外断开：结束结果流，让上层去重连
    private func connectionClosed() {
        guard socket != nil else { return }   // 正常 stop 时 socket 已经置空
        socket = nil
        pending = Data()
        flush()
        eventContinuation.finish()
    }

    func simulateDrop() {
        queue.async { self.socket?.forceClose() }
    }

    // MARK: - 结果处理(都在 queue 上)

    private func handle(_ text: String) {
        guard let message = parseJSON(text), let type = message["type"] as? String else { return }
        switch type {
        case "Results":
            guard let channel = message["channel"] as? [String: Any],
                  let alternative = (channel["alternatives"] as? [[String: Any]])?.first else { return }
            let transcript = (alternative["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let isFinal = message["is_final"] as? Bool ?? false
            let speechFinal = message["speech_final"] as? Bool ?? false
            let start = message["start"] as? Double ?? 0
            let duration = message["duration"] as? Double ?? 0
            // 结束位置优先用最后一个词的时间，避免把句尾静音算进去
            let lastWordEnd = ((alternative["words"] as? [[String: Any]])?.last?["end"] as? Double) ?? (start + duration)

            if transcript.isEmpty {
                if speechFinal { flush() }
                return
            }
            if sentenceStartMs == nil { sentenceStartMs = Int(start * 1000) }
            let full = committed.isEmpty ? transcript : committed + separator + transcript
            let endMs = Int(lastWordEnd * 1000)
            if isFinal {
                committed = full
                lastEndMs = endMs
                if speechFinal || Self.endsSentence(full) || full.count > 240 {
                    flush()
                } else {
                    emit(.partial, full, endMs)
                }
            } else {
                emit(.partial, full, endMs)
            }
        case "UtteranceEnd":
            flush()
        case "Error":
            Log.write("Deepgram 报错：\(message["description"] ?? message["message"] ?? text)")
        default:
            break
        }
    }

    private func emit(_ kind: ASREvent.Kind, _ text: String, _ endMs: Int) {
        eventContinuation.yield(ASREvent(kind: kind, text: text, startMs: sentenceStartMs ?? endMs, endMs: endMs))
    }

    private func flush() {
        guard !committed.isEmpty else { return }
        emit(.final, committed, lastEndMs)
        committed = ""
        sentenceStartMs = nil
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!。？！".contains(last)
    }
}
