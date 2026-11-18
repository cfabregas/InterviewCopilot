import AppKit
import Foundation

/// 检查新版本：查 GitHub 上这个项目最新发布的版本号，比本机新就在侧栏提示。
/// 只向 GitHub 发一个公开接口请求，不带任何用户信息。启动时一天最多自动查一次，菜单里可以手动查。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let page: URL
    }

    /// 有比本机新、而且用户没有选择忽略的版本时不为空
    @Published private(set) var available: Release?
    @Published private(set) var checking = false

    private static let api = URL(string: "https://api.github.com/repos/cfabregas/InterviewCopilot/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/cfabregas/InterviewCopilot/releases/latest")!
    private let defaults = UserDefaults.standard

    /// 本机版本。调试时可用 --app-version=0.1.0 假装是旧版本
    let current: String? = {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--app-version=") }) { return String(arg.dropFirst(14)) }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }()

    private init() {
        // 上次查到的新版本先显示出来，不用等联网
        if let version = defaults.string(forKey: "update.latestVersion"),
           let page = defaults.string(forKey: "update.latestPage").flatMap(URL.init(string:)) {
            show(Release(version: version, page: page))
        }
    }

    /// 启动时调用：距离上次检查超过一天才联网
    func checkIfDue() {
        guard current != nil else { return }   // swift run 直接运行时没有版本号，不查
        let last = defaults.object(forKey: "update.lastCheck") as? Date ?? .distantPast
        let force = CommandLine.arguments.contains("--check-update")
        guard force || Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { _ = await check() }
    }

    /// 联网查一次，返回最新发布的版本(失败时抛错)
    @discardableResult
    func check() async -> Result<Release, Error> {
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: Self.api)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("InterviewCopilot", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String else {
                throw AppError(L("GitHub 返回 HTTP %@", "\(status)"))
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
            let release = Release(version: version, page: page)
            defaults.set(Date(), forKey: "update.lastCheck")
            if let current, Self.isNewer(version, than: current) {
                defaults.set(version, forKey: "update.latestVersion")
                defaults.set(page.absoluteString, forKey: "update.latestPage")
                Log.write("发现新版本 \(version)(当前 \(current))")
            } else {
                defaults.removeObject(forKey: "update.latestVersion")
                defaults.removeObject(forKey: "update.latestPage")
            }
            show(release)
            return .success(release)
        } catch {
            Log.write("检查更新失败：\(error)")
            return .failure(error)
        }
    }

    /// 用户点了"忽略这个版本"：之后只在出了更新的版本时再提示
    func skip() {
        guard let available else { return }
        defaults.set(available.version, forKey: "update.skipped")
        self.available = nil
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(available?.page ?? Self.releasesPage)
    }

    /// 菜单里的"检查更新…"：查完弹窗告诉结果
    func checkFromMenu() {
        Task {
            let result = await check()
            let alert = NSAlert()
            switch result {
            case .success(let release):
                if let current, Self.isNewer(release.version, than: current) {
                    alert.messageText = L("有新版本 %@", release.version)
                    alert.informativeText = L("当前是 %@。下载新的 DMG 后把应用拖进「应用程序」替换即可，设置和复盘记录都会保留。", current)
                    alert.addButton(withTitle: L("去下载"))
                    alert.addButton(withTitle: L("以后再说"))
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
                    return
                }
                alert.messageText = L("已经是最新版本")
                alert.informativeText = L("当前版本 %@。", current ?? "")
            case .failure(let error):
                alert.messageText = L("检查更新失败")
                alert.informativeText = "\(error)"
            }
            alert.runModal()
        }
    }

    private func show(_ release: Release) {
        guard let current, Self.isNewer(release.version, than: current),
              defaults.string(forKey: "update.skipped") != release.version else {
            available = nil
            return
        }
        available = release
    }

    /// 按数字逐段比较版本号：0.10.0 比 0.9.1 新
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) in s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
