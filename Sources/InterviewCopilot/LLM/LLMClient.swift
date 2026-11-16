import Foundation

/// 大模型线路。国内用通义千问(复用阿里云百炼的密钥)，海外用 Claude。
enum LLMLine: String, CaseIterable, Identifiable {
    case qwen
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qwen: return "国内：通义千问(用阿里云密钥)"
        case .claude: return "海外：Claude"
        }
    }

    /// 密钥在 KeyStore 里的条目名。通义千问和阿里云转写共用一个百炼密钥。
    var keyAccount: String {
        switch self {
        case .qwen: return "asr.aliyun"
        case .claude: return "llm.claude"
        }
    }

    static var saved: LLMLine {
        for argument in CommandLine.arguments where argument.hasPrefix("--llm=") {
            if let line = LLMLine(rawValue: String(argument.dropFirst(6))) { return line }
        }
        return LLMLine(rawValue: UserDefaults.standard.string(forKey: "llmLine") ?? "") ?? .qwen
    }

    /// 按当前线路建客户端；没填密钥时返回 nil
    func makeClient() -> LLMClient? {
        guard let key = KeyStore.get(keyAccount) else { return nil }
        switch self {
        case .qwen: return QwenLLM(apiKey: key)
        case .claude: return ClaudeLLM(apiKey: key)
        }
    }
}

/// 模型档位：快的用来做分类和抽取，强的用来写答案
enum LLMTier: String, CaseIterable {
    case fast
    case strong

    var title: String { self == .fast ? "快档" : "强档" }
}

/// 每条线路每个档位实际调用的模型名。可以在主窗口里改，留空就用默认值。
enum LLMModels {
    static func defaultName(_ line: LLMLine, _ tier: LLMTier) -> String {
        switch (line, tier) {
        case (.qwen, .fast): return "qwen3.8-flash"
        case (.qwen, .strong): return "qwen3.8-max"
        case (.claude, .fast): return "claude-haiku-5-5"
        case (.claude, .strong): return "claude-sonnet-5-5"
        }
    }

    static func key(_ line: LLMLine, _ tier: LLMTier) -> String { "model.\(line.rawValue).\(tier.rawValue)" }

    static func name(_ line: LLMLine, _ tier: LLMTier) -> String {
        let saved = (UserDefaults.standard.string(forKey: key(line, tier)) ?? "").trimmingCharacters(in: .whitespaces)
        return saved.isEmpty ? defaultName(line, tier) : saved
    }

    static func set(_ name: String, _ line: LLMLine, _ tier: LLMTier) {
        UserDefaults.standard.set(name == defaultName(line, tier) ? "" : name, forKey: key(line, tier))
    }
}

protocol LLMClient {
    /// 流式生成，逐段返回文本
    func stream(system: String, user: String, tier: LLMTier) -> AsyncThrowingStream<String, Error>
}

extension LLMClient {
    /// 一次性拿到完整结果
    func complete(system: String, user: String, tier: LLMTier) async throws -> String {
        var text = ""
        for try await piece in stream(system: system, user: user, tier: tier) { text += piece }
        return text
    }
}

enum SSE {
    /// 发起流式请求，把每个 "data: ..." 事件的内容交给 onData。HTTP 出错时抛出带响应内容的错误。
    static func run(_ request: URLRequest, onData: (String) throws -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("大模型接口没有返回 HTTP 响应") }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 600 { break }
            }
            throw LLMHTTPError(status: http.statusCode, body: body)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data.isEmpty || data == "[DONE]" { continue }
            try onData(data)
        }
    }
}

struct LLMHTTPError: Error, CustomStringConvertible {
    let status: Int
    let body: String
    var description: String { "大模型接口返回 HTTP \(status)：\(body.prefix(300))" }
}
