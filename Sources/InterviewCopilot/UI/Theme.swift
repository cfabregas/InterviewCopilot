import AppKit
import SwiftUI

/// 全应用的视觉语言：轻、亮、通透。系统字体，浅色的底，主要面板和按钮用系统的玻璃材质
/// (macOS 26 起是 Liquid Glass，更早的系统退回毛玻璃)。
/// 红色只用于"正在进行"，黄色只用于提示给我的答案。
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// 内容区的底色
    static let paper = dynamic(0xF5F6F8, 0x1B1C1F)
    /// 抬起一层的面：输入区、分组列表
    static let surface = dynamic(0xFFFFFF, 0x26282C)
    /// 正文
    static let ink = dynamic(0x1D1D1F, 0xF2F2F5)
    /// 次要文字
    static let muted = dynamic(0x6E6E76, 0x98989F)
    /// 分隔线
    static let line = dynamic(0xE4E5E9, 0x34363B)
    /// 可以点的东西
    static let accent = dynamic(0x3368D6, 0x7FA7F5)
    /// 实心按钮的底色：深色外观下也要压得住白字
    static let accentFill = dynamic(0x3368D6, 0x4A7BE0)
    /// 提示灯红：只表示"正在进行"
    static let live = dynamic(0xE0453A, 0xF0574C)
    /// 提词黄：给我看的答案和提示
    static let cue = dynamic(0xC98A12, 0xE9B44C)
    static let good = dynamic(0x2B8C5E, 0x4DB583)
    static let warn = dynamic(0xB86A12, 0xE39A3B)

    /// 标题
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    /// 大段的字幕、问题
    static func script(_ size: CGFloat) -> Font { .system(size: size, weight: .regular) }
}

/// 内容区背后很淡的两团光，让上面的玻璃面板有东西可以折射
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.paper
            GeometryReader { proxy in
                let w = proxy.size.width
                Circle().fill(Theme.accent.opacity(0.16)).frame(width: w * 0.6).blur(radius: 120)
                    .position(x: w * 0.22, y: 40)
                Circle().fill(Theme.cue.opacity(0.10)).frame(width: w * 0.45).blur(radius: 120)
                    .position(x: w * 0.85, y: 120)
            }
        }
        .ignoresSafeArea()
    }
}

/// 主要动作：胶囊形的实心按钮(macOS 26 起是带颜色的玻璃)。live 为 true 时变成红色(结束正在进行的事)。
struct PrimaryButtonStyle: ButtonStyle {
    var live = false
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let color = live ? Theme.live : Theme.accentFill
        let label = configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 9 : 5)
        return Group {
            if #available(macOS 26, *) {
                label.glassEffect(.regular.tint(color).interactive(), in: Capsule())
            } else {
                label.background(Capsule().fill(color))
            }
        }
        .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// 次要动作：胶囊形的玻璃按钮。large 和 PrimaryButtonStyle 的 large 一样大，两个并排时用
struct QuietButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: large ? 14 : 13, weight: large ? .semibold : .regular))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, large ? 22 : 13)
            .padding(.vertical, large ? 9 : 5)
        return Group {
            if #available(macOS 26, *) {
                label.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label.background(Capsule().fill(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1)))
                    .overlay(Capsule().strokeBorder(Theme.line))
            }
        }
        .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

/// 文字链接式的动作
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).foregroundStyle(Theme.accent).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 提示灯：进行中是红色并缓慢呼吸，待机是暗的
struct TallyLamp: View {
    let on: Bool
    var size: CGFloat = 10
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(on ? Theme.live : Theme.muted.opacity(0.35))
            .frame(width: size, height: size)
            .shadow(color: on ? Theme.live.opacity(0.8) : .clear, radius: on ? 5 : 0)
            .opacity(on && dim ? 0.45 : 1)
            .onAppear { animate() }
            .onChange(of: on) { animate() }
    }

    private func animate() {
        dim = false
        guard on, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// 键帽：显示一个快捷键
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
    }
}

/// 页面顶部：标题、一句说明、右侧放这一页的主要动作
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(Theme.display(26)).foregroundStyle(Theme.ink).fixedSize()
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 小节标题
struct SectionRule: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.8))
    }
}

/// 分组列表里的一行：上面一条缩进的分隔线。放进 groupedRows() 的容器后，第一行的分隔线会被裁掉
struct GroupedRow<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14)
            content.padding(.horizontal, 14).padding(.vertical, 9)
        }
    }
}

extension View {
    /// 抬起一层的面：白底，圆角，没有描边
    func surface(radius: CGFloat = 12, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surface))
    }

    /// 分组列表的容器：像系统设置里的一组选项，里面放 GroupedRow
    func groupedRows() -> some View {
        self.padding(.top, -1)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 胶囊形的玻璃底：给菜单这类不能套按钮样式的控件用
    @ViewBuilder
    func capsuleGlass() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(Capsule().fill(Theme.surface)).overlay(Capsule().strokeBorder(Theme.line))
        }
    }

    /// 玻璃面板：放这一页最要紧的东西
    @ViewBuilder
    func stage(padding: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26, *) {
            self.padding(padding).glassEffect(.regular, in: shape)
        } else {
            self.padding(padding)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.4)))
                .shadow(color: .black.opacity(0.06), radius: 18, y: 6)
        }
    }
}

/// 日历那种分段滑块：白色玻璃胶囊底，选中的一段是浅灰色圆块。
/// 可以点击，也可以按住拖动：拖动时圆块变成跟着手指走的玻璃透镜，松手吸附到最近的一段。
struct SlidingPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @State private var frames: [Int: CGRect] = [:]
    @State private var dragX: CGFloat?
    @Environment(\.isEnabled) private var enabled

    private var selectedIndex: Int { options.firstIndex { $0.value == selection } ?? 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            thumb
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Text(option.title)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .frame(minWidth: 64)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: SegmentFrames.self, value: [index: proxy.frame(in: .named("sliding"))])
                        })
                        .contentShape(Rectangle())
                        .accessibilityElement()
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(index == selectedIndex ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { choose(index) }
                }
            }
        }
        .coordinateSpace(name: "sliding")
        .onPreferenceChange(SegmentFrames.self) { value in
            MainActor.assumeIsolated { frames = value }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sliding"))
            .onChanged { drag in
                guard enabled else { return }
                // 按下后稍微挪动才算拖动，原地松开当作点击
                if dragX != nil || abs(drag.translation.width) > 3 { dragX = drag.location.x }
            }
            .onEnded { drag in
                guard enabled else { return }
                let index = nearest(drag.location.x)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    dragX = nil
                    if options.indices.contains(index) { selection = options[index].value }
                }
            })
        .padding(4)
        .background(track)
        .opacity(enabled ? 1 : 0.45)
    }

    /// 选中块：平时是浅灰圆块，拖动时变成玻璃透镜
    @ViewBuilder
    private var thumb: some View {
        let index = dragX.map(nearest) ?? selectedIndex
        if let frame = frames[index] {
            let width = frame.width
            let total = frames.values.map(\.maxX).max() ?? width
            let x = dragX.map { min(max($0 - width / 2, 0), total - width) } ?? frame.minX
            Group {
                if dragX != nil, #available(macOS 26, *) {
                    Capsule().fill(Color.white.opacity(0.15))
                        .glassEffect(.clear.interactive(), in: Capsule())
                        .scaleEffect(1.12)
                } else {
                    Capsule().fill(Theme.ink.opacity(dragX == nil ? 0.08 : 0.12))
                }
            }
            .frame(width: width, height: frame.height)
            .offset(x: x, y: frame.minY)
        }
    }

    @ViewBuilder
    private var track: some View {
        if #available(macOS 26, *) {
            Capsule().fill(Theme.surface.opacity(0.5)).glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(Theme.surface)
                .overlay(Capsule().strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    private func nearest(_ x: CGFloat) -> Int {
        frames.min { abs($0.value.midX - x) < abs($1.value.midX - x) }?.key ?? selectedIndex
    }

    private func choose(_ index: Int) {
        guard enabled, options.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { selection = options[index].value }
    }
}

private struct SegmentFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
