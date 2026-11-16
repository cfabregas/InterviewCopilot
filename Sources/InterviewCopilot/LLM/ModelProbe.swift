import Foundation

/// 检测通义千问有没有比当前更新的模型可用。
/// 官方没有可靠的"最新"别名，模型列表接口也会比实际上线晚，所以两头都查：
/// 列表里有的拿来试，列表里没有但版本号更高的名字也猜着试，能调通的才算数。
enum ModelProbe {
    struct Result: Identifiable, Hashable {
        var id: String { model }
        let model: String
        let version: Double
        let grade: String          // max、plus、flash
        let firstTokenMs: Int      // 首字延迟
        let listed: Bool           // 是否出现在账号的模型列表里
    }

    static let grades = ["max", "plus", "flash"]

    /// "qwen3.8-max" → (3.8, "max")；带日期、preview 或其他用途的型号不算
    static func parse(_ id: String) -> (version: Double, grade: String)? {
        guard id.hasPrefix("qwen") else { return nil }
        let parts = id.dropFirst(4).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, grades.contains(String(parts[1])),
              parts[0].allSatisfy({ $0.isNumber || $0 == "." }), let version = Double(parts[0]) else { return nil }
        return (version, String(parts[1]))
    }

    static func name(version: Double, grade: String) -> String {
        let text = version == version.rounded() ? String(Int(version)) : String(format: "%.1f", version)
        return "qwen\(text)-\(grade)"
    }

    /// 要试的模型名：列表里版本号不低于 floor 的，加上往上猜的几个版本
    static func candidates(listed: [String], floor: Double) -> [String] {
        let known = listed.compactMap { id in parse(id).map { (id, $0.version) } }
        let top = max(known.map(\.1).max() ?? floor, floor)
        let major = top.rounded(.down)
        var versions = Set(known.map(\.1).filter { $0 >= floor })
        versions.insert(floor)
        for guess in [top + 0.1, top + 0.2, major + 1, major + 1.1, major + 1.5, major + 2] {
            versions.insert((guess * 10).rounded() / 10)
        }
        return versions.sorted(by: >).flatMap { version in grades.map { name(version: version, grade: $0) } }
    }

    static func listModels(apiKey: String) async -> [String] {
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/models")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }
    }

    /// 试调一次，返回首字延迟(毫秒)；调不通返回 nil
    static func firstTokenMs(model: String, apiKey: String) async -> Int? {
        let client = QwenLLM(apiKey: apiKey, modelOverride: model)
        let began = Date()
        do {
            for try await _ in client.stream(system: "你是一个助手。", user: "用一句话介绍一下你自己。", tier: .fast) {
                return Int(Date().timeIntervalSince(began) * 1000)
            }
        } catch {}
        return nil
    }

    /// 返回所有能调通的模型，版本新的在前
    static func run(apiKey: String) async -> [Result] {
        let listed = await listModels(apiKey: apiKey)
        let current = LLMTier.allCases.compactMap { parse(LLMModels.name(.qwen, $0))?.version }
        let floor = current.min() ?? 3.8
        let names = candidates(listed: listed, floor: floor)
        let listedSet = Set(listed)
        var results: [Result] = []
        await withTaskGroup(of: Result?.self) { group in
            for model in names {
                group.addTask {
                    guard let parsed = parse(model), let ms = await firstTokenMs(model: model, apiKey: apiKey) else { return nil }
                    return Result(model: model, version: parsed.version, grade: parsed.grade, firstTokenMs: ms,
                                  listed: listedSet.contains(model))
                }
            }
            for await result in group { if let result { results.append(result) } }
        }
        return results.sorted {
            $0.version != $1.version ? $0.version > $1.version
                : grades.firstIndex(of: $0.grade)! < grades.firstIndex(of: $1.grade)!
        }
    }
}
