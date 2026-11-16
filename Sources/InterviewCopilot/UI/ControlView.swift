import SwiftUI
import UniformTypeIdentifiers
import Translation

@MainActor
final class LogStore: ObservableObject {
    @Published var text = ""

    func append(_ line: String) {
        text += line
        if text.count > 40_000 { text = String(text.suffix(30_000)) }
    }
}

/// 主窗口：开始和结束会话，以及简历、复盘、模拟面试、设置几个入口。线路、密钥、外观都在设置窗口里。
struct ControlView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var log: LogStore
    @ObservedObject var answers: AnswerEngine
    @ObservedObject var resume: ResumeStore
    @ObservedObject var checkup: Checkup
    @ObservedObject private var hotKeys = HotKeys.shared
    var openReview: () -> Void = {}
    var openMock: () -> Void = {}
    var openSettings: (String?) -> Void = { _ in }

    @State private var showingResumeManager = false
    /// 日志区域是否展开(记住上次的选择)
    @AppStorage("showLog") private var showLog = true
    @State private var downloadConfig: TranslationSession.Configuration?
    /// 热词表：提高专有名词的转写准确率，下次开始听译时生效
    @AppStorage(Terms.defaultsKey) private var terms = ""
    /// 实际生效的热词数(手动的加两份简历的，去重后)
    private var termCount: Int {
        _ = terms; _ = resume.terms
        return Terms.load().count
    }

    /// 收起日志时把窗口缩到刚好放下控件，展开时恢复高度；窗口顶边保持不动
    private func resizeWindowForLog() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == "面试助手" }),
                  let content = window.contentView else { return }
            let target = showLog ? max(content.fittingSize.height, 520) : content.fittingSize.height
            var frame = window.frame
            let delta = target - window.contentLayoutRect.height
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true, animate: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("听译方向", selection: $controller.mode) {
                    ForEach(LanguageMode.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 240)
                .disabled(controller.isRunning || controller.isBusy)

                Button(controller.isRunning ? "结束" : "开始听译") {
                    Task {
                        if controller.isRunning { await controller.stop() } else { await controller.start() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isBusy)

                Text(controller.status).foregroundStyle(.secondary)
                Spacer()
                Button("设置…") { openSettings(nil) }
            }

            // 权限或密钥有问题时在这里提醒，点进去处理
            if !checkup.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(checkup.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                    }
                    Button("去处理…") { openSettings("checkup") }
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
            }

            HStack {
                Toggle("实时答案", isOn: $answers.enabled)
                Text("\(hotKeys.display(.answer)) 回答上一句，\(hotKeys.display(.dismiss)) 关闭答案")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("简历与热词…") { showingResumeManager = true }
                Text(ResumeSlot.allCases.map { "\($0.title)\(resume.texts[$0] == nil ? "未导入" : "已导入")" }.joined(separator: "，")
                     + "，热词 \(termCount) 个")
                    .foregroundStyle(.secondary)
            }
            // 调试用：启动后直接打开管理界面，方便截图检查
            .onAppear { if CommandLine.arguments.contains("--show-resume-manager") { showingResumeManager = true } }
            .sheet(isPresented: $showingResumeManager) {
                ResumeManagerView(resume: resume, answers: answers, locked: controller.isRunning) {
                    showingResumeManager = false
                }
            }

            HStack {
                Button("历史与复盘…") { openReview() }
                Button("模拟面试…") { openMock() }.disabled(controller.isRunning)
            }

            if controller.translationNeedsDownload {
                HStack {
                    Text("翻译语言包未安装，当前只能转写。")
                    Button("下载翻译语言包") {
                        downloadConfig = TranslationSession.Configuration(source: controller.mode.sourceLanguage,
                                                                          target: controller.mode.targetLanguage)
                    }
                }
            }

            HStack {
                Text("开始后悬浮窗出现，主窗口收进程序坞；结束后恢复。\(hotKeys.display(.end)) 结束，\(hotKeys.display(.toggleOverlay)) 显示或隐藏悬浮窗，\(hotKeys.display(.clickThrough)) 切换鼠标穿透。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出应用") { NSApp.terminate(nil) }
            }

            HStack(spacing: 4) {
                Button {
                    showLog.toggle()
                    resizeWindowForLog()
                } label: {
                    Label("日志", systemImage: showLog ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showLog ? "收起日志" : "展开日志")
                Spacer()
            }

            if showLog {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: log.text) { proxy.scrollTo("end") }
            }
            .frame(minHeight: 160)
            .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: showLog ? 440 : nil, alignment: .top)
        // 上次是收起状态时，启动后也把窗口缩到合适的高度
        .onAppear {
            checkup.refresh()
            if !showLog { resizeWindowForLog() }
        }
        .translationTask(downloadConfig) { session in
            do {
                try await session.prepareTranslation()
                controller.translationNeedsDownload = false
                Log.write("翻译语言包已就绪，下次开始听译时生效")
            } catch {
                Log.write("翻译语言包下载未完成：\(error)")
            }
        }
    }
}
