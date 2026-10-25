import AppKit
import Combine
import Darwin
import IOBluetooth
import SwiftUI

// MARK: - 当前网络状态（默认路由接口 + 类型标签；macOS 14+ 下 SSID 探测会被打码误报，不用它）

final class WiFiControl: ObservableObject {
    /// 当前真正上网用的接口（默认路由出口）
    @Published private(set) var primaryInterface: String?
    @Published private(set) var primaryIP: String?
    @Published private(set) var primaryLabel = ""

    private(set) var device: String?
    private var timer: VisibilityAwareTimer?

    init() {
        device = Self.discoverDevice()
        refresh()
        timer = VisibilityAwareTimer(
            interval: 5,
            onFire: { [weak self] in self?.refresh() },
            onResume: { [weak self] in self?.refresh() }
        )
    }

    /// 从硬件端口列表里找到 Wi-Fi 对应的网卡名（en0 / en1…），用于接口类型标注
    private static func discoverDevice() -> String? {
        portMap()["Wi-Fi"]
    }

    /// device → 硬件端口名 映射（含 iPhone USB / 以太网 / 雷电网桥等）
    private static func portMap() -> [String: String] {
        guard let output = runCommand("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return [:] }
        var map: [String: String] = [:]
        var currentPort: String?
        for line in output.components(separatedBy: .newlines) {
            if let range = line.range(of: "Hardware Port: (.+)", options: .regularExpression) {
                currentPort = String(line[range].dropFirst("Hardware Port: ".count)).trimmingCharacters(in: .whitespaces)
            } else if let range = line.range(of: "Device: (\\S+)", options: .regularExpression),
                      let port = currentPort {
                map[String(line[range].dropFirst("Device: ".count))] = port
            }
        }
        return map
    }

    /// 真正在用的网络接口 = 默认路由出口
    private static func defaultInterface() -> String? {
        guard let output = runCommand("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in output.components(separatedBy: .newlines) {
            if let range = line.range(of: "interface: \\S+", options: .regularExpression) {
                return String(line[range].dropFirst("interface: ".count))
            }
        }
        return nil
    }

    /// getifaddrs 直读某接口 IPv4，不依赖子进程
    private static func ipv4(of name: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            if String(cString: interface.ifa_name) == name,
               let sockaddr = interface.ifa_addr,
               sockaddr.pointee.sa_family == UInt8(AF_INET) {
                var address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buffer)
                }
            }
            cursor = interface.ifa_next
        }
        return nil
    }

    private static func interfaceLabel(interface: String, wifiDevice: String?, ports: [String: String]) -> String {
        if interface == wifiDevice { return "Wi-Fi" }
        let port = ports[interface] ?? interface
        if port.contains("iPhone") { return "iPhone USB 共享" }
        if port.contains("iPad") { return "iPad USB 共享" }
        if port.contains("Bluetooth") { return "蓝牙网络" }
        if port.contains("Thunderbolt") { return "雷电网桥" }
        if port.contains("Ethernet") || port.contains("适配器") || port.contains("USB") { return "以太网" }
        if interface.hasPrefix("utun") { return "VPN" }
        if interface.hasPrefix("bridge") { return "网桥" }
        return port
    }

    func refresh() {
        let ports = Self.portMap()
        primaryInterface = Self.defaultInterface()
        if let primary = primaryInterface {
            primaryIP = Self.ipv4(of: primary)
            primaryLabel = Self.interfaceLabel(interface: primary, wifiDevice: device, ports: ports)
        } else {
            primaryIP = nil
            primaryLabel = ""
        }
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
            bluetoothRow
            ipRow
        }
        .padding(.horizontal, 2)
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
                Text("当前网络").font(.system(size: 9)).foregroundStyle(.tertiary)
                if let ip = wifi.primaryIP, let interface = wifi.primaryInterface {
                    Text("\(ip) · \(wifi.primaryLabel.isEmpty ? interface : wifi.primaryLabel)")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                } else {
                    Text("未连接网络")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
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
