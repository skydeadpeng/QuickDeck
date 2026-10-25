import AppKit

struct SystemAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let detail: String
    let run: () -> Void
}

@discardableResult
func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func takeScreenshot() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/截图 \(formatter.string(from: Date())).png")
    runCommand("/usr/sbin/screencapture", ["-i", file.path])
}

private func toggleMute() {
    let muted = runCommand("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"]) == "true"
    runCommand("/usr/bin/osascript", ["-e", muted ? "set volume without output muted" : "set volume with output muted"])
}

private func openSystemApp(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

private func defaultsReadBool(_ domain: String, _ key: String) -> Bool {
    let out = runCommand("/usr/bin/defaults", ["read", domain, key])
    guard let out else { return true }
    return out == "1" || out == "true"
}

private func toggleFinderDefault(key: String) {
    let next = defaultsReadBool("com.apple.finder", key) ? "false" : "true"
    runCommand("/usr/bin/defaults", ["write", "com.apple.finder", key, "-bool", next])
    runCommand("/usr/bin/killall", ["Finder"])
}

enum SystemActions {
    static let all: [SystemAction] = [
        SystemAction(id: "screenshot", title: "截图", symbol: "camera.viewfinder",
                     detail: "框选屏幕区域，图片自动保存到桌面") {
            takeScreenshot()
        },
        SystemAction(id: "lock", title: "锁屏", symbol: "lock.fill",
                     detail: "立即熄灭屏幕（等同于锁定）") {
            runCommand("/usr/bin/pmset", ["displaysleepnow"])
        },
        SystemAction(id: "trash", title: "清空废纸篓", symbol: "trash",
                     detail: "永久删除废纸篓里的全部文件，不可恢复") {
            runCommand("/bin/zsh", ["-c", "rm -rf ~/.Trash/*"])
        },
        SystemAction(id: "darkmode", title: "深浅切换", symbol: "circle.lefthalf.filled",
                     detail: "切换系统的深色 / 浅色外观（首次需授权）") {
            runCommand("/usr/bin/osascript", [
                "-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode",
            ])
        },
        SystemAction(id: "mute", title: "静音", symbol: "speaker.slash.fill",
                     detail: "打开 / 关闭系统静音") {
            toggleMute()
        },
        SystemAction(id: "terminal", title: "终端", symbol: "terminal.fill",
                     detail: "打开终端 App") {
            openSystemApp("/System/Applications/Utilities/Terminal.app")
        },
        SystemAction(id: "monitor", title: "活动监视器", symbol: "gauge",
                     detail: "查看 CPU、内存等占用情况") {
            openSystemApp("/System/Applications/Utilities/Activity Monitor.app")
        },
        SystemAction(id: "sleep", title: "睡眠", symbol: "moon.zzz.fill",
                     detail: "让 Mac 立即进入睡眠") {
            runCommand("/usr/bin/pmset", ["sleepnow"])
        },
        SystemAction(id: "restartdock", title: "重启 Dock", symbol: "dock.rectangle",
                     detail: "Dock 卡住时重启它") {
            runCommand("/usr/bin/killall", ["Dock"])
        },
        SystemAction(id: "desktopicons", title: "桌面图标", symbol: "menubar.rectangle",
                     detail: "显示 / 隐藏桌面上的所有图标") {
            toggleFinderDefault(key: "CreateDesktop")
        },
        SystemAction(id: "hiddenfiles", title: "隐藏文件", symbol: "eye.trianglebadge.exclamationmark",
                     detail: "访达中显示 / 隐藏以 . 开头的隐藏文件") {
            toggleFinderDefault(key: "AppleShowAllFiles")
        },
        SystemAction(id: "syssettings", title: "系统设置", symbol: "gearshape",
                     detail: "打开系统设置 App") {
            openSystemApp("/System/Applications/System Settings.app")
        },
        SystemAction(id: "clearclip", title: "清空剪贴板", symbol: "clipboard",
                     detail: "一键清空系统剪贴板内容") {
            NSPasteboard.general.clearContents()
        },
        SystemAction(id: "netsettings", title: "网络设置", symbol: "network",
                     detail: "打开系统设置的网络面板") {
            openSystemApp("/System/Library/PreferencePanes/Network.prefPane")
        },
        SystemAction(id: "btsettings", title: "蓝牙设置", symbol: "dot.radiowaves.left.and.right",
                     detail: "打开系统设置的蓝牙面板") {
            openSystemApp("/System/Library/PreferencePanes/Bluetooth.prefPane")
        },
    ]

    static func action(_ id: String) -> SystemAction? {
        all.first { $0.id == id }
    }
}
