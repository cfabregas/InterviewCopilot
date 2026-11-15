import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let resume = ResumeStore()
    private lazy var answers = AnswerEngine(resume: resume)
    private lazy var controller = SessionController(answers: answers)
    private var cardObserver: AnyCancellable?
    private let settings = OverlaySettings()
    private let logStore = LogStore()
    private var overlay: OverlayPanel!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.sink = { [weak self] line in self?.logStore.append(line) }

        overlay = OverlayPanel(content: SubtitleOverlayView(controller: controller, settings: settings, answers: answers))
        settings.panel = overlay
        overlay.ignoresMouseEvents = settings.clickThrough   // 默认鼠标穿透，⌃⌥T 切换
        overlay.orderFrontRegardless()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "面试助手"
        window.contentView = NSHostingView(rootView: ControlView(controller: controller, settings: settings, log: logStore,
                                                                  answers: answers, resume: resume))
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
        // 答案卡出现时悬浮窗不够高就向下撑开(保持顶边不动)，否则答案会被裁掉
        cardObserver = answers.$card.map { $0 != nil }.removeDuplicates().sink { [weak self] showing in
            guard showing, let panel = self?.overlay, panel.frame.height < 460 else { return }
            var frame = panel.frame
            frame.origin.y -= 460 - frame.height
            frame.size.height = 460
            panel.setFrame(frame, display: true, animate: false)
        }

        Log.write("启动，系统 \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // 调试用：让悬浮窗出现在截屏里，方便检查布局
        if CommandLine.arguments.contains("--visible-in-capture") { settings.hideFromSharing = false }

        if CommandLine.arguments.contains("--autotest") {
            Task { await runAutotest() }
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
