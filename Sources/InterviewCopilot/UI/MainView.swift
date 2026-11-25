import SwiftUI

/// 主窗口里的几个页面
enum Page: String, CaseIterable, Identifiable {
    case listen, mock, review, resume, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listen: return L("面试助手")
        case .mock: return L("模拟面试")
        case .review: return L("历史复盘")
        case .resume: return L("简历管理")
        case .settings: return L("设置")
        }
    }

    var symbol: String {
        switch self {
        case .listen: return "captions.bubble"
        case .mock: return "person.wave.2"
        case .review: return "list.bullet.rectangle"
        case .resume: return "doc.text"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// 当前显示哪一页，以及面试是从什么时候开始的(用来显示计时)
@MainActor
final class Navigator: ObservableObject {
    @Published var page: Page = {
        let argument = CommandLine.arguments.first { $0.hasPrefix("--page=") }.map { String($0.dropFirst(7)) }
        return argument.flatMap(Page.init(rawValue:)) ?? .listen
    }()
    @Published var runningSince: Date?
}

/// 主窗口：系统原生的侧栏(macOS 26 起是浮在内容上的玻璃)，右边是页面
struct MainView: View {
    @ObservedObject var navigator: Navigator
    @ObservedObject var controller: SessionController
    @ObservedObject var settings: OverlaySettings
    @ObservedObject var log: LogStore
    @ObservedObject var answers: AnswerEngine
    @ObservedObject var resume: ResumeStore
    @ObservedObject var checkup: Checkup
    @ObservedObject var post: PostProcessor
    @ObservedObject var reviewModel: ReviewModel
    @ObservedObject var mock: MockInterview
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var toasts = ToastCenter.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: L10n.shared.isSource ? 180 : 220)
                .navigationSplitViewColumnWidth(min: L10n.shared.isSource ? 180 : 220, ideal: L10n.shared.isSource ? 200 : 230, max: 300)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch navigator.page {
                case .listen:
                    ListenPage(navigator: navigator, controller: controller, log: log, answers: answers, resume: resume, checkup: checkup)
                case .mock:
                    MockInterviewView(mock: mock, resume: resume, navigator: navigator) { id in
                        reviewModel.selectedID = id
                        navigator.page = .review
                    }
                case .review:
                    ReviewView(model: reviewModel, post: post)
                case .resume:
                    ResumeManagerView(resume: resume, answers: answers, locked: controller.isRunning)
                case .settings:
                    SettingsView(controller: controller, settings: settings, answers: answers, resume: resume, checkup: checkup)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Backdrop())
            // 只让内容顶到标题栏，左边要给浮起来的侧栏让位
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .navigationSplitViewStyle(.balanced)
        // 轻提示相对整个窗口居中，不跟着右边内容区偏
        .toast($toasts.message)
        .onChange(of: navigator.page) {
            if navigator.page == .review { reviewModel.reload() }
            if navigator.page == .settings { checkup.refresh() }
        }
        // 换语言后整个界面重建一遍
        .id(l10n.code)
        .frame(minWidth: 1040, minHeight: 680)
    }

    private var selection: Binding<Page?> {
        Binding(get: { navigator.page }, set: { if let page = $0 { navigator.page = page } })
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section {
                ForEach([Page.listen, .mock, .review, .resume]) { row($0) }
            } header: {
                Text(L("千人千面")).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.bottom, 10)
            }
            .collapsible(false)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if let release = updates.available { updateBanner(release) }
                if !checkup.problems.isEmpty {
                    Button {
                        UserDefaults.standard.set("checkup", forKey: "settingsTab")
                        navigator.page = .settings
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.cue)
                            Text(L("有 %@ 项需要处理", "\(checkup.problems.count)")).foregroundStyle(Theme.ink)
                        }
                        .font(.system(size: 12))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cue.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                }
                languageMenu
                settingsButton
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private func row(_ page: Page) -> some View {
        HStack(spacing: 0) {
            Label(page.title, systemImage: page.symbol).lineLimit(1)
            Spacer()
            if page == .review, post.running != nil {
                ProgressView().controlSize(.mini)
            } else if isLive(page) {
                TallyLamp(on: true, size: 7)
            }
        }
        .tag(page)
    }

    /// 有新版本时显示在侧栏底部：点主体去下载页，右上角的叉号忽略这个版本
    private func updateBanner(_ release: UpdateChecker.Release) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("有新版本 %@", release.version)).foregroundStyle(Theme.ink)
                Text(L("点这里下载")).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button {
                updates.skip()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("忽略这个版本"))
        }
        .font(.system(size: 12))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { updates.openDownloadPage() }
        .help(L("打开下载页"))
        .padding(.bottom, 6)
    }

    /// 设置放在侧栏底部，选中时和上面的列表一样高亮
    private var settingsButton: some View {
        let selected = navigator.page == .settings
        return Button {
            navigator.page = .settings
        } label: {
            Label(Page.settings.title, systemImage: Page.settings.symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.accent : Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accent.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 界面语言：选项来自语言文件，加一个文件就多一项
    private var languageMenu: some View {
        Menu {
            Picker("", selection: $l10n.choice) {
                Text(L("跟随系统")).tag("")
                ForEach(l10n.languages) { Text($0.name).tag($0.code) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe").frame(width: 18)
                Text(l10n.choice.isEmpty ? L("跟随系统") : (l10n.languages.first { $0.code == l10n.choice }?.name ?? l10n.choice))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(L("界面语言"))
    }

    private func isLive(_ page: Page) -> Bool {
        (page == .listen && controller.isRunning) || (page == .mock && mock.isActive)
            || (page == .review && post.running != nil)
    }
}
