import AVFoundation
import Foundation

/// 判断一场面试是不是外放：对方说话时，麦克风里是不是晚几十毫秒也出现了同样的声音。
/// 做法是把两条录音都变成每 20 毫秒一个点的音量曲线，在一小段延迟范围里找两条曲线最像的位置。
/// 不依赖输出设备类型，耳机漏音严重时也能发现。
enum EchoDetector {
    struct Result {
        /// 两条音量曲线的相关系数，0 到 1，越大越像
        let score: Double
        /// 麦克风里的回声比系统声音晚多少毫秒
        let lagMs: Int
        /// 回声明显到回放时应该只放麦克风
        var hasEcho: Bool { score >= threshold }
    }

    static let threshold = 0.4
    private static let frameMs = 20

    /// micOffsetMs：麦克风录音比系统录音晚开始多少毫秒(复盘时间轴上的对齐量)
    static func analyze(system: URL, mic: URL, micOffsetMs: Int) -> Result? {
        guard let s = envelope(system), let m = envelope(mic), s.count > 50, m.count > 50 else { return nil }
        // 系统声音几乎全程无声(比如对方没开麦)时判断不了
        let active = s.filter { $0 > 0.003 }.count
        guard active > 50 else { return nil }

        let offset = micOffsetMs / frameMs
        var best = (score: -1.0, lag: 0)
        // 麦克风里的回声比系统声音晚：扬声器到麦克风的距离加上设备的缓冲，一般几十到几百毫秒
        for lag in stride(from: -5, through: 30, by: 1) {
            // 系统声音第 i 帧对应麦克风第 i - offset + lag 帧
            var xs: [Float] = []
            var ys: [Float] = []
            xs.reserveCapacity(s.count)
            ys.reserveCapacity(s.count)
            for i in 0..<s.count {
                let j = i - offset + lag
                guard j >= 0, j < m.count else { continue }
                xs.append(s[i])
                ys.append(m[j])
            }
            guard xs.count > 50 else { continue }
            let r = pearson(xs, ys)
            if r > best.score { best = (r, lag) }
        }
        guard best.score > -1 else { return nil }
        return Result(score: max(best.score, 0), lagMs: best.lag * frameMs)
    }

    /// 每 20 毫秒的平均音量(RMS)，多声道取平均
    private static func envelope(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameSize = AVAudioFrameCount(format.sampleRate * Double(frameMs) / 1000)
        guard frameSize > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameSize * 500) else { return nil }
        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) / Double(frameSize)) + 1)
        while true {
            do { try file.read(into: buffer) } catch { break }
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(format.channelCount)
            var start = 0
            while start < count {
                let end = min(start + Int(frameSize), count)
                var sum: Float = 0
                for c in 0..<channels {
                    let samples = data[c]
                    for k in start..<end { sum += samples[k] * samples[k] }
                }
                result.append(sqrt(sum / Float((end - start) * channels)))
                start = end
            }
        }
        return result
    }

    private static func pearson(_ x: [Float], _ y: [Float]) -> Double {
        let n = Double(x.count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<x.count {
            let a = Double(x[i]), b = Double(y[i])
            sx += a; sy += b; sxx += a * a; syy += b * b; sxy += a * b
        }
        let cov = sxy - sx * sy / n
        let vx = sxx - sx * sx / n, vy = syy - sy * sy / n
        guard vx > 0, vy > 0 else { return 0 }
        return cov / (vx * vy).squareRoot()
    }
}
