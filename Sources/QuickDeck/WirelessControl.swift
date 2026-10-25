import AppKit
import Combine
import IOBluetooth
import SwiftUI

// MARK: - Wi-Fi 控制（networksetup，无需权限）

final class WiFiControl: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var ssid: String?
    @Published private(set) var ipAddress = "…"
    private(set) var device: String?
    private var timer: VisibilityAwareTimer?

    init() {
        device = Self.discoverDevice()
        refresh()
        timer = VisibilityAwareTimer(
            interval: 10,
            onFire: { [weak self] in self?.refresh() },
            onResume: { [weak self] in self?.refresh() }
        )
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
        refreshIP(device: device)
    }

    private func refreshIP(device: String) {
        if let ip = runCommand("/usr/sbin/ipconfig", ["getifaddr", device]), !ip.isEmpty {
            ipAddress = ip
        } else if let ip = runCommand("/usr/sbin/ipconfig", ["getifaddr", "en1"]), !ip.isEmpty {
            ipAddress = ip
        } else {
            ipAddress = "未获取到"
        }
    }

    func toggle() {
        guard let device else { return }
        runCommand("/usr/sbin/networksetup", ["-setairportpower", device, isOn ? "off" : "on"])
        refresh()
    }
}

// MARK: - 蓝牙控制（系统 IOBluetooth 框架，首次使用弹一次蓝牙授权）

/// 新 SDK 未把这两个 C 函数暴露给 Swift，从框架里动态取符号（blueutil 内部用的同一组函数）
private enum BluetoothPowerAPI {
    private static let framework = dlopen(
        "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY
    )

    static func get() -> Bool {
        guard let symbol = dlsym(framework, "IOBluetoothPreferenceGetControllerPowerState") else { return false }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)()
    }

    static func set(_ on: Bool) {
        guard let symbol = dlsym(framework, "IOBluetoothPreferenceSetControllerPowerState") else { return }
        unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(on)
    }
}

final class BluetoothControl: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var connectedNames: [String] = []
    /// 上次开关没有生效（多半是蓝牙权限没点允许）
    @Published private(set) var toggleFailed = false

    private var timer: VisibilityAwareTimer?

    init() {
        refresh()
        timer = VisibilityAwareTimer(
            interval: 15,
            onFire: { [weak self] in self?.refresh() },
            onResume: { [weak self] in self?.refresh() }
        )
    }

    func refresh() {
        isOn = BluetoothPowerAPI.get()
        var names: [String] = []
        if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in devices where device.isConnected() {
                if let name = device.name, !name.isEmpty {
                    names.append(name)
                }
            }
        }
        connectedNames = names
    }

    func toggle() {
        let before = isOn
        BluetoothPowerAPI.set(!before)
        // 蓝牙控制器切换状态需要一点时间，稍等再核对结果
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.refresh()
            self.toggleFailed = (self.isOn == before)
        }
    }
}

// MARK: - 面板上的网络区块

struct NetworkSection: View {
    @ObservedObject var wifi: WiFiControl
    @ObservedObject var bluetooth: BluetoothControl

    var body: some View {
        VStack(spacing: 8) {
            wifiRow
            bluetoothRow
            ipRow
        }
        .padding(.horizontal, 2)
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
                if bluetooth.toggleFailed {
                    HStack(spacing: 4) {
                        Text("开关未生效：请允许蓝牙权限")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                        Button("去开启") {
                            openSettingsPane("Bluetooth")
                        }
                        .buttonStyle(.link)
                        .controlSize(.mini)
                        .font(.system(size: 10))
                    }
                } else {
                    Text(bluetoothStatusText)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { bluetooth.isOn }, set: { _ in bluetooth.toggle() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("首次使用会弹一次蓝牙授权，点「允许」即可")
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
                Text(wifi.ipAddress)
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
}
