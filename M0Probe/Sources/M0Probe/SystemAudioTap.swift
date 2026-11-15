import AVFoundation
import CoreAudio

/// 用 Core Audio Process Tap 采集系统声音(全局 Tap)，写入 WAV 并统计电平。
final class SystemAudioTap {
    struct Stats {
        var callbacks = 0
        var frames: Int64 = 0
        var peakRMS: Float = 0
        var formatDescription = ""
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var stats = Stats()
    private let queue = DispatchQueue(label: "m0probe.tap.io")

    var onLevel: ((Float) -> Void)?
    private(set) var isRunning = false

    func start(writingTo url: URL) throws {
        guard !isRunning else { return }

        // 1. 创建全局 Tap(不排除任何进程)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "M0ProbeTap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "创建 Process Tap")

        // 2. 读取 Tap 的音频格式
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd), "读取 Tap 格式")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw ProbeError("无法识别 Tap 音频格式")
        }

        // 3. 创建包含 Tap 的私有聚合设备
        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "M0ProbeAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "创建聚合设备")

        // 4. 录音文件：16 位 WAV，处理格式与 Tap 一致
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        stats = Stats()
        stats.formatDescription = "\(Int(format.sampleRate)) Hz, \(format.channelCount) 声道, "
            + (format.isInterleaved ? "交错" : "非交错")

        // 5. 注册回调并启动
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.handle(input: input, format: format)
        }, "注册音频回调")
        try check(AudioDeviceStart(aggregateID, procID), "启动采集")
        isRunning = true
    }

    @discardableResult
    func stop() -> Stats {
        guard isRunning else { return stats }
        AudioDeviceStop(aggregateID, procID)
        if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
        return queue.sync {
            file = nil
            return stats
        }
    }

    private func handle(input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }
        try? file?.write(from: buffer)

        var rms: Float = 0
        if let channels = buffer.floatChannelData {
            let count = Int(buffer.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
            let samples = UnsafeBufferPointer(start: channels[0], count: count)
            var sum: Float = 0
            for sample in samples { sum += sample * sample }
            rms = (sum / Float(max(count, 1))).squareRoot()
        }
        stats.callbacks += 1
        stats.frames += Int64(buffer.frameLength)
        stats.peakRMS = max(stats.peakRMS, rms)
        onLevel?(rms)
    }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
                  "读取默认输出设备")

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        try check(status, "读取输出设备 UID")
        return uid as String
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw ProbeError("\(step)失败，OSStatus = \(status)") }
    }
}
