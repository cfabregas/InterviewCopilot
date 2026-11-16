import AppKit
import SwiftUI

/// 全应用的视觉语言。取自同传间和提词器：深色的"幕布"侧栏，冷调的纸面，
/// 红色只用于"正在进行"，黄色只用于提示给我的答案。
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// 纸面：内容区的底色
    static let paper = dynamic(0xF3F4F7, 0x12161D)
    /// 纸面上抬起一层的面：输入区、列表
    static let surface = dynamic(0xFFFFFF, 0x1A2029)
    /// 墨色：正文
    static let ink = dynamic(0x17202C, 0xE6EAF0)
    /// 次要文字
    static let muted = dynamic(0x667185, 0x8D97A8)
    /// 分隔线
    static let line = dynamic(0xDCE0E7, 0x2A323E)
    /// 幕布：侧栏和"台口"面板，两种外观下都是深色
    static let curtain = dynamic(0x1A2432, 0x0B0F15)
    static let curtainRaised = dynamic(0x263345, 0x171E28)
    static let onCurtain = Color.white.opacity(0.9)
    static let onCurtainMuted = Color.white.opacity(0.5)
    /// 靛青：可以点的东西
    static let accent = dynamic(0x2C4F86, 0x86ABE6)
    /// 实心按钮的底色：深色外观下也要压得住白字
    static let accentFill = dynamic(0x2C4F86, 0x3D6DBE)
    /// 提示灯红：只表示"正在进行"
    static let live = dynamic(0xE0453A, 0xF0574C)
    /// 提词黄：给我看的答案和提示
    static let cue = dynamic(0xC98A12, 0xE9B44C)
    static let good = dynamic(0x2B8C5E, 0x4DB583)
    static let warn = dynamic(0xB86A12, 0xE39A3B)

    /// 标题用宋体：像一页台本
    static func display(_ size: CGFloat) -> Font { .custom("STSongti-SC-Bold", size: size) }
    static func script(_ size: CGFloat) -> Font { .custom("STSongti-SC-Regular", size: size) }
}

/// 主要动作：实心按钮。live 为 true 时变成红色(结束正在进行的事)。
struct PrimaryButtonStyle: ButtonStyle {
    var live = false
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 10 : 6)
            .background(RoundedRectangle(cornerRadius: large ? 9 : 7).fill(live ? Theme.live : Theme.accentFill))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// 次要动作：描边按钮
struct QuietButtonStyle: ButtonStyle {
    var onCurtain = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(onCurtain ? Theme.onCurtain : Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(onCurtain ? Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)
                                                                            : Theme.surface.opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(onCurtain ? Color.white.opacity(0.14) : Theme.line))
            .opacity(enabled ? 1 : 0.45)
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
            .fill(on ? Theme.live : Color.white.opacity(0.22))
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

/// 页面顶部：宋体标题、一句说明、右侧放这一页的主要动作
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(Theme.display(26)).foregroundStyle(Theme.ink)
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

/// 小节标题：一行字加一条贯通的细线
struct SectionRule: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

extension View {
    /// 抬起一层的面：白底加细边
    func surface(radius: CGFloat = 10, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line))
    }

    /// 台口：深色面板，放这一页最要紧的东西
    func stage(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.curtain))
    }
}
