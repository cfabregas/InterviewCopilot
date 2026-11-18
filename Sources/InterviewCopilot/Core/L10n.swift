import Foundation

/// 界面语言。源文字是简体中文：代码里直接写中文，L("中文") 在别的语言下去语言文件里查译文，查不到就显示中文。
///
/// 加一种语言不用改代码：往 Localizations 目录放一个 <语言代码>.json 即可，例如 ja.json。文件是一个 JSON 对象：
/// - "_name"：这种语言在设置里显示的名字，如 "日本語"
/// - "_promptName"：告诉大模型用什么语言写内容时用的中文叫法，如 "日文"
/// - 其余每一项的键是中文源文字，值是译文。带参数的文字用 %@ 占位，语序不同时可以写成 %1$@、%2$@。
/// 目录有两处：应用包里的 Contents/Resources/Localizations(随应用发布)，
/// 和应用数据目录下的 Localizations(自己加的放这里，同名文件优先于应用包里的)。
final class L10n: ObservableObject {
    static let shared = L10n()
    static let source = "zh-Hans"
    private static let defaultsKey = "appLanguage"

    struct Language: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// 用户的选择：空字符串表示跟随系统
    @Published var choice: String {
        didSet {
            UserDefaults.standard.set(choice, forKey: Self.defaultsKey)
            resolve()
        }
    }
    /// 实际生效的语言代码
    @Published private(set) var code = L10n.source
    private(set) var languages: [Language] = [Language(code: L10n.source, name: "简体中文")]
    private var tables: [String: [String: String]] = [:]
    private var table: [String: String] = [:]

    private init() {
        var initial = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        for argument in CommandLine.arguments where argument.hasPrefix("--lang=") {
            initial = String(argument.dropFirst(7))   // 调试用：只在本次运行里换语言，不写进偏好设置
        }
        // 直接设底层存储，不触发 didSet，否则调试参数会被当成用户的选择保存下来
        _choice = Published(initialValue: initial)
        load()
        resolve()
    }

    private func load() {
        let directories = [Bundle.main.resourceURL?.appendingPathComponent("Localizations"),
                           AppPaths.root.appendingPathComponent("Localizations")].compactMap { $0 }
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let entries = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { continue }
                let code = file.deletingPathExtension().lastPathComponent
                tables[code] = (tables[code] ?? [:]).merging(entries) { _, new in new }
            }
        }
        for code in tables.keys.sorted() where code != Self.source {
            languages.append(Language(code: code, name: tables[code]?["_name"] ?? code))
        }
    }

    /// 跟随系统时，按系统的首选语言顺序找第一个支持的；都不支持就用中文
    private func resolve() {
        let available = Set(languages.map(\.code))
        var resolved = Self.source
        if available.contains(choice) {
            resolved = choice
        } else {
            for preferred in Locale.preferredLanguages {
                if preferred.hasPrefix("zh") { break }
                if let match = available.first(where: { $0 != Self.source && preferred.hasPrefix($0) }) {
                    resolved = match
                    break
                }
            }
        }
        code = resolved
        table = tables[resolved] ?? [:]
    }

    var isSource: Bool { code == Self.source }

    func translate(_ key: String) -> String { table[key] ?? key }

    /// 让大模型用界面语言写内容时，加在提示词后面的一句话；中文界面下为空
    var promptNote: String {
        guard !isSource else { return "" }
        let name = table["_promptName"] ?? code
        return "\n\n注意：上面要求的小标题、\"标题：\"和 JSON 字段名保持原样不要翻译；凡是要求用中文写的内容，一律改用\(name)书写。"
    }
}

/// 取一段界面文字在当前语言下的写法。带参数时按 String(format:) 的规则填入。
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = L10n.shared.translate(key)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

/// 数据库里存的是中文的题型、说话人标签和纪要小标题，显示时换成当前语言
enum Localized {
    static func speaker(_ label: String) -> String {
        if label.hasPrefix("面试官") { return L("面试官") + label.dropFirst(3) }
        return L(label)
    }
}
