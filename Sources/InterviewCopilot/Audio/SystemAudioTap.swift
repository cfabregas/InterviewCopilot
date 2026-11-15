import AVFoundation
import CoreAudio

/// 用 Core Audio Process Tap 采集系统声音(面试官一侧)。
/// 每个音频块复制后通过 onBuffer 交给下游，回调运行在内部串行队列上。
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "copilot.tap.io", qos: .userInteractive)

    private var peakSinceLastRead: Float = 0
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning = false

    /// 启动采集，返回采集到的音频格式
    @discardableResult
    func start() throws -> AVAudioFormat {
        if isRunning { stop() }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "InterviewCopilotTap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "创建 Process Tap")

        do {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "读取 Tap 格式")
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw AppError("无法识别 Tap 音频格式")
            }

            let outputUID = try defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "InterviewCopilotAggregate",
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

            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
                self?.handle(input: input, format: format)
            }, "注册音频回调")
            try check(AudioDeviceStart(aggregateID, procID), "启动采集")
            isRunning = true
            return format
        } catch {
            teardown()
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        AudioDeviceStop(aggregateID, procID)
        teardown()
        isRunning = false
        queue.sync {}   // 等在途回调结束
    }

    private func teardown() {
        if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func handle(input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        // 回调里的内存只在本次回调内有效，必须复制一份再交给下游
        guard let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength) else { return }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(from, to) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            memcpy(dstData, srcData, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        if let channels = copy.floatChannelData {
            let count = Int(copy.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
            var peak: Float = 0
            for sample in UnsafeBufferPointer(start: channels[0], count: count) { peak = max(peak, abs(sample)) }
            peakSinceLastRead = max(peakSinceLastRead, peak)
        }
        onBuffer?(copy)
    }

    /// 读取并清零上次读取以来的音量峰值，用来发现"采到的全是静音"
    func takePeak() -> Float {
        queue.sync {
            let peak = peakSinceLastRead
            peakSinceLastRead = 0
            return peak
        }
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
        guard status == noErr else { throw AppError("\(step)失败，OSStatus = \(status)") }
    }
}
