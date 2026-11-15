import AVFoundation
import Foundation

/// 可以被人为断开连接的转写线路，用于自测断线恢复
protocol DropSimulating {
    func simulateDrop()
}

/// 给云端转写加上断线保护：
/// - 保留最近 10 秒音频，重连后从上一句定稿的位置补发，避免丢句；
/// - 短时间内重连不上就切到本地转写兜底，后台继续探测，云端恢复后在句子边界切回。
/// 对外仍是一条 ASRProvider，时间戳统一换算到整场会话的音频时间轴上。
final class ResilientASR: ASRProvider {
    let events: AsyncStream<ASREvent>
    private let out: AsyncStream<ASREvent>.Continuation

    private let name: String
    private let makePrimary: () -> ASRProvider
    private let makeFallback: (() -> ASRProvider)?
    private var adopted: ASRProvider?
    /// 线路变化时回调(任意线程)，参数是给用户看的线路说明
    var onRoute: ((String) -> Void)?

    private let q = DispatchQueue(label: "copilot.asr.resilient", qos: .userInteractive)
    // 以下状态都只在 q 上读写
    private var current: ASRProvider?
    private var draining: ASRProvider?
    private var currentIsFallback = false
    private var pumps: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var ring: [(startFrame: Int, buffer: AVAudioPCMBuffer)] = []
    private var framesFed = 0
    private var sampleRate = 48_000.0
    private var lastFinalEndMs = 0
    private var hasOpenPartial = false
    private var stopping = false
    private var recovering = false
    private var locale = Locale.current

    // 自测用：--chaos=<秒> 在该时刻断开连接；加 --chaos-long 则随后 6 秒内重连都失败，逼出本地兜底
    private let chaosAtSeconds: Double?
    private var chaosDone = false
    private var blockPrimaryUntil = Date.distantPast

    /// - Parameter started: 已经连好的主线路(测速选路时顺手建好的连接)，避免重复建连
    init(name: String, started: ASRProvider? = nil,
         makePrimary: @escaping () -> ASRProvider, makeFallback: (() -> ASRProvider)?) {
        self.name = name
        self.adopted = started
        self.makePrimary = makePrimary
        self.makeFallback = makeFallback
        (events, out) = AsyncStream<ASREvent>.makeStream()
        chaosAtSeconds = CommandLine.arguments.first { $0.hasPrefix("--chaos=") }
            .flatMap { Double($0.dropFirst(8)) }
    }

    func start(locale: Locale) async throws {
        q.sync { self.locale = locale }
        if let adopted {
            self.adopted = nil
            q.sync { install(adopted, isFallback: false, replay: false) }
            return
        }
        let primary = makePrimary()
        do {
            try await primary.start(locale: locale)
            q.sync { install(primary, isFallback: false, replay: false) }
        } catch {
            guard let makeFallback else { throw error }
            Log.write("\(name) 启动失败(\(error))，先用本地转写兜底")
            let fallback = makeFallback()
            try await fallback.start(locale: locale)
            q.sync { install(fallback, isFallback: true, replay: false) }
            onRoute?("本地兜底(\(name) 连不上)")
            recover(alreadyOnFallback: true)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        q.async { [self] in
            sampleRate = buffer.format.sampleRate
            ring.append((framesFed, buffer))
            framesFed += Int(buffer.frameLength)
            // 正常时留 10 秒；断线期间多留一些，等重连后补发
            let keep = Int((current == nil ? 30 : 10) * sampleRate)
            while let first = ring.first, first.startFrame < framesFed - keep { ring.removeFirst() }
            current?.feed(buffer)

            if let at = chaosAtSeconds, !chaosDone, !currentIsFallback, Double(framesFed) / sampleRate >= at {
                chaosDone = true
                if CommandLine.arguments.contains("--chaos-long") { blockPrimaryUntil = Date().addingTimeInterval(6) }
                Log.write("【自测】人为断开 \(name) 的连接")
                (current as? DropSimulating)?.simulateDrop()
            }
        }
    }

    func stop() async {
        let (provider, pump): (ASRProvider?, Task<Void, Never>?) = q.sync {
            stopping = true
            let provider = current
            draining = provider     // 收尾时吐出的最后几条结果仍然要
            current = nil
            return (provider, provider.flatMap { pumps[ObjectIdentifier($0)] })
        }
        await provider?.stop()
        if let pump { _ = await waitUpTo(3) { await pump.value } }
        out.finish()
    }

    // MARK: - 线路安装与事件转发

    /// 把一条已启动的线路设为当前线路。replay 为 true 时，从上一句定稿的位置补发缓冲的音频。只在 q 上调用。
    private func install(_ provider: ASRProvider, isFallback: Bool, replay: Bool) {
        let fromFrame = replay ? Int(Double(lastFinalEndMs) / 1000 * sampleRate) : framesFed
        let pendingBuffers = ring.filter { $0.startFrame >= fromFrame }
        // 这条线路的时间从它收到的第一块音频算起，换算到会话时间轴要加上这个偏移
        let startFrame = pendingBuffers.first?.startFrame ?? framesFed
        let offsetMs = Int(Double(startFrame) / sampleRate * 1000)

        current = provider
        currentIsFallback = isFallback
        hasOpenPartial = false
        for item in pendingBuffers { provider.feed(item.buffer) }
        if replay {
            let seconds = Double(framesFed - startFrame) / sampleRate
            Log.write(String(format: "已补发 %.1f 秒音频", seconds))
        }

        pumps[ObjectIdentifier(provider)] = Task { [weak self] in
            for await event in provider.events {
                guard let self else { return }
                let forward: Bool = self.q.sync {
                    guard provider === self.current || provider === self.draining else { return false }
                    switch event.kind {
                    case .partial: self.hasOpenPartial = true
                    case .final:
                        self.hasOpenPartial = false
                        if event.endMs >= 0 { self.lastFinalEndMs = max(self.lastFinalEndMs, event.endMs + offsetMs) }
                    }
                    return true
                }
                if forward {
                    self.out.yield(ASREvent(kind: event.kind, text: event.text,
                                            startMs: event.startMs + offsetMs,
                                            endMs: event.endMs >= 0 ? event.endMs + offsetMs : -1))
                }
            }
            // 结果流结束：如果它还是当前线路，说明是意外断开
            guard let self else { return }
            let dropped: Bool = self.q.sync {
                self.pumps[ObjectIdentifier(provider)] = nil
                guard provider === self.current, !self.stopping else { return false }
                self.current = nil
                return true
            }
            if dropped { self.recover(alreadyOnFallback: false) }
        }
    }

    // MARK: - 断线恢复

    private func tryPrimary() async -> ASRProvider? {
        let (blocked, locale): (Bool, Locale) = q.sync { (Date() < blockPrimaryUntil, self.locale) }
        if blocked { return nil }
        let provider = makePrimary()
        do {
            try await provider.start(locale: locale)
            return provider
        } catch {
            return nil
        }
    }

    private func recover(alreadyOnFallback: Bool) {
        let begin: Bool = q.sync {
            if recovering || stopping { return false }
            recovering = true
            return true
        }
        guard begin else { return }

        Task { [self] in
            defer { q.sync { recovering = false } }
            let droppedAt = Date()
            if !alreadyOnFallback {
                Log.write("\(name) 连接断开，正在重连…")
                onRoute?("\(name) 重连中")
                // 先快速重试两次，多数抖动在这里就恢复了
                for delay in [0.2, 1.0] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if q.sync(execute: { stopping }) { return }
                    if let provider = await tryPrimary() {
                        q.sync { install(provider, isFallback: false, replay: true) }
                        Log.write(String(format: "\(name) 已重连，中断 %.1f 秒", Date().timeIntervalSince(droppedAt)))
                        onRoute?(name)
                        return
                    }
                }
                // 重连不上：切本地兜底，保证字幕不断
                if let makeFallback {
                    let fallback = makeFallback()
                    let locale = q.sync { self.locale }
                    if (try? await fallback.start(locale: locale)) != nil {
                        q.sync { install(fallback, isFallback: true, replay: true) }
                        Log.write("\(name) 重连失败，已切到本地转写兜底")
                        onRoute?("本地兜底(\(name) 断线)")
                    }
                }
            }
            // 后台持续探测主线路
            var delay = 3.0
            while true {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if q.sync(execute: { stopping }) { return }
                delay = min(delay * 1.5, 15)
                guard let provider = await tryPrimary() else { continue }
                await switchBack(to: provider)
                Log.write(String(format: "\(name) 已恢复，累计中断 %.1f 秒", Date().timeIntervalSince(droppedAt)))
                onRoute?(name)
                return
            }
        }
    }

    /// 切回主线路。尽量等兜底线路把当前这句说完(最多等 8 秒)，在句子边界切换。
    private func switchBack(to provider: ASRProvider) async {
        for _ in 0..<40 {
            if q.sync(execute: { !hasOpenPartial || current == nil }) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let old: ASRProvider? = q.sync {
            let old = current
            // 句子说到一半被迫切换，或者之前根本没有兜底线路：从上一句定稿处补发
            install(provider, isFallback: false, replay: hasOpenPartial || old == nil)
            return old
        }
        if let old { Task { await old.stop() } }
    }
}
