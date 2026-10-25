import AppKit
import Carbon.HIToolbox

/// 全局快捷键：Carbon RegisterEventHotKey 是 macOS 上唯一无需辅助功能权限的注册方式
final class HotkeyManager {
    static let shared = HotkeyManager()
    static let presetKey = "deck.hotkey.index"
    /// 四字符码 'QDKD'，用于识别自己的热键回调
    private static let signature: OSType = 0x51444B44

    static let presets: [(title: String, keyCode: Int, modifiers: Int)] = [
        ("⌥ + 空格", kVK_Space, optionKey),
        ("⌃⌥ + 空格", kVK_Space, optionKey | controlKey),
        ("⌥ + D", kVK_ANSI_D, optionKey),
        ("⌥ + /", kVK_ANSI_Slash, optionKey),
        ("F6", kVK_F6, 0),
    ]

    var onTrigger: (() -> Void)?
    private(set) var lastStatus: OSStatus = noErr
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var currentIndex: Int {
        get { UserDefaults.standard.integer(forKey: Self.presetKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.presetKey)
            applyPreset(newValue)
        }
    }

    var currentTitle: String {
        let clamped = min(max(currentIndex, 0), Self.presets.count - 1)
        return Self.presets[clamped].title
    }

    init() {
        installHandler()
        applyPreset(min(max(currentIndex, 0), Self.presets.count - 1))
    }

    func applyPreset(_ index: Int) {
        guard Self.presets.indices.contains(index) else { return }
        unregister()
        let preset = Self.presets[index]
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        lastStatus = RegisterEventHotKey(
            UInt32(preset.keyCode),
            UInt32(preset.modifiers),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if lastStatus == noErr { hotKeyRef = ref }
    }

    private func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
    }

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
                DispatchQueue.main.async { manager.onTrigger?() }
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
}
