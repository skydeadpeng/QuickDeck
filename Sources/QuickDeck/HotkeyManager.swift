import AppKit
import Carbon.HIToolbox
import Combine

// MARK: - 可绑定的动作

enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case togglePanel
    case focusSearch
    case screenshot
    case lock
    case clipboardHistory
    case clearClipboard
    case darkMode
    case mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePanel: return "显示 / 隐藏面板"
        case .focusSearch: return "呼出面板并搜索"
        case .screenshot: return "截图"
        case .lock: return "锁屏"
        case .clipboardHistory: return "打开剪贴板历史"
        case .clearClipboard: return "清空剪贴板"
        case .darkMode: return "深色 / 浅色切换"
        case .mute: return "静音切换"
        }
    }
}

struct HotkeyBinding: Codable, Equatable {
    var action: HotkeyAction
    /// 键码；-1 表示尚未设置组合（不注册）
    var keyCode: Int
    /// Carbon 修饰键位（cmdKey/optionKey/shiftKey/controlKey 组合）
    var modifiers: Int

    var isAssigned: Bool { keyCode >= 0 }
}

// MARK: - 全局热键管理（Carbon RegisterEventHotKey，支持多组绑定）

final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    static let storageKey = "deck.hotkeys"
    static let legacyIndexKey = "deck.hotkey.index"
    static let maxSlots = 3
    /// 四字符码 'QDKD'，用于识别自己的热键回调
    private static let signature: OSType = 0x51444B44

    @Published private(set) var bindings: [HotkeyBinding] = []
    @Published private(set) var lastError: String?

    /// 动作执行器，由 PanelController 注入
    var performAction: ((HotkeyAction) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init() {
        load()
        installHandler()
        registerAll()
    }

    // MARK: - 存储与迁移

    /// v1.6 及以前的单一预设，按原顺序迁移到「显示/隐藏面板」绑定
    private static let legacyPresets: [(keyCode: Int, modifiers: Int)] = [
        (kVK_Space, optionKey),
        (kVK_Space, optionKey | controlKey),
        (kVK_ANSI_D, optionKey),
        (kVK_ANSI_Slash, optionKey),
        (kVK_F6, 0),
    ]

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([HotkeyBinding].self, from: data),
           !saved.isEmpty {
            bindings = saved
        } else if defaults.object(forKey: Self.legacyIndexKey) != nil {
            let index = min(max(defaults.integer(forKey: Self.legacyIndexKey), 0), Self.legacyPresets.count - 1)
            let preset = Self.legacyPresets[index]
            bindings = [HotkeyBinding(action: .togglePanel, keyCode: preset.keyCode, modifiers: preset.modifiers)]
        } else {
            bindings = [HotkeyBinding(action: .togglePanel, keyCode: kVK_Space, modifiers: optionKey)]
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - 注册

    func registerAll() {
        unregisterAll()
        for (index, binding) in bindings.enumerated() where binding.isAssigned {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                UInt32(binding.modifiers),
                id,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                lastError = "「\(binding.action.title)」的 \(Self.comboText(binding)) 注册失败，可能与其他软件冲突"
            }
        }
    }

    func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        lastError = nil
    }

    // MARK: - 编辑接口

    func setBinding(_ index: Int, _ binding: HotkeyBinding) {
        guard bindings.indices.contains(index) else { return }
        if isDuplicate(binding, ignoring: index) {
            lastError = "组合 \(Self.comboText(binding)) 与其他快捷键重复"
            return
        }
        bindings[index] = binding
        persist()
        registerAll()
    }

    func appendBinding(action: HotkeyAction) {
        guard bindings.count < Self.maxSlots else { return }
        bindings.append(HotkeyBinding(action: action, keyCode: -1, modifiers: 0))
        persist()
    }

    func removeBinding(at index: Int) {
        guard bindings.indices.contains(index) else { return }
        bindings.remove(at: index)
        persist()
        registerAll()
    }

    private func isDuplicate(_ binding: HotkeyBinding, ignoring index: Int) -> Bool {
        bindings.enumerated().contains { offset, existing in
            offset != index && existing.isAssigned && binding.isAssigned
                && existing.keyCode == binding.keyCode && existing.modifiers == binding.modifiers
        }
    }

    /// 面板显隐热键的显示文本（菜单和按钮提示用）
    var togglePanelComboText: String {
        if let binding = bindings.first(where: { $0.action == .togglePanel && $0.isAssigned }) {
            return Self.comboText(binding)
        }
        return "未设置"
    }

    // MARK: - Carbon 事件处理

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C 函数指针回调，不能捕获上下文 → 通过 userData 传回 self
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr, hotKeyID.signature == HotkeyManager.signature {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
                let index = Int(hotKeyID.id) - 1
                DispatchQueue.main.async {
                    guard manager.bindings.indices.contains(index) else { return }
                    manager.performAction?(manager.bindings[index].action)
                }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    // MARK: - 显示名

    static func comboText(_ binding: HotkeyBinding) -> String {
        guard binding.isAssigned else { return "未设置" }
        var text = ""
        if binding.modifiers & cmdKey != 0 { text += "⌘" }
        if binding.modifiers & optionKey != 0 { text += "⌥" }
        if binding.modifiers & controlKey != 0 { text += "⌃" }
        if binding.modifiers & shiftKey != 0 { text += "⇧" }
        return text + keyName(binding.keyCode)
    }

    static func keyName(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "空格"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "键#\(keyCode)"
        }
    }

    /// NSEvent 修饰键 → Carbon 位标记
    static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> Int {
        var value = 0
        if flags.contains(.command) { value |= cmdKey }
        if flags.contains(.option) { value |= optionKey }
        if flags.contains(.shift) { value |= shiftKey }
        if flags.contains(.control) { value |= controlKey }
        return value
    }
}
