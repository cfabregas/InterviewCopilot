import Foundation

/// 国内线路的大模型：阿里云百炼的对话补全接口(流式)。默认用通义千问，也能填百炼上的其他模型名，比如 DeepSeek、Kimi、GLM。
/// 文档：https://help.aliyun.com/zh/model-studio/use-qwen-by-calling-api
struct QwenLLM: LLMClient {
    let apiKey: String
    /// 检测新模型时用：不管档位，固定调这个模型
    var modelOverride: String?

    func stream(system: String, user: String, tier: LLMTier) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await send(system: system, user: user, tier: tier, thinking: false, to: continuation)
                    } catch let error as LLMHTTPError where error.status == 400 && error.body.contains("enable_thinking") {
                        // 有的模型(比如 glm-5.3)不允许关掉深度思考，只好开着重试；思考内容不输出，首字会慢很多
                        try await send(system: system, user: user, tier: tier, thinking: true, to: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func send(system: String, user: String, tier: LLMTier, thinking: Bool,
                      to continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let body: [String: Any] = [
            "model": modelOverride ?? LLMModels.name(.qwen, tier),
            "stream": true,
            // 实时场景要的是快：能关就关掉深度思考
            "enable_thinking": thinking,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await SSE.run(request) { data in
            guard let event = parseJSON(data),
                  let choice = (event["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any],
                  let text = delta["content"] as? String, !text.isEmpty else { return }
            continuation.yield(text)
        }
    }
}
