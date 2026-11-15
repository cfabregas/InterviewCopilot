import AppKit
import SwiftUI

/// 悬浮窗的外观和行为设置
@MainActor
final class OverlaySettings: ObservableObject {
    weak var panel: NSPanel?

    @Published var showSource = true
    @Published var fontSize: Double = 20
    @Published var opacity: Double = 0.6
    @Published var maxLines = 4

    @Published var clickThrough = true {
        didSet { panel?.ignoresMouseEvents = clickThrough }
    }
    @Published var hideFromSharing = true {
        didSet { panel?.sharingType = hideFromSharing ? .none : .readOnly }
    }
    @Published var visible = true {
        didSet {
            if visible { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
        }
    }
}

/// 字幕悬浮窗：不抢焦点，浮在所有窗口和全屏应用之上，默认不出现在截屏和屏幕共享里。
final class OverlayPanel: NSPanel {
    init(content: some View) {
        let screen = NSScreen.screens[0].visibleFrame
        let size = NSSize(width: 760, height: 230)
        let rect = NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12,
                          width: size.width, height: size.height)
        super.init(contentRect: rect,
                   styleMask: [.nonactivatingPanel, .borderless, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        sharingType = .none
        minSize = NSSize(width: 360, height: 90)
        maxSize = NSSize(width: 1600, height: 600)
        let hosting = DraggableHostingView(rootView: content)
        // 不让字幕内容反过来撑大窗口：否则字幕一多窗口会被撑到几千点高，文字跑到屏幕外
        hosting.sizingOptions = []
        contentView = hosting
        setFrameAutosaveName("SubtitleOverlay")
        // 上次保存的位置如果异常(过大或不在屏幕内)，回到默认位置
        if frame.height > maxSize.height || frame.width > maxSize.width || !screen.contains(frame) {
            setFrame(rect, display: false)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI 内容会吃掉鼠标事件，导致无边框窗口拖不动。这里直接把按下鼠标变成拖动窗口。
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct SubtitleOverlayView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var settings: OverlaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.lines.isEmpty {
                Text(controller.isRunning ? "正在听…" : "未开始")
                    .font(.system(size: settings.fontSize * 0.8))
                    .foregroundStyle(.white.opacity(0.55))
            }
            ForEach(controller.lines.suffix(settings.maxLines)) { line in
                VStack(alignment: .leading, spacing: 2) {
                    if settings.showSource {
                        Text(line.source)
                            .font(.system(size: settings.fontSize * 0.7))
                            .foregroundStyle(.white.opacity(line.isFinal ? 0.75 : 0.5))
                    }
                    if !line.translation.isEmpty {
                        Text(line.translation)
                            .font(.system(size: settings.fontSize, weight: .medium))
                            .foregroundStyle(.white.opacity(line.translationIsProvisional ? 0.6 : 1))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(settings.opacity)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
