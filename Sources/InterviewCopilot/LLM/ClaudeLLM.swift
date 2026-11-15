import Foundation

/// 海外线路的大模型：Claude Messages API(流式)。Swift 没有官方 SDK，直接走 HTTP。
/// 文档：https://platform.claude.com/docs/en/api/messages
struct ClaudeLLM: LLMClient {
    let apiKey: String

    func stream(system: String, user: String, tier: LLMTier) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await run(system: system, user: user, tier: tier, withFallbacks: tier == .strong, continuation)
                    } catch let error as LLMHTTPError where error.status == 400 && tier == .strong {
                        // 拒答回退是测试版参数，被拒绝时去掉它重试一次
                        Log.write("Claude 不接受回退参数，去掉后重试：\(error.body.prefix(160))")
                        try await run(system: system, user: user, tier: tier, withFallbacks: false, continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(system: String, user: String, tier: LLMTier, withFallbacks: Bool,
                     _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var body: [String: Any] = [
            "model": tier == .fast ? "claude-haiku-5-5" : "claude-sonnet-5-5",
            "max_tokens": tier == .fast ? 2_000 : 8_000,
            "stream": true,
            // 系统提示(规则加简历)每次都一样，打开缓存：后续请求更快也更便宜
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
            // 实时场景要的是快：低投入档
            "output_config": ["effort": "low"],
        ]
        if tier == .fast {
            body["thinking"] = ["type": "disabled"]
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if withFallbacks {
            // 模型的安全分类器拒答时，由服务端自动换模型重试
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await SSE.run(request) { data in
            guard let event = parseJSON(data), let type = event["type"] as? String else { return }
            switch type {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    continuation.yield(text)
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                    throw AppError("模型拒绝回答这个问题")
                }
            case "error":
                throw AppError("Claude 返回错误：\(data.prefix(300))")
            default:
                break
            }
        }
    }
}
