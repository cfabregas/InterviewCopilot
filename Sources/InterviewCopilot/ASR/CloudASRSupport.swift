import AVFoundation
import Foundation

/// 只会被兑现一次的等待点，带超时。用来等"连接已打开""任务已启动"这类一次性事件。
final class OneShot<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private let lock = NSLock()

    func wait(timeout: Double, what: String) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                c.resume(with: result)
                return
            }
            continuation = c
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.fulfill(.failure(AppError("\(what)超时")))
            }
        }
    }

    func fulfill(_ value: Result<T, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: value)
    }
}

/// 把采集到的音频(48 kHz 立体声浮点)转成云端转写通用的 16 kHz 单声道 16 位 PCM。
/// 只在单一队列上调用。
final class PCM16Downsampler {
    static let sampleRate = 16_000
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                             channels: 1, interleaved: true)!

    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            inputFormat = buffer.format
        }
        guard let converter else { return Data() }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Double(Self.sampleRate) / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return Data() }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData else { return Data() }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// WebSocket 长连接的薄封装：打开、发送、循环接收。
final class StreamingSocket {
    private let task: URLSessionWebSocketTask
    private var receiveTask: Task<Void, Never>?
    /// 收到文本消息。在任意线程回调。
    var onText: ((String) -> Void)?

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
    }

    /// 建立连接。握手失败(密钥无效、网络不通)会在这里抛错。
    func open() async throws {
        task.resume()
        let opened = OneShot<Void>()
        task.sendPing { error in
            if let error { opened.fulfill(.failure(error)) } else { opened.fulfill(.success(())) }
        }
        do {
            try await opened.wait(timeout: 10, what: "连接")
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            var hint = "\(error.localizedDescription)"
            if let response = task.response as? HTTPURLResponse {
                hint = "HTTP \(response.statusCode)" + ([401, 403].contains(response.statusCode) ? "，API Key 无效或没有权限" : "")
            }
            throw AppError("连接云端转写失败：\(hint)")
        }
        receiveTask = Task { [task, weak self] in
            while true {
                do {
                    switch try await task.receive() {
                    case .string(let text): self?.onText?(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self?.onText?(text) }
                    @unknown default: break
                    }
                } catch {
                    return   // 连接关闭
                }
            }
        }
    }

    func send(_ data: Data) {
        task.send(.data(data)) { _ in }
    }

    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// 等服务端把剩余结果发完并关闭连接，最多等指定秒数，然后断开。
    func drainAndClose(timeout: Double) async {
        if let receiveTask {
            _ = await waitUpTo(timeout) { await receiveTask.value }
        }
        task.cancel(with: .normalClosure, reason: nil)
        receiveTask?.cancel()
        receiveTask = nil
    }
}

func parseJSON(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
