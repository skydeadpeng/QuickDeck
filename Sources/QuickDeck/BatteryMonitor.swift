import Foundation
import IOKit.ps

/// 通过 IOKit 读取电池电量；没有电池的台式机 level 保持 nil，界面自动隐藏
final class BatteryMonitor: ObservableObject {
    @Published var level: Int?
    @Published var charging = false

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let infoBlob = IOPSCopyPowerSourcesInfo() else {
            level = nil
            return
        }
        let info = infoBlob.takeRetainedValue()
        guard let listBlob = IOPSCopyPowerSourcesList(info) else {
            level = nil
            return
        }
        let sources = listBlob.takeRetainedValue() as [AnyObject]
        for source in sources {
            guard let descBlob = IOPSGetPowerSourceDescription(info, source),
                  let desc = descBlob.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }
            level = Int(round(Double(current) / Double(max) * 100))
            charging = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return
        }
        level = nil
    }

    var symbolName: String {
        guard let level else { return "battery.100" }
        if charging { return "bolt.fill" }
        switch level {
        case 90...: return "battery.100"
        case 60...: return "battery.75"
        case 35...: return "battery.50"
        case 10...: return "battery.25"
        default: return "battery.0"
        }
    }
}
