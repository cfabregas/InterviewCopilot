import AppKit
import SwiftUI

/// 悬浮窗的外观和行为设置
@MainActor
final class OverlaySettings: ObservableObject {
    weak var panel: NSPanel?

    // 外观和行为都记在偏好设置里，下次启动沿用
    private static let defaults = UserDefaults.standard
    private static func saved<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "overlay.\(key)") as? T ?? fallback }
    private func save(_ key: String, _ value: Any) { Self.defaults.set(value, forKey: "overlay.\(key)") }

    @Published var showSource: Bool = saved("showSource", true) { didSet { save("showSource", showSource) } }
    @Published var fontSize: Double = saved("fontSize", 20.0) { didSet { save("fontSize", fontSize) } }
    @Published var opacity: Double = saved("opacity", 0.25) { didSet { save("opacity", opacity) } }
    @Published var maxLines: Int = saved("maxLines", 4) { didSet { save("maxLines", maxLines) } }

    @Published var clickThrough: Bool = saved("clickThrough", true) {
        didSet {
            panel?.ignoresMouseEvents = clickThrough
            save("clickThrough", clickThrough)
        }
    }
    @Published var hideFromSharing: Bool = saved("hideFromSharing", true) {
        didSet {
            panel?.sharingType = hideFromSharing ? .none : .readOnly
            save("hideFromSharing", hideFromSharing)
        }
    }
    @Published var visible = true {
        didSet { refresh() }
    }
    /// 只有面试进行中才显示悬浮窗；⌃⌥H 可以在进行中临时隐藏
    var sessionActive = false {
        didSet { refresh() }
    }

    private func refresh() {
        if visible && sessionActive { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
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
        sharingType = .none   // 启动后由 AppDelegate 按保存的设置再设一次
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

/// 答案卡：像一张提词卡。左边一条提词黄的竖线，先是问题，再是中文要点，最后是可以照着说的回答
struct AnswerCardView: View {
    let card: AnswerCard
    let fontSize: Double

    private let cue = Color(red: 0.95, green: 0.74, blue: 0.33)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5).fill(cue).frame(width: 3)
            VStack(alignment: .leading, spacing: 7) {
                Text(card.question)
                    .font(.system(size: fontSize * 0.6))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                if card.text.isEmpty, card.error == nil {
                    Text(L("正在准备回答…"))
                        .font(.system(size: fontSize * 0.75))
                        .foregroundStyle(.white.opacity(0.6))
                }
                if !card.points.isEmpty {
                    Text(card.points)
                        .font(.system(size: fontSize * 0.85, weight: .semibold))
                        .foregroundStyle(cue)
                        .lineSpacing(3)
                }
                if !card.script.isEmpty {
                    Text(card.script)
                        .font(.system(size: fontSize * 0.75))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineSpacing(3)
                }
                if let error = card.error {
                    Text(L("答案生成失败：") + error)
                        .font(.system(size: fontSize * 0.6))
                        .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.45))
                        .lineLimit(3)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
    }
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
    @ObservedObject var answers: AnswerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.lines.isEmpty {
                HStack(spacing: 8) {
                    TallyLamp(on: controller.isRunning, size: 8)
                    Text(controller.isRunning ? L("正在听…") : L("未开始"))
                        .font(.system(size: settings.fontSize * 0.75))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            let visible = Array(controller.lines.suffix(settings.maxLines))
            ForEach(visible) { line in
                // 越早的句子越淡，眼睛自然落在最新一句上
                let latest = line.id == visible.last?.id
                VStack(alignment: .leading, spacing: 3) {
                    if settings.showSource {
                        Text(line.source)
                            .font(.system(size: settings.fontSize * 0.66))
                            .foregroundStyle(.white.opacity(line.isFinal ? 0.62 : 0.45))
                    }
                    if !line.translation.isEmpty {
                        Text(line.translation)
                            .font(.system(size: settings.fontSize, weight: latest ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(line.translationIsProvisional ? 0.6 : (latest ? 1 : 0.8)))
                            .lineSpacing(2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let card = answers.card {
                AnswerCardView(card: card, fontSize: settings.fontSize)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .modifier(OverlayBackground(opacity: settings.opacity))
    }
}

/// 悬浮窗的底：深色半透明。不加玻璃，玻璃会把后面的会议画面糊掉
private struct OverlayBackground: ViewModifier {
    let opacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content
            .background(shape.fill(Color(red: 0.06, green: 0.08, blue: 0.11).opacity(opacity)))
            .overlay(shape.strokeBorder(.white.opacity(opacity > 0.05 ? 0.1 : 0)))
            .clipShape(shape)
    }
}

