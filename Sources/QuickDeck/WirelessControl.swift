import AppKit
import Combine
import SwiftUI

// MARK: - Wi-Fi 控制（networksetup，无需权限）

final class WiFiControl: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var ssid: String?
    private(set) var device: String?
    private var timer: Timer?

    init() {
        device = Self.discoverDevice()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 从硬件端口列表里找到 Wi-Fi 对应的网卡名（en0 / en1…）
    private static func discoverDevice() -> String? {
        guard let output = runCommand("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        let lines = output.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.contains("Hardware Port: Wi-Fi") {
            for follow in lines[(index + 1)...].prefix(3) where follow.contains("Device:") {
                return follow.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func refresh() {
        guard let device else { return }
        if let power = runCommand("/usr/sbin/networksetup", ["-getairportpower", device]) {
            isOn = power.contains("On")
        }
        ssid = nil
        if isOn,
           let network = runCommand("/usr/sbin/networksetup", ["-getairportnetwork", device]),
           !network.contains("not associated"),
           let name = network.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces),
           !name.isEmpty, !network.contains("You are not") {
            ssid = name
        }
    }

    func toggle() {
        guard let device else { return }
        runCommand("/usr/sbin/networksetup", ["-setairportpower", device, isOn ? "off" : "on"])
        refresh()
    }
}

// MARK: - 蓝牙控制（blueutil，brew 安装）

final class BluetoothControl: ObservableObject {
    enum InstallState { case installed, missing }

    @Published private(set) var isOn = false
    @Published private(set) var connectedNames: [String] = []
    @Published private(set) var installState: InstallState = .missing
    @Published private(set) var installing = false

    private var timer: Timer?

    private static var blueutilPath: String? {
        ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    init() {
        installState = Self.blueutilPath == nil ? .missing : .installed
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let path = Self.blueutilPath else { return }
        if let power = runCommand(path, ["--power"]) {
            isOn = power.contains("1")
        }
        var names: [String] = []
        if let connected = runCommand(path, ["--connected"]) {
            for line in connected.components(separatedBy: .newlines) {
                guard let range = line.range(of: "\"[^\"]*\"", options: .regularExpression) else { continue }
                let name = line[range].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !name.isEmpty { names.append(name) }
            }
        }
        connectedNames = names
    }

    func toggle() {
        guard let path = Self.blueutilPath else { return }
        runCommand(path, ["--power", isOn ? "0" : "1"])
        refresh()
    }

    /// 面板内一键安装 blueutil（约 150KB）
    func installViaBrew() {
        guard !installing, let brew = Self.brewPath else { return }
        installing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = runCommand(brew, ["install", "blueutil"])
            DispatchQueue.main.async {
                self?.installing = false
                self?.installState = Self.blueutilPath == nil ? .missing : .installed
                self?.refresh()
            }
        }
    }
}

// MARK: - 面板上的网络区块

struct NetworkSection: View {
    @ObservedObject var wifi: WiFiControl
    @ObservedObject var bluetooth: BluetoothControl
    @State private var ipAddress = "…"

    var body: some View {
        VStack(spacing: 8) {
            wifiRow
            bluetoothRow
            ipRow
        }
        .padding(.horizontal, 2)
        .onAppear { refreshIP() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            refreshIP()
        }
    }

    private var wifiRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
                .font(.system(size: 12))
                .foregroundStyle(wifi.isOn ? Color.blue : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Wi-Fi").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(wifi.isOn ? (wifi.ssid ?? "已开启 · 未连接无线") : "已关闭")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { wifi.isOn }, set: { _ in wifi.toggle() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(wifi.device.map { "网卡 \($0)" } ?? "")
        }
    }

    private var bluetoothRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 12))
                .foregroundStyle(bluetooth.isOn ? Color.blue : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("蓝牙").font(.system(size: 9)).foregroundStyle(.tertiary)
                if bluetooth.installState == .installed {
                    Text(bluetoothStatusText)
                        .font(.system(size: 11))
                        .lineLimit(1)
                } else {
                    Button {
                        bluetooth.installViaBrew()
                    } label: {
                        Text(bluetooth.installing ? "正在安装 blueutil…" : "点此安装 blueutil 启用控制")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.link)
                    .controlSize(.mini)
                    .disabled(bluetooth.installing)
                }
            }
            Spacer()
            if bluetooth.installState == .installed {
                Toggle("", isOn: Binding(get: { bluetooth.isOn }, set: { _ in bluetooth.toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
    }

    private var bluetoothStatusText: String {
        guard bluetooth.isOn else { return "已关闭" }
        if bluetooth.connectedNames.isEmpty { return "已开启" }
        return "已连接 " + bluetooth.connectedNames.joined(separator: "、")
    }

    private var ipRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("IP 地址").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(ipAddress)
                    .font(.system(size: 11, design: .monospaced))
            }
            Spacer()
            Button {
                openSettingsPane("Network")
            } label: {
                Text("网络设置").font(.system(size: 9))
            }
            .buttonStyle(.link)
            .controlSize(.mini)
            Button {
                openSettingsPane("Bluetooth")
            } label: {
                Text("蓝牙设置").font(.system(size: 9))
            }
            .buttonStyle(.link)
            .controlSize(.mini)
        }
    }

    private func openSettingsPane(_ name: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/\(name).prefPane"))
    }

    private func refreshIP() {
        let device = wifi.device ?? "en0"
        if let ip = runCommand("/usr/sbin/ipconfig", ["getifaddr", device]), !ip.isEmpty {
            ipAddress = ip
        } else if let ip = runCommand("/usr/sbin/ipconfig", ["getifaddr", "en1"]), !ip.isEmpty {
            ipAddress = ip
        } else {
            ipAddress = "未获取到"
        }
    }
}
