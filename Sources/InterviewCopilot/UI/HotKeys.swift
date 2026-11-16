import AppKit
import Carbon.HIToolbox

/// 可以绑定全局快捷键的动作
enum HotKeyAction: String, CaseIterable, Identifiable {
    case end, toggleOverlay, clickThrough, answer, dismiss

    var id: String { rawValue }

    var title: String {
        switch self {
        case .end: return L("结束面试")
        case .toggleOverlay: return L("显示或隐藏悬浮窗")
        case .clickThrough: return L("切换鼠标穿透")
        case .answer: return L("回答上一句")
        case .dismiss: return L("关闭答案卡")
        }
    }

    var defaultCombo: KeyCombo {
        let modifiers = controlKey | optionKey
        switch self {
        case .end: return KeyCombo(keyCode: kVK_ANSI_E, modifiers: modifiers, label: "E")
        case .toggleOverlay: return KeyCombo(keyCode: kVK_ANSI_H, modifiers: modifiers, label: "H")
        case .clickThrough: return KeyCombo(keyCode: kVK_ANSI_T, modifiers: modifiers, label: "T")
        case .answer: return KeyCombo(keyCode: kVK_ANSI_A, modifiers: modifiers, label: "A")
        case .dismiss: return KeyCombo(keyCode: kVK_ANSI_X, modifiers: modifiers, label: "X")
        }
    }
}

/// 一个组合键。modifiers 用 Carbon 的修饰键位。
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var label: String

    var display: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + label
    }

    /// 从一次按键事件得到组合键；没有带 ⌃、⌥ 或 ⌘ 的不能当全局快捷键
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        guard modifiers & (controlKey | optionKey | cmdKey) != 0 else { return nil }
        let names: [Int: String] = [kVK_Space: L("空格"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let code = Int(event.keyCode)
        let label = names[code] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !label.isEmpty else { return nil }
        self.init(keyCode: code, modifiers: modifiers, label: label)
    }

    init(keyCode: Int, modifiers: Int, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

/// 全局快捷键(Carbon 热键，不需要辅助功能权限)。组合键可以在设置里改，存在偏好设置里。
final class HotKeys: ObservableObject {
    static let shared = HotKeys()

    @Published private(set) var combos: [HotKeyAction: KeyCombo] = [:]
    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var installed = false

    private init() {
        for action in HotKeyAction.allCases {
            if let data = UserDefaults.standard.data(forKey: "hotkey.\(action.rawValue)"),
               let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                combos[action] = combo
            } else {
                combos[action] = action.defaultCombo
            }
        }
    }

    func display(_ action: HotKeyAction) -> String { combos[action]?.display ?? "" }

    /// 绑定动作要做的事，并注册它当前的组合键
    func bind(_ action: HotKeyAction, handler: @escaping () -> Void) {
        handlers[action] = handler
        register(action)
    }

    /// 改组合键。和别的动作撞了就不改，返回撞上的那个动作。
    @discardableResult
    func set(_ combo: KeyCombo, for action: HotKeyAction) -> HotKeyAction? {
        if let clash = combos.first(where: { $0.key != action && $0.value.keyCode == combo.keyCode && $0.value.modifiers == combo.modifiers }) {
            return clash.key
        }
        combos[action] = combo
        if combo == action.defaultCombo {
            UserDefaults.standard.removeObject(forKey: "hotkey.\(action.rawValue)")
        } else if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: "hotkey.\(action.rawValue)")
        }
        register(action)
        return nil
    }

    private func register(_ action: HotKeyAction) {
        installIfNeeded()
        if let old = refs[action] {
            UnregisterEventHotKey(old)
            refs[action] = nil
        }
        guard handlers[action] != nil, let combo = combos[action],
              let index = HotKeyAction.allCases.firstIndex(of: action) else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4943_4F50), id: UInt32(index + 1))   // 'ICOP'
        let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[action] = ref } else {
            Log.write("快捷键 \(combo.display)(\(action.title))注册失败：\(status)，可能被别的应用占用")
        }
    }

    fileprivate func fire(_ id: UInt32) {
        let actions = HotKeyAction.allCases
        guard id >= 1, Int(id) <= actions.count else { return }
        handlers[actions[Int(id) - 1]]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKeys.shared.fire(hotKeyID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}
