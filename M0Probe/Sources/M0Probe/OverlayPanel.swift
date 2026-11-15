import AppKit

/// 验证用悬浮窗：不抢焦点、浮在所有窗口和全屏应用之上。
/// 左侧的品红色块是截屏检测用的标记。
final class OverlayPanel: NSPanel {
    let marker = NSView(frame: NSRect(x: 16, y: 40, width: 120, height: 100))
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    init() {
        let screen = NSScreen.screens[0].visibleFrame
        let rect = NSRect(x: screen.midX - 320, y: screen.maxY - 220, width: 640, height: 180)
        super.init(contentRect: rect,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        sharingType = .none

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        content.layer?.cornerRadius = 12

        marker.wantsLayer = true
        marker.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        content.addSubview(marker)

        label.frame = NSRect(x: 152, y: 20, width: 470, height: 140)
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        label.maximumNumberOfLines = 0
        content.addSubview(label)

        contentView = content
        refreshLabel()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshLabel()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var sharingName: String { sharingType == .none ? "none(应当不可见)" : "readOnly(对照组，可见)" }

    func setSharing(_ type: NSWindow.SharingType) {
        sharingType = type
        refreshLabel()
    }

    /// 标记色块中心点的屏幕坐标(左下角为原点)
    var markerCenterOnScreen: CGPoint {
        let inWindow = marker.convert(marker.bounds, to: nil)
        let onScreen = convertToScreen(inWindow)
        return CGPoint(x: onScreen.midX, y: onScreen.midY)
    }

    private func refreshLabel() {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        label.stringValue = """
        M0 悬浮窗验证
        sharingType = \(sharingName)
        鼠标穿透 = \(ignoresMouseEvents ? "开" : "关")
        \(time)
        """
    }

    func toggleClickThrough() {
        ignoresMouseEvents.toggle()
        refreshLabel()
    }
}
