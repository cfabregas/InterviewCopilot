import Foundation

/// 国内线路的大模型：阿里云百炼的通义千问(对话补全接口，流式)。
/// 文档：https://help.aliyun.com/zh/model-studio/use-qwen-by-calling-api
struct QwenLLM: LLMClient {
    let apiKey: String

    func stream(system: String, user: String, tier: LLMTier) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        // 3.8 这一代只有 Max 和 Flash 两档，没有 Plus
                        "model": tier == .fast ? "qwen3.8-flash" : "qwen3.8-max",
                        "stream": true,
                        // 实时场景要的是快：关掉深度思考
                        "enable_thinking": false,
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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
