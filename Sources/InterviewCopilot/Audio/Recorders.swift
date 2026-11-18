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

/// 麦克风输入的公共处理：可以打开系统的语音处理(和 FaceTime 一样的回声消除)，并把输入整理成单声道。
/// 系统会把扬声器正在播放的声音从麦克风里减掉，但同时会压低其他应用(比如会议软件)的音量，
/// 所以只有模拟面试用它；真实面试不开，保证听得清对方。
/// 注意：开过语音处理的引擎停下后要关掉语音处理，否则同一次运行里之后不开的录音会拿不到声音。
enum VoiceInput {
    /// 打开回声消除，返回是否成功(设备不支持时退回普通录音)
    static func enableEchoCancellation(_ engine: AVAudioEngine) -> Bool {
        let input = engine.inputNode
        // 模拟面试自测靠外放的系统语音代替人作答，开了回声消除就录不到了
        let arguments = CommandLine.arguments
        if arguments.contains("--mock-test"), !arguments.contains("--scripted") {
            Log.write("模拟面试自测：不开回声消除，好让麦克风录到外放的回答")
            return false
        }
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            Log.write("麦克风回声消除开启失败，改为普通录音：\(error)")
            return false
        }
        // 只要回声消除：不自动调音量，也尽量不压低会议软件等其他声音
        input.isVoiceProcessingAGCEnabled = false
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        // 语音处理要求输出端也接上，才能拿到扬声器的声音作参考
        _ = engine.outputNode
        return true
    }

    /// 停下引擎后调用：关掉语音处理，恢复麦克风的普通状态
    static func disableEchoCancellation(_ engine: AVAudioEngine) {
        guard engine.inputNode.isVoiceProcessingEnabled else { return }
        do { try engine.inputNode.setVoiceProcessingEnabled(false) } catch { Log.write("关闭回声消除失败：\(error)") }
    }

    /// 和输入同采样率的单声道格式
    static func monoFormat(for format: AVAudioFormat) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
    }

    /// 开了语音处理后输入是多声道，处理过的人声在第一个声道；取出来变成单声道
    static func mono(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let target = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        target[0].update(from: source[0], count: Int(buffer.frameLength))
        return copy
    }
}

/// 麦克风录音，默认不开回声消除(会压低会议软件的声音)
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var recorder: AudioFileRecorder?
    private(set) var startedAt: Date?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(url: URL, voiceProcessing: Bool = false) throws {
        let echoCancelled = voiceProcessing && VoiceInput.enableEchoCancellation(engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let mono = VoiceInput.monoFormat(for: format) else {
            throw AppError("没有可用的麦克风输入")
        }
        let recorder = try AudioFileRecorder(url: url, format: mono)
        self.recorder = recorder
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let copy = VoiceInput.mono(buffer, format: mono) { recorder.write(copy) }
        }
        try engine.start()
        startedAt = Date()
        Log.write("麦克风录音已启动：\(Int(format.sampleRate)) Hz，\(format.channelCount) 声道，回声消除\(echoCancelled ? "已开启" : "未开启")")
    }

    func stop() {
        guard startedAt != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        VoiceInput.disableEchoCancellation(engine)
        recorder?.close()
        recorder = nil
        startedAt = nil
    }
}
