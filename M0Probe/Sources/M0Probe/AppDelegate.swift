import AppKit

final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlay = OverlayPanel()
    private let tap = SystemAudioTap()
    private var control: NSWindow!
    private var logView: NSTextView!
    private var tapButton: ActionButton!
    private let levelLabel = NSTextField(labelWithString: "电平：—")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildControlWindow()
        Log.sink = { [weak self] line in self?.appendLog(line) }
        overlay.orderFrontRegardless()
        Log.write("启动，系统 \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Log.write("输出目录：\(Log.dir.path)")

        tap.onLevel = { [weak self] rms in
            DispatchQueue.main.async { self?.levelLabel.stringValue = String(format: "电平(RMS)：%.4f", rms) }
        }

        if CommandLine.arguments.contains("--autotest") {
            Task {
                await runAutotest()
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { tap.stop() }

    // MARK: - 界面

    private func buildControlWindow() {
        control = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 560, height: 460),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        control.title = "M0 技术验证"

        tapButton = ActionButton("开始采集系统声音") { [weak self] in self?.toggleTap() }
        let buttons: [NSView] = [
            ActionButton("切换 sharingType(none / readOnly)") { [weak self] in self?.toggleSharing() },
            ActionButton("切换鼠标穿透") { [weak self] in self?.overlay.toggleClickThrough() },
            ActionButton("截屏检测悬浮窗是否入画") { [weak self] in Task { await self?.runCaptureCheck() } },
            tapButton,
            levelLabel,
            ActionButton("导出会议软件窗口列表") { [weak self] in self?.dumpWindows() },
            ActionButton("打开输出目录") { NSWorkspace.shared.open(Log.dir) },
        ]

        let scroll = NSTextView.scrollableTextView()
        logView = scroll.documentView as? NSTextView
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let stack = NSStackView(views: buttons + [scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        control.contentView = stack
        control.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func appendLog(_ line: String) {
        logView.textStorage?.append(NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: - 操作

    private func toggleSharing() {
        overlay.setSharing(overlay.sharingType == .none ? .readOnly : .none)
        Log.write("sharingType 切换为 \(overlay.sharingName)")
    }

    private func toggleTap() {
        if tap.isRunning {
            logTapStats(tap.stop())
            tapButton.title = "开始采集系统声音"
        } else {
            let url = Log.dir.appendingPathComponent("tap-manual.wav")
            do {
                try tap.start(writingTo: url)
                tapButton.title = "停止采集"
                Log.write("开始采集系统声音，写入 \(url.lastPathComponent)。请播放任意声音。")
            } catch {
                Log.write("采集启动失败：\(error)")
            }
        }
    }

    private func logTapStats(_ stats: SystemAudioTap.Stats) {
        let verdict: String
        if stats.callbacks == 0 {
            verdict = "失败：没有收到任何音频回调"
        } else if stats.peakRMS < 0.0005 {
            verdict = "收到回调但全程静音：没有声音在播放，或未授予系统音频录制权限"
        } else {
            verdict = "成功：采集到了系统声音"
        }
        Log.write("采集结束。格式 \(stats.formatDescription)；回调 \(stats.callbacks) 次；"
                  + "共 \(stats.frames) 帧；峰值 RMS \(String(format: "%.4f", stats.peakRMS))")
        Log.write("系统声音采集结论 → \(verdict)")
    }

    private func dumpWindows() {
        if let result = WindowDump.run() {
            Log.write("已导出 \(result.count) 个会议软件窗口 → \(result.url.lastPathComponent)")
        } else {
            Log.write("读取窗口列表失败")
        }
    }

    // MARK: - 检测

    private func runCaptureCheck() async {
        if !CGPreflightScreenCaptureAccess() {
            Log.write("尚未授予屏幕录制权限，正在请求。授权后需要重启本应用再检测。")
            CGRequestScreenCaptureAccess()
            return
        }
        let original = overlay.sharingType
        var visibleWhenReadOnly: Bool?
        var visibleWhenNone: Bool?
        for type in [NSWindow.SharingType.readOnly, .none] {
            overlay.setSharing(type)
            try? await Task.sleep(nanoseconds: 800_000_000)
            do {
                let result = try await CaptureCheck.run(panel: overlay)
                Log.write("sharingType=\(type == .none ? "none" : "readOnly")："
                          + "标记\(result.markerVisible ? "可见" : "不可见")，"
                          + "像素=(\(result.pixel.r),\(result.pixel.g),\(result.pixel.b))，"
                          + "\(result.listedInShareableContent ? "出现在" : "不在")可共享窗口列表中")
                if type == .none { visibleWhenNone = result.markerVisible } else { visibleWhenReadOnly = result.markerVisible }
            } catch {
                Log.write("截屏失败：\(error)")
            }
        }
        overlay.setSharing(original)

        switch (visibleWhenReadOnly, visibleWhenNone) {
        case (true?, false?):
            Log.write("截屏检测结论 → sharingType=.none 有效：ScreenCaptureKit 截屏里看不到悬浮窗")
        case (true?, true?):
            Log.write("截屏检测结论 → sharingType=.none 无效：ScreenCaptureKit 截屏里仍能看到悬浮窗")
        case (false?, _):
            Log.write("截屏检测结论 → 检测本身无效：对照组也看不到标记(悬浮窗可能被遮挡或不在主屏幕)")
        default:
            Log.write("截屏检测结论 → 未完成")
        }
    }

    private func runAudioCheck(seconds: Double) async {
        let url = Log.dir.appendingPathComponent("tap-autotest.wav")
        do {
            try tap.start(writingTo: url)
        } catch {
            Log.write("采集启动失败：\(error)")
            return
        }
        // 用另一个进程播放系统提示音，验证能采到其他进程的声音
        for _ in 0..<2 {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try? player.run()
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1_000_000_000))
        }
        logTapStats(tap.stop())
    }

    private func runAutotest() async {
        Log.write("=== 自动检测开始 ===")
        await runCaptureCheck()
        await runAudioCheck(seconds: 4)
        Log.write("=== 自动检测结束 ===")
    }
}
