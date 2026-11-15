import AVFoundation
import CoreMedia
import Speech

/// 本地线路的流式转写：系统自带的 SpeechAnalyzer，完全离线。
final class AppleSpeechASR: ASRProvider {
    /// 转写引擎的几种配置，用来对比延迟。启动参数 --asr=<名字> 可切换。
    enum Variant: String {
        case fast          // SpeechTranscriber，中间结果 + 快速结果
        case volatile      // SpeechTranscriber，只开中间结果
        case dictation     // DictationTranscriber，渐进式长听写

        static var fromArguments: Variant {
            for argument in CommandLine.arguments where argument.hasPrefix("--asr=") {
                if let variant = Variant(rawValue: String(argument.dropFirst(6))) { return variant }
            }
            return .fast
        }
    }

    let events: AsyncStream<ASREvent>
    private let eventContinuation: AsyncStream<ASREvent>.Continuation
    private let variant: Variant

    private var analyzer: SpeechAnalyzer?
    private var converter: AnalyzerInputConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let feedQueue = DispatchQueue(label: "copilot.asr.feed", qos: .userInteractive)

    private let terms: [String]

    init(variant: Variant = .fromArguments, terms: [String] = []) {
        self.variant = variant
        self.terms = terms
        (events, eventContinuation) = AsyncStream<ASREvent>.makeStream()
    }

    func start(locale: Locale) async throws {
        let module: any SpeechModule
        let startResults: () -> Task<Void, Never>

        switch variant {
        case .fast, .volatile:
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw AppError("本地转写不支持语言 \(locale.identifier)")
            }
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: variant == .fast ? [.volatileResults, .fastResults] : [.volatileResults],
                attributeOptions: [.audioTimeRange])
            module = transcriber
            startResults = { [unowned self] in self.consume(transcriber.results) { $0.text } }
        case .dictation:
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw AppError("本地听写不支持语言 \(locale.identifier)")
            }
            let transcriber = DictationTranscriber(locale: supported, preset: .progressiveLongDictation)
            module = transcriber
            startResults = { [unowned self] in self.consume(transcriber.results) { $0.text } }
        }
        Log.write("本地转写配置：\(variant.rawValue)")

        // 语言模型没装时先下载
        if await AssetInventory.status(forModules: [module]) != .installed {
            Log.write("本地转写模型(\(locale.identifier))未安装，开始下载…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            Log.write("本地转写模型下载完成")
        }

        let began = Date()
        let analyzer = SpeechAnalyzer(modules: [module])
        if !terms.isEmpty {
            // 热词：告诉识别器这些词可能出现
            let context = AnalysisContext()
            context.contextualStrings = [.general: terms]
            try? await analyzer.setContext(context)
        }
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [module])
        // 预加载模型。冷启动可能要几十秒，之后再开始就很快。
        try await analyzer.prepareToAnalyze(in: await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputStream)
        Log.write("本地转写模型加载完成，耗时 \(Int(Date().timeIntervalSince(began) * 1000)) ms")

        self.analyzer = analyzer
        feedQueue.sync {
            self.converter = converter
            self.inputContinuation = inputContinuation
        }
        resultsTask = startResults()
    }

    private func consume<S: AsyncSequence & Sendable>(
        _ results: S, text: @escaping @Sendable (S.Element) -> AttributedString
    ) -> Task<Void, Never> where S.Element: SpeechModuleResult {
        let continuation = eventContinuation
        return Task {
            do {
                for try await result in results {
                    continuation.yield(ASREvent(kind: result.isFinal ? .final : .partial,
                                                text: String(text(result).characters),
                                                startMs: Self.milliseconds(result.range.start),
                                                endMs: Self.milliseconds(result.range.end)))
                }
            } catch {
                Log.write("转写结果流出错：\(error)")
            }
            continuation.finish()
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        feedQueue.async { [weak self] in
            guard let self, let converter = self.converter, let input = self.inputContinuation else { return }
            do {
                for item in try converter.convert(buffer, at: nil) { input.yield(item) }
            } catch {
                Log.write("音频格式转换失败：\(error)")
            }
        }
    }

    func stop() async {
        feedQueue.sync {
            if let converter, let input = inputContinuation {
                if let rest = try? converter.flush() { rest.forEach { input.yield($0) } }
                input.finish()
            }
            converter = nil
            inputContinuation = nil
        }
        // 收尾都带超时，保证结束会话不会卡死
        if let analyzer {
            let finished = await waitUpTo(5) { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            if !finished {
                Log.write("转写收尾超时，强制结束")
                _ = await waitUpTo(2) { await analyzer.cancelAndFinishNow() }
            }
        }
        if let resultsTask {
            let drained = await waitUpTo(2) { await resultsTask.value }
            if !drained {
                resultsTask.cancel()
                eventContinuation.finish()
            }
        }
        resultsTask = nil
        analyzer = nil
    }

    private static func milliseconds(_ time: CMTime) -> Int {
        time.isNumeric ? Int(CMTimeGetSeconds(time) * 1000) : 0
    }
}
