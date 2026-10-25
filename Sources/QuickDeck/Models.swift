import AppKit

enum ShortcutKind: String, Codable {
    case app, url, folder, action
}

struct ShortcutItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ShortcutKind
    var title: String
    var path: String?
    var urlString: String?
    var actionID: String?
}

final class ShortcutStore: ObservableObject {
    @Published private(set) var items: [ShortcutItem] = []

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QuickDeck", isDirectory: true)
    }

    private var fileURL: URL { Self.supportDirectory.appendingPathComponent("shortcuts.json") }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ShortcutItem].self, from: data),
           !decoded.isEmpty {
            items = decoded
        } else {
            items = Self.defaultItems()
            persist()
        }
    }

    // MARK: - 增删

    func addApp(name: String, path: String) {
        guard !items.contains(where: { $0.kind == .app && $0.path == path }) else { return }
        items.append(ShortcutItem(kind: .app, title: name, path: path))
        persist()
    }

    func addURL(name: String, urlString: String) {
        items.append(ShortcutItem(kind: .url, title: name.isEmpty ? urlString : name, urlString: urlString))
        persist()
    }

    func addFolder(name: String, path: String) {
        guard !items.contains(where: { $0.kind == .folder && $0.path == path }) else { return }
        items.append(ShortcutItem(kind: .folder, title: name, path: path))
        persist()
    }

    func addSystemAction(id: String) {
        guard let action = SystemActions.action(id),
              !items.contains(where: { $0.actionID == id }) else { return }
        items.append(ShortcutItem(kind: .action, title: action.title, actionID: id))
        persist()
    }

    func remove(_ item: ShortcutItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// 拖动排序：把 id 对应的项移动到 targetID 之前
    func moveItem(_ id: UUID, before targetID: UUID?) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: from)
        if let targetID, let to = items.firstIndex(where: { $0.id == targetID }) {
            items.insert(item, at: to)
        } else {
            items.append(item)
        }
        persist()
    }

    /// 统一的执行入口：按类型打开 App / 网址 / 文件夹，或运行系统功能
    func performShortcut(_ item: ShortcutItem) {
        switch item.kind {
        case .app:
            if let p = item.path, FileManager.default.fileExists(atPath: p) {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
            }
        case .url:
            if let s = item.urlString, let u = URL(string: s) {
                NSWorkspace.shared.open(u)
            }
        case .folder:
            if let p = item.path {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
            }
        case .action:
            if let a = SystemActions.action(item.actionID ?? "") {
                a.run()
            }
        }
    }

    func resetToDefault() {
        items = Self.defaultItems()
        persist()
    }

    var appItems: [ShortcutItem] { items.filter { $0.kind == .app } }
    var actionItems: [ShortcutItem] { items.filter { $0.kind == .action } }
    var linkItems: [ShortcutItem] { items.filter { $0.kind == .url || $0.kind == .folder } }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 首次启动的默认配置

    /// 按顺序检测，装了哪个就加哪个，最多 8 个
    private static let appCandidates: [(bundleID: String, title: String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.tencent.xinWeChat", "微信"),
        ("com.apple.Notes", "备忘录"),
        ("com.apple.calculator", "计算器"),
        ("com.tencent.qq", "QQ"),
        ("com.netease.163music", "网易云音乐"),
        ("com.apple.Music", "音乐"),
        ("com.microsoft.VSCode", "VS Code"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.freeform", "无边记"),
    ]

    private static let defaultActionIDs = ["screenshot", "lock", "trash", "darkmode", "mute"]

    static func defaultItems() -> [ShortcutItem] {
        var result: [ShortcutItem] = []
        for candidate in appCandidates where result.count < 8 {
            if let path = AppScanner.path(bundleID: candidate.bundleID) {
                result.append(ShortcutItem(kind: .app, title: candidate.title, path: path))
            }
        }
        for id in defaultActionIDs {
            if let action = SystemActions.action(id) {
                result.append(ShortcutItem(kind: .action, title: action.title, actionID: id))
            }
        }
        return result
    }
}
