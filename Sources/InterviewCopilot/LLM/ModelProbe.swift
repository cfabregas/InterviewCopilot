import Foundation

/// 检测通义千问有没有比当前更新的模型可用，顺带检测百炼上 DeepSeek 和 Kimi 的最新版本。
/// 官方没有可靠的"最新"别名，模型列表接口也会比实际上线晚，所以两头都查：
/// 列表里有的拿来试，列表里没有但版本号更高的名字也猜着试，能调通的才算数。
enum ModelProbe {
    /// 一个系列的模型：名字是 前缀 + 版本号 + 可选的 "-档位"，比如 qwen3.8-max、deepseek-v4.1-flash、kimi-k3
    struct Family {
        let title: String
        let prefix: String
        let grades: [String]       // 空字符串表示名字不带档位
        let floor: Double          // 版本号低于这个的不试
        let showAll: Bool          // false 时每个档位只留能调通的最新一个
    }

    struct Result: Identifiable, Hashable {
        var id: String { model }
        let model: String
        let family: String
        let version: Double
        let grade: String
        let firstTokenMs: Int      // 首字延迟
        let listed: Bool           // 是否出现在账号的模型列表里
    }

    static let qwenTitle = "qwen"

    /// 要检测的系列；千问的下限跟着当前在用的版本走
    static func families() -> [Family] {
        let current = LLMTier.allCases.compactMap { parse(LLMModels.name(.qwen, $0))?.version }
        return [
            Family(title: qwenTitle, prefix: "qwen", grades: ["max", "plus", "flash"], floor: current.min() ?? 3.8, showAll: true),
            Family(title: "deepseek", prefix: "deepseek-v", grades: ["flash", "pro"], floor: 4, showAll: false),
            Family(title: "kimi", prefix: "kimi-k", grades: ["", "pro"], floor: 3, showAll: false),
        ]
    }

    /// 按系列解析名字："deepseek-v4.1-flash" → (4.1, "flash")；带日期、preview 或其他用途的型号不算
    static func parse(_ id: String, in family: Family) -> (version: Double, grade: String)? {
        guard id.hasPrefix(family.prefix) else { return nil }
        let parts = id.dropFirst(family.prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isNumber || $0 == "." }), let version = Double(parts[0]) else { return nil }
        let grade = parts.count == 2 ? String(parts[1]) : ""
        guard family.grades.contains(grade) else { return nil }
        return (version, grade)
    }

    /// 千问名字的解析："qwen3.8-max" → (3.8, "max")
    static func parse(_ id: String) -> (version: Double, grade: String)? {
        parse(id, in: Family(title: qwenTitle, prefix: "qwen", grades: ["max", "plus", "flash"], floor: 0, showAll: true))
    }

    static func name(_ family: Family, version: Double, grade: String) -> String {
        let text = version == version.rounded() ? String(Int(version)) : String(format: "%.1f", version)
        return family.prefix + text + (grade.isEmpty ? "" : "-\(grade)")
    }

    /// 要试的模型名：列表里版本号不低于下限的，加上往上猜的几个版本
    static func candidates(_ family: Family, listed: [String]) -> [String] {
        let known = listed.compactMap { parse($0, in: family)?.version }
        let top = max(known.max() ?? family.floor, family.floor)
        let major = top.rounded(.down)
        var versions = Set(known.filter { $0 >= family.floor })
        versions.insert(family.floor)
        for guess in [top + 0.1, top + 0.2, major + 1, major + 1.1, major + 1.5, major + 2] {
            versions.insert((guess * 10).rounded() / 10)
        }
        return versions.sorted(by: >).flatMap { version in family.grades.map { name(family, version: version, grade: $0) } }
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

    /// 返回能调通的模型：千问在前、版本新的在前；DeepSeek 和 Kimi 每个档位只留最新的
    static func run(apiKey: String) async -> [Result] {
        let listed = await listModels(apiKey: apiKey)
        let listedSet = Set(listed)
        let families = families()
        var results: [Result] = []
        await withTaskGroup(of: Result?.self) { group in
            for family in families {
                for model in candidates(family, listed: listed) {
                    group.addTask {
                        guard let parsed = parse(model, in: family),
                              let ms = await firstTokenMs(model: model, apiKey: apiKey) else { return nil }
                        return Result(model: model, family: family.title, version: parsed.version, grade: parsed.grade,
                                      firstTokenMs: ms, listed: listedSet.contains(model))
                    }
                }
            }
            for await result in group { if let result { results.append(result) } }
        }

        var shown: [Result] = []
        for family in families {
            let mine = results.filter { $0.family == family.title }
            for grade in family.grades {
                let sorted = mine.filter { $0.grade == grade }.sorted { $0.version > $1.version }
                shown += family.showAll ? sorted : Array(sorted.prefix(1))
            }
        }
        // 每个系列内部按版本新到旧，同一版本按档位顺序
        return shown.sorted { a, b in
            let fa = families.firstIndex { $0.title == a.family }!, fb = families.firstIndex { $0.title == b.family }!
            if fa != fb { return fa < fb }
            if a.version != b.version { return a.version > b.version }
            let grades = families[fa].grades
            return grades.firstIndex(of: a.grade)! < grades.firstIndex(of: b.grade)!
        }
    }
}
