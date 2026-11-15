import AVFoundation

/// 把音频块写成 AAC 文件。写入在内部串行队列上进行。
final class AudioFileRecorder {
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "copilot.recorder")
    let startedAt = Date()

    init(url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 96_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            do { try self?.file?.write(from: buffer) } catch { Log.write("录音写入失败：\(error)") }
        }
    }

    func close() {
        queue.sync { file = nil }
    }
}

/// 麦克风只录音不处理：回声消除和转写放到会后。
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var recorder: AudioFileRecorder?
    private(set) var startedAt: Date?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError("没有可用的麦克风输入")
        }
        let recorder = try AudioFileRecorder(url: url, format: format)
        self.recorder = recorder
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder.write(buffer)
        }
        try engine.start()
        startedAt = Date()
    }

    func stop() {
        guard startedAt != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recorder?.close()
        recorder = nil
        startedAt = nil
    }
}
