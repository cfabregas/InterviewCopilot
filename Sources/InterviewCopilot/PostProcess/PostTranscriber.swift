import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 会后对整段录音重新转写。和会中的流式转写相比，模型能看到完整上下文，准确率更高，还能区分说话人。
enum PostTranscriber {
    /// 一段连续的发言。speaker 是转写服务给的说话人标签(A、B…)，本地转写分不出说话人，为 nil。
    struct Piece {
        var speaker: String?
        var startMs: Int
        var endMs: Int
        var text: String
    }

    // MARK: - 云端：AssemblyAI 录音文件接口
    // 文档：https://www.assemblyai.com/docs/api-reference/transcripts/submit

    static func cloud(file: URL, apiKey: String, chinese: Bool, terms: [String],
                      progress: @escaping (String) -> Void) async throws -> [Piece] {
        progress("上传录音")
        var upload = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        upload.httpMethod = "POST"
        upload.timeoutInterval = 600
        upload.setValue(apiKey, forHTTPHeaderField: "authorization")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (uploadData, uploadResponse) = try await URLSession.shared.upload(for: upload, fromFile: file)
        guard let uploaded = try json(uploadData, uploadResponse)["upload_url"] as? String else {
            throw AppError("上传录音后没有拿到地址")
        }

        var body: [String: Any] = [
            "audio_url": uploaded,
            "language_code": chinese ? "zh" : "en",
            "speaker_labels": true,
        ]
        // 热词：每个最多 6 个词
        let keyterms = terms.filter { $0.split(separator: " ").count <= 6 }
        if !keyterms.isEmpty { body["keyterms_prompt"] = keyterms }

        progress("提交转写")
        var created: [String: Any]
        do {
            created = try await submit(body, apiKey: apiKey)
        } catch where body["keyterms_prompt"] != nil {
            // 有的语言不支持热词：去掉再试一次
            Log.write("会后转写：带热词提交失败(\(error))，去掉热词重试")
            body["keyterms_prompt"] = nil
            created = try await submit(body, apiKey: apiKey)
        }
        guard let id = created["id"] as? String else { throw AppError("提交转写后没有拿到任务编号") }

        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript/\(id)")!)
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        let began = Date()
        while true {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let (data, response) = try await URLSession.shared.data(for: request)
            let result = try json(data, response)
            switch result["status"] as? String {
            case "completed":
                return pieces(from: result, chinese: chinese)
            case "error":
                throw AppError("云端转写失败：\(result["error"] as? String ?? "未知原因")")
            default:
                progress("云端转写中(\(Int(Date().timeIntervalSince(began))) 秒)")
                if Date().timeIntervalSince(began) > 1200 { throw AppError("云端转写超过 20 分钟没有完成") }
            }
        }
    }

    private static func submit(_ body: [String: Any], apiKey: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try json(data, response)
    }

    private static func json(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("AssemblyAI 返回 HTTP \(status)：\(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        }
        return object
    }

    private static func pieces(from result: [String: Any], chinese: Bool) -> [Piece] {
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        if let utterances = result["utterances"] as? [[String: Any]], !utterances.isEmpty {
            return utterances.flatMap { item -> [Piece] in
                guard let text = item["text"] as? String, !text.isEmpty else { return [] }
                let speaker = item["speaker"] as? String
                let whole = Piece(speaker: speaker, startMs: int(item["start"]), endMs: int(item["end"]), text: text)
                // 服务端把同一个人前后说的话并成了一大段，哪怕中间隔着别人的发言：按停顿(1.5 秒以上)重新切开
                guard let words = item["words"] as? [[String: Any]], words.count > 1 else { return [whole] }
                var pieces: [Piece] = []
                var current: [[String: Any]] = []
                func flush() {
                    guard let first = current.first, let last = current.last else { return }
                    let joined = current.compactMap { $0["text"] as? String }.joined(separator: chinese ? "" : " ")
                    pieces.append(Piece(speaker: speaker, startMs: int(first["start"]), endMs: int(last["end"]), text: joined))
                    current = []
                }
                for word in words {
                    if let last = current.last, int(word["start"]) - int(last["end"]) >= 1500 { flush() }
                    current.append(word)
                }
                flush()
                return pieces
            }
        }
        // 没有分说话人的结果时，退回整段文字
        guard let text = result["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let words = result["words"] as? [[String: Any]] ?? []
        return [Piece(speaker: nil, startMs: int(words.first?["start"]), endMs: int(words.last?["end"]), text: text)]
    }

    // MARK: - 本地：系统自带的 SpeechAnalyzer，离线，分不出说话人

    static func local(file: URL, locale: Locale, terms: [String]) async throws -> [Piece] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppError("本地转写不支持语言 \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: terms]
            try? await analyzer.setContext(context)
        }
        let collector = Task { () -> [Piece] in
            var pieces: [Piece] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                pieces.append(Piece(speaker: nil, startMs: milliseconds(result.range.start),
                                    endMs: milliseconds(result.range.end), text: text))
            }
            return pieces
        }
        let audio = try AVAudioFile(forReading: file)
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return merge(try await collector.value, joiner: locale.language.languageCode?.identifier == "zh" ? "" : " ")
    }

    /// 本地转写是一句一句出的：把停顿很短的相邻句子并成一段发言
    private static func merge(_ pieces: [Piece], joiner: String) -> [Piece] {
        var merged: [Piece] = []
        for piece in pieces {
            if var last = merged.last, piece.startMs - last.endMs < 1500, last.text.count < 500 {
                last.text += joiner + piece.text
                last.endMs = piece.endMs
                merged[merged.count - 1] = last
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    private static func milliseconds(_ time: CMTime) -> Int {
        time.isNumeric ? Int(CMTimeGetSeconds(time) * 1000) : 0
    }
}
