import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// 编辑模式切换等导致面板高度变化时发出，让窗口重新贴齐内容
    static let deckContentChanged = Notification.Name("deck.contentChanged")
    /// 界面请求隐藏面板（快捷键呼回）
    static let deckHidePanel = Notification.Name("deck.hidePanel")
    /// 面板显示 / 隐藏变化，object 携带 Bool；隐藏时各监控暂停轮询省电
    static let deckPanelVisibilityChanged = Notification.Name("deck.panelVisibilityChanged")
}

/// 常驻桌面的悬浮面板：无边框半透明、不抢焦点、所有空间和全屏下可见
final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 308, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    let panel = DeckPanel()
    let store = ShortcutStore()
    let weather = WeatherModel()
    let battery = BatteryMonitor()
    let clipboard = ClipboardMonitor()
    let volume = VolumeControl()
    let monitor = SystemMonitor()
    let wifi = WiFiControl()
    let bluetooth = BluetoothControl()

    private static let positionKey = "deck.panel.origin"

    override init() {
        Self.migratePanelWidth()
        super.init()

        let content = DeckView(
            store: store,
            weather: weather,
            battery: battery,
            clipboard: clipboard,
            volume: volume,
            monitor: monitor,
            wifi: wifi,
            bluetooth: bluetooth
        )
        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting
        panel.delegate = self

        restorePosition()
        panel.orderFrontRegardless()
        fitToContent()

        // 快捷方式增删 → 高度变化 → 重新计算窗口尺寸
        store.objectWillChange
            .dropFirst()
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.fitToContent() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .deckContentChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.fitToContent() }

        NotificationCenter.default.addObserver(
            forName: .deckHidePanel, object: nil, queue: .main
        ) { [weak self] _ in self?.hidePanel() }

        // 全局快捷键：显示 / 隐藏面板
        HotkeyManager.shared.onTrigger = { [weak self] in
            self?.togglePanel()
        }
    }

    func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            NotificationCenter.default.post(name: .deckPanelVisibilityChanged, object: false)
        } else {
            panel.orderFrontRegardless()
            NotificationCenter.default.post(name: .deckPanelVisibilityChanged, object: true)
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        NotificationCenter.default.post(name: .deckPanelVisibilityChanged, object: false)
    }

    /// v1.4 宽度档位升级：300/340/380 → 320/380/440，老用户一次性迁移
    private static func migratePanelWidth() {
        let flag = "deck.panel.width.migrated.v4"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let key = "deck.panel.width"
        guard UserDefaults.standard.object(forKey: key) != nil else { return }
        let old = UserDefaults.standard.integer(forKey: key)
        let mapped = old <= 300 ? 320 : (old <= 340 ? 380 : 440)
        UserDefaults.standard.set(mapped, forKey: key)
    }

    private var cancellables = Set<AnyCancellable>()

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            let origin = NSPointFromString(saved)
            let onScreen = NSScreen.screens.contains {
                $0.visibleFrame.intersects(NSRect(origin: origin, size: NSSize(width: 120, height: 120)))
            }
            if onScreen && origin != .zero {
                panel.setFrameOrigin(origin)
                return
            }
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - 220))
        }
    }

    private func fitToContent() {
        DispatchQueue.main.async { [panel] in
            guard let hosting = panel.contentView else { return }
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            guard size.width > 10, size.height > 10 else { return }
            panel.setContentSize(size)
        }
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.positionKey)
    }
}

/// 面板隐藏时自动暂停、显示时恢复并先跑一次的定时器（省电）
final class VisibilityAwareTimer {
    private var timer: Timer?
    private let interval: TimeInterval
    private let onFire: () -> Void
    private let onResume: (() -> Void)?
    private var startedOnce = false

    init(interval: TimeInterval,
         onFire: @escaping () -> Void,
         onResume: (() -> Void)? = nil) {
        self.interval = interval
        self.onFire = onFire
        self.onResume = onResume
        start()
        NotificationCenter.default.addObserver(
            forName: .deckPanelVisibilityChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let visible = note.object as? Bool else { return }
            if visible { self?.start() } else { self?.stop() }
        }
    }

    private func start() {
        if startedOnce { onResume?() } else { startedOnce = true }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.onFire()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
