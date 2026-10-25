import AppKit

struct InstalledApp: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

enum AppScanner {
    private static var searchPaths: [String] {
        var paths = [
            "/Applications",
            "/System/Applications",
            "/Applications/Utilities",
            "/System/Applications/Utilities",
        ]
        paths.append(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications")
        return paths
    }

    /// 浅层扫描各个 Applications 目录，速度足够快（~百级 App 数量）
    static func scan() -> [InstalledApp] {
        var seen = Set<String>()
        var result: [InstalledApp] = []
        let fm = FileManager.default
        for dir in searchPaths {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".app") {
                let displayName = String(name.dropLast(4))
                guard seen.insert(displayName).inserted else { continue }
                result.append(InstalledApp(name: displayName, path: dir + "/" + name))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func path(bundleID: String) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".app") {
                let full = dir + "/" + name
                if Bundle(path: full)?.bundleIdentifier == bundleID { return full }
            }
        }
        return nil
    }
}
