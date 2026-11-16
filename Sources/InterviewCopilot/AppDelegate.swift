import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let resume = ResumeStore()
    private lazy var answers = AnswerEngine(resume: resume)
    private lazy var controller = SessionController(answers: answers)
    private lazy var post = PostProcessor(answers: answers)
    private let reviewModel = ReviewModel()
    private var reviewWindow: NSWindow?
    private var cardObserver: AnyCancellable?
    private var runningObserver: AnyCancellable?
    private let settings = OverlaySettings()
    private let logStore = LogStore()
    private var overlay: OverlayPanel!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.sink = { [weak self] line in self?.logStore.append(line) }

        overlay = OverlayPanel(content: SubtitleOverlayView(controller: controller, settings: settings, answers: answers))
        settings.panel = overlay
        overlay.ignoresMouseEvents = settings.clickThrough   // 默认鼠标穿透，⌃⌥T 切换

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "面试助手"
        window.contentView = NSHostingView(rootView: ControlView(controller: controller, settings: settings, log: logStore,
                                                                  answers: answers, resume: resume,
                                                                  openReview: { [weak self] in self?.showReview() }))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        installMainMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        HotKeys.shared.register(keyCode: kVK_ANSI_H, modifiers: controlKey | optionKey) { [weak self] in
            self?.settings.visible.toggle()
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.settings.clickThrough.toggle()
        }

        HotKeys.shared.register(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey) { [weak self] in
            self?.answers.answerLastTurn()
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_X, modifiers: controlKey | optionKey) { [weak self] in
            self?.answers.dismissCard()
        }
        // 结束面试：和主窗口的"结束"按钮一样。主窗口最小化时不用先把它找回来。
        HotKeys.shared.register(keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey) { [weak self] in
            guard let self, self.controller.isRunning else { return }
            Task { await self.controller.stop() }
        }
        // 开始后才显示悬浮窗并把主窗口收进程序坞；结束(不管从哪里结束)就收起悬浮窗、把主窗口拿回来
        runningObserver = controller.$isRunning.removeDuplicates().dropFirst().sink { [weak self] running in
            guard let self else { return }
            self.settings.sessionActive = running
            if running {
                self.window.miniaturize(nil)
            } else {
                self.window.deminiaturize(nil)
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Log.write("窗口切换：面试\(running ? "开始" : "结束")，悬浮窗\(self.overlay.isVisible ? "显示" : "收起")，主窗口\(self.window.isMiniaturized ? "已最小化" : "显示")")
        }
        // 答案卡出现时悬浮窗不够高就向下撑开(保持顶边不动)，否则答案会被裁掉
        cardObserver = answers.$card.map { $0 != nil }.removeDuplicates().sink { [weak self] showing in
            guard showing, let panel = self?.overlay, panel.frame.height < 460 else { return }
            var frame = panel.frame
            frame.origin.y -= 460 - frame.height
            frame.size.height = 460
            panel.setFrame(frame, display: true, animate: false)
        }

        // 会话结束后自动做会后处理(可在主窗口关掉)；太短或什么都没听到的不处理
        controller.onSessionEnded = { [weak self] id in
            guard let self, !CommandLine.arguments.contains("--autotest"),
                  UserDefaults.standard.object(forKey: "autoPostProcess") as? Bool ?? true,
                  let session = Store.shared?.session(id), session.segmentCount > 0 else { return }
            Task { await self.post.process(id) }
        }

        Log.write("启动，系统 \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // 调试用：让悬浮窗出现在截屏里，方便检查布局
        if CommandLine.arguments.contains("--visible-in-capture") { settings.hideFromSharing = false }

        if CommandLine.arguments.contains("--autotest") {
            Task { await runAutotest() }
        }
        // 自测：检测可用的通义千问模型，结果写进日志后退出
        if CommandLine.arguments.contains("--probe-models") {
            Task {
                guard let key = KeyStore.get(LLMLine.qwen.keyAccount) else { NSApp.terminate(nil); return }
                for result in await ModelProbe.run(apiKey: key) {
                    Log.write("模型检测：\(result.model) 首字 \(result.firstTokenMs) 毫秒\(result.listed ? "" : "(不在模型列表里)")")
                }
                Log.write("=== 模型检测结束 ===")
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSApp.terminate(nil)
            }
        }
        if let dir = CommandLine.arguments.first(where: { $0.hasPrefix("--post-test=") })?.dropFirst(12) {
            Task { await runPostTest(URL(fileURLWithPath: String(dir))) }
        } else if CommandLine.arguments.contains("--show-review") {
            showReview()
        }
    }

    /// 打开历史与复盘窗口
    func showReview() {
        if reviewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "历史与复盘"
            window.contentView = NSHostingView(rootView: ReviewView(model: reviewModel, post: post))
            window.isReleasedWhenClosed = false
            window.center()
            reviewWindow = window
        }
        reviewModel.reload()
        reviewWindow?.makeKeyAndOrderFront(nil)
    }

    /// 自测：把一个目录里的 system.m4a / mic.m4a 当作一场刚结束的面试，跑一遍会后处理
    private func runPostTest(_ source: URL) async {
        guard let store = Store.shared else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = AppPaths.sessions.appendingPathComponent(formatter.string(from: Date()) + "-posttest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var seconds = 0.0
        for name in ["system.m4a", "mic.m4a"] {
            let from = source.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try? FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(name))
            if name == "system.m4a", let file = try? AVAudioFile(forReading: from) {
                seconds = Double(file.length) / file.processingFormat.sampleRate
            }
        }
        let mode: LanguageMode = CommandLine.arguments.contains("--mode=zh") ? .zhToEn : .enToZh
        let id = store.createSession(mode: mode.rawValue, dir: dir.path)
        let now = Date()
        store.setAudioStart(session: id, system: now, mic: now)
        store.run("UPDATE session SET ended_at = started_at + ? WHERE id = ?", [seconds, id])
        Log.write("=== 会后处理自测开始：录音 \(Int(seconds)) 秒 ===")
        await post.process(id)
        for utterance in store.utterances(session: id) {
            Log.write("  [\(Exporter.clock(utterance.startMs))] \(utterance.speaker)：\(utterance.text.prefix(90)) ‖ \(utterance.translation.prefix(50))")
        }
        for item in store.qaItems(session: id) {
            Log.write("  问答 \(item.idx + 1) [\(item.kind)，评分 \(item.score)] \(item.question) ‖ 我的回答 \(item.myAnswer.count) 字，参考答案 \(item.reference.count) 字")
        }
        Log.write("  纪要：\n\(store.summary(session: id))")
        if let session = store.session(id) {
            let markdown = Exporter.markdown(session: session, summary: store.summary(session: id),
                                             qa: store.qaItems(session: id), utterances: store.utterances(session: id))
            try? markdown.write(to: dir.appendingPathComponent("export.md"), atomically: true, encoding: .utf8)
            do {
                try Exporter.writePDF(markdown: markdown, to: dir.appendingPathComponent("export.pdf"))
                Log.write("  导出自测：Markdown \(markdown.count) 字，PDF 已写入 \(dir.path)")
            } catch {
                Log.write("  导出自测失败：\(error)")
            }
        }
        Log.write("=== 会后处理自测结束 ===")
        if CommandLine.arguments.contains("--show-review") {
            reviewModel.selectedID = id
            showReview()
        } else {
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }

    /// 手写的应用没有默认菜单：没有它就没有 ⌘Q，输入框里也不能 ⌘V 粘贴。
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏面试助手", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出面试助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// 关掉主窗口就退出整个应用(否则只剩悬浮窗，没有地方可以退出)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRunning else { return .terminateNow }
        Task {
            await controller.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 自测：启动会话，用系统语音朗读几句英文面试问题，检查转写和翻译，然后退出。
    private func runAutotest() async {
        Log.write("=== 自测开始 ===")
        controller.recordMic = false
        // --resume=<文件>：只在本次自测里使用这份简历，不覆盖已导入的
        if let path = CommandLine.arguments.first(where: { $0.hasPrefix("--resume=") })?.dropFirst(9) {
            do {
                try resume.load(from: URL(fileURLWithPath: String(path)), slot: .zh, persist: false)
                if let llm = answers.llmLine.makeClient() { await resume.extractTerms(.zh, using: llm, persist: false) }
            } catch {
                Log.write("自测简历读取失败：\(error)")
            }
        }
        // --qa：每段之间多停一会儿，让答案有时间生成完
        let pauseSeconds: UInt64 = CommandLine.arguments.contains("--qa") ? 14 : 0
        let chinese = CommandLine.arguments.contains("--mode=zh")   // 中文朗读，测中文听写
        controller.mode = chinese ? .zhToEn : .enToZh
        await controller.start()
        guard controller.isRunning else {
            Log.write("=== 自测失败：会话没有启动 ===")
            NSApp.terminate(nil)
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let chineseSentences = [
            "感谢你今天来参加面试。请先介绍一下你最近做过的一个有挑战性的项目。",
            "你和同事在技术方案上有分歧的时候，是怎么处理的？",
            "我们聊聊系统设计。如果让你给分布式网关设计一个限流器，你会怎么做？",
        ]
        let englishSentences = [
            "Thanks for joining us today. Could you start by telling me about a challenging project you worked on recently?",
            "How did you handle disagreements with your teammates about the technical design?",
            "Let's talk about system design. How would you design a rate limiter for a distributed API gateway?",
        ]
        for sentence in chinese ? chineseSentences : englishSentences {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-v", chinese ? "Tingting" : "Samantha", "-r", "175", sentence]
                say.terminationHandler = { _ in continuation.resume() }
                Log.write("朗读开始")
                do { try say.run() } catch { continuation.resume() }
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000 + pauseSeconds * 1_000_000_000)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await controller.stop()

        let finals = controller.lines.filter(\.isFinal)
        let translated = finals.filter { !$0.translation.isEmpty }
        Log.write("自测结果：定稿句段 \(finals.count) 条，其中有译文 \(translated.count) 条")
        Log.write("=== 自测结束 ===")
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }
}
