import Combine
import Darwin
import SwiftUI

/// CPU / 内存 / 网速监控：Mach 统计接口 + 网络接口字节计数，全部无需权限
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpuUsage: Double = 0 // 0-100
    @Published private(set) var ramPercent: Double = 0
    @Published private(set) var ramUsedGB: Double = 0
    @Published private(set) var ramTotalGB: Double = 0
    @Published private(set) var netInBytesPerSec: Double = 0
    @Published private(set) var netOutBytesPerSec: Double = 0

    private var timer: Timer?
    private var lastCPU: (idle: UInt64, busy: UInt64)?
    private var lastNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        readCPU()
        readRAM()
        readNetwork()
    }

    // MARK: - CPU（各核 tick 差值求平均）

    private func readCPU() {
        var cpuCount: natural_t = 0
        var infoPointer: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoPointer, &infoCount)
        guard kr == KERN_SUCCESS, let info = infoPointer else { return }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(MemoryLayout<integer_t>.stride) * vm_size_t(infoCount)
            )
        }
        var idle: UInt64 = 0
        var busy: UInt64 = 0
        let base = UnsafeMutableRawPointer(info)
        for core in 0..<Int(cpuCount) {
            let ticks = base
                .advanced(by: core * Int(CPU_STATE_MAX) * MemoryLayout<integer_t>.stride)
                .assumingMemoryBound(to: integer_t.self)
            busy += UInt64(ticks[Int(CPU_STATE_USER)]) + UInt64(ticks[Int(CPU_STATE_SYSTEM)]) + UInt64(ticks[Int(CPU_STATE_NICE)])
            idle += UInt64(ticks[Int(CPU_STATE_IDLE)])
        }
        if let last = lastCPU {
            let idleDelta = Double(idle &- last.idle)
            let totalDelta = Double((idle &+ busy) &- (last.idle &+ last.busy))
            if totalDelta > 0 {
                cpuUsage = min(100, max(0, (totalDelta - idleDelta) / totalDelta * 100))
            }
        }
        lastCPU = (idle, busy)
    }

    // MARK: - 内存（活跃 + 联动 + 压缩，与活动监视器口径接近）

    private func readRAM() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return }
        ramPercent = Double(used) / Double(total) * 100
        ramUsedGB = Double(used) / 1_073_741_824
        ramTotalGB = Double(total) / 1_073_741_824
    }

    // MARK: - 网速（PF_ROUTE 接口字节计数差值）

    private func readNetwork() {
        guard let counters = networkCounters() else { return }
        let now = Date()
        if let last = lastNet, counters.inBytes >= last.inBytes, counters.outBytes >= last.outBytes {
            let interval = max(0.5, now.timeIntervalSince(last.at))
            netInBytesPerSec = Double(counters.inBytes - last.inBytes) / interval
            netOutBytesPerSec = Double(counters.outBytes - last.outBytes) / interval
        }
        lastNet = (counters.inBytes, counters.outBytes, now)
    }

    private func networkCounters() -> (inBytes: UInt64, outBytes: UInt64)? {
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, AF_UNSPEC, NET_RT_IFLIST2]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var offset = 0
        while offset + MemoryLayout<if_msghdr2>.size <= size {
            let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
            guard header.ifm_msglen > 0 else { break }
            if header.ifm_type == UInt8(RTM_IFINFO2),
               header.ifm_flags & Int32(IFF_LOOPBACK) == 0,
               header.ifm_flags & Int32(IFF_UP) != 0 {
                let dataOffset = offset + MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_data)!
                let data = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: dataOffset, as: if_data64.self) }
                totalIn += data.ifi_ibytes
                totalOut += data.ifi_obytes
            }
            offset += Int(header.ifm_msglen)
        }
        return (totalIn, totalOut)
    }
}

// MARK: - 面板上的监控条

struct MonitorSection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CPU").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text("\(Int(monitor.cpuUsage.rounded()))%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                gaugeBar(ratio: monitor.cpuUsage / 100, color: .blue)
            }
            .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text("内存").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text("\(Int(monitor.ramPercent.rounded()))%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                gaugeBar(ratio: monitor.ramPercent / 100, color: .purple)
            }
            .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text("网速").font(.system(size: 9)).foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    speedLabel(direction: "arrow.down", value: monitor.netInBytesPerSec)
                    speedLabel(direction: "arrow.up", value: monitor.netOutBytesPerSec)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .help("CPU：各核平均占用\n内存：\(String(format: "%.1f", monitor.ramUsedGB)) / \(String(format: "%.0f", monitor.ramTotalGB)) GB\n网速：↓ 下载 ↑ 上传，每 2 秒刷新")
    }

    private func speedLabel(direction: String, value: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: direction)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(formatSpeed(value))
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
        }
    }

    private func gaugeBar(ratio: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(3, geo.size.width * min(1, max(0, ratio))))
            }
        }
        .frame(height: 3)
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return "\(Int(bytesPerSec))B/s" }
        if bytesPerSec < 1_048_576 { return String(format: "%.0fK/s", bytesPerSec / 1024) }
        return String(format: "%.1fM/s", bytesPerSec / 1_048_576)
    }
}
