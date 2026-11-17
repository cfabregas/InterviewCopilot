import AVFoundation
import Foundation

/// 国内线路的流式转写：阿里云百炼 Paraformer 实时识别(WebSocket)。
/// 文档：https://help.aliyun.com/zh/model-studio/websocket-for-paraformer-real-time-service
final class AliyunASR: ASRProvider, DropSimulating {
    static let defaultEndpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"

    let events: AsyncStream<ASREvent>
    private let eventContinuation: AsyncStream<ASREvent>.Continuation

    private let apiKey: String
    private let endpoint = AliyunASR.defaultEndpoint
    private let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let queue = DispatchQueue(label: "copilot.asr.aliyun", qos: .userInteractive)
    private let downsampler = PCM16Downsampler()
    private var socket: StreamingSocket?
    private var pending = Data()
    /// 每攒够 100 ms 音频发一次(官方建议的包大小)
    private let chunkBytes = PCM16Downsampler.sampleRate * 2 / 10
    private let started = OneShot<Void>()
    private var stopped = false

    init(apiKey: String) {
        self.apiKey = apiKey
        (events, eventContinuation) = AsyncStream<ASREvent>.makeStream()
    }

    func start(locale: Locale) async throws {
        guard let url = URL(string: endpoint), url.scheme == "wss" else {
            throw AppError("阿里云接入地址无效：\(endpoint)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let socket = StreamingSocket(request: request)
        socket.onText = { [weak self] text in
            self?.queue.async { self?.handle(text) }
        }
        socket.onClose = { [weak self] in
            self?.queue.async { self?.connectionClosed() }
        }
        let began = Date()
        try await socket.open()
        socket.send(json: [
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": "paraformer-realtime-v2",
                "parameters": [
                    "format": "pcm",
                    "sample_rate": PCM16Downsampler.sampleRate,
                    // 中英都给，支持中英混说
                    "language_hints": ["zh", "en"],
                ],
                "input": [String: Any](),
            ],
        ])
        do {
            try await started.wait(timeout: 10, what: "等待阿里云识别任务启动")
        } catch {
            await socket.drainAndClose(timeout: 0)
            throw error
        }
        queue.sync { self.socket = socket }
        Log.write("阿里云实时识别已启动，耗时 \(Int(Date().timeIntervalSince(began) * 1000)) ms")
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
            stopped = true
            let socket = self.socket
            if let socket {
                if !pending.isEmpty { socket.send(pending) }
                pending = Data()
                socket.send(json: [
                    "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
                    "payload": ["input": [String: Any]()],
                ])
            }
            self.socket = nil
            return socket
        }
        await socket?.drainAndClose(timeout: 3)
        eventContinuation.finish()
    }


    /// 连接意外断开：结束结果流，让上层去重连
    private func connectionClosed() {
        guard socket != nil else { return }   // 正常 stop 时 socket 已经置空
        socket = nil
        pending = Data()
        
        eventContinuation.finish()
    }

    func simulateDrop() {
        queue.async { self.socket?.forceClose() }
    }

    // MARK: - 结果处理(在 queue 上)

    private func handle(_ text: String) {
        guard let message = parseJSON(text),
              let header = message["header"] as? [String: Any],
              let event = header["event"] as? String else { return }
        switch event {
        case "task-started":
            started.fulfill(.success(()))
        case "result-generated":
            guard let payload = message["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  sentence["heartbeat"] as? Bool != true else { return }
            let content = (sentence["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return }
            let isEnd = sentence["sentence_end"] as? Bool ?? false
            let beginMs = Self.int(sentence["begin_time"]) ?? 0
            let lastWordEnd = (sentence["words"] as? [[String: Any]])?.last.flatMap { Self.int($0["end_time"]) }
            // 句子没结束时 end_time 为空，用最后一个词的时间；都没有就标记为未知(-1)
            let endMs = Self.int(sentence["end_time"]) ?? lastWordEnd ?? -1
            eventContinuation.yield(ASREvent(kind: isEnd ? .final : .partial, text: content,
                                             startMs: beginMs, endMs: endMs))
        case "task-failed":
            let reason = "\(header["error_code"] ?? "")：\(header["error_message"] ?? text)"
            // 主动结束时(比如测速后没被选中、一点音频都没发)服务端也会报失败，不用提示
            if !stopped { Log.write("阿里云识别任务失败 \(reason)") }
            started.fulfill(.failure(AppError("阿里云识别任务失败 \(reason)")))
        default:
            break   // task-finished 等
        }
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
