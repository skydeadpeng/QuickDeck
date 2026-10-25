import AppKit

// 附件型应用：无 Dock 图标、不参与 Cmd+Tab 切换
NSApplication.shared.setActivationPolicy(.accessory)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
