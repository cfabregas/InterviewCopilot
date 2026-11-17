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

/// 主窗口：左边幕布色的侧栏，右边是页面
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

    var body: some View {
        HStack(spacing: 0) {
            sidebar
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
            .background(Theme.paper)
        }
        .tint(Theme.accent)
        // 换语言后整个界面重建一遍
        .id(l10n.code)
        .frame(minWidth: 1040, minHeight: 680)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 给窗口左上角的三个按钮让出位置
            Color.clear.frame(height: 46)
            Text(L("千人千面"))
                .font(Theme.display(20))
                .foregroundStyle(Theme.onCurtain)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)

            ForEach([Page.listen, .mock, .review, .resume]) { item($0) }
            Spacer()

            if !checkup.problems.isEmpty {
                Button {
                    UserDefaults.standard.set("checkup", forKey: "settingsTab")
                    navigator.page = .settings
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.cue)
                        Text(L("有 %@ 项需要处理", "\(checkup.problems.count)")).foregroundStyle(Theme.onCurtain)
                    }
                    .font(.system(size: 12))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            item(.settings)
            Color.clear.frame(height: 12)
        }
        .frame(width: L10n.shared.isSource ? 196 : 216)
        .frame(maxHeight: .infinity)
        .background(Theme.curtain)
    }

    private func isLive(_ page: Page) -> Bool {
        (page == .listen && controller.isRunning) || (page == .mock && mock.isActive)
            || (page == .review && post.running != nil)
    }

    private func item(_ page: Page) -> some View {
        let selected = navigator.page == page
        return Button {
            navigator.page = page
            if page == .review { reviewModel.reload() }
            if page == .settings { checkup.refresh() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).frame(width: 18)
                Text(page.title).lineLimit(1)
                Spacer()
                if page == .review, post.running != nil {
                    ProgressView().controlSize(.mini).colorScheme(.dark)
                } else if isLive(page) {
                    TallyLamp(on: true, size: 7)
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.onCurtain : Theme.onCurtainMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.curtainRaised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
