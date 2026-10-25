import AppKit
import SwiftUI

/// 管理各类「添加 / 设置」弹层窗口（带标题栏的普通面板，可正常输入文字）
enum WindowManager {
    private static var panels: [String: NSPanel] = [:]

    static func presentAppPicker(store: ShortcutStore) {
        present(id: "apppicker", title: "添加 App", size: NSSize(width: 320, height: 460)) {
            AppPickerView(store: store)
        }
    }

    static func presentActionPicker(store: ShortcutStore) {
        present(id: "actionpicker", title: "添加系统功能", size: NSSize(width: 330, height: 440)) {
            ActionPickerView(store: store)
        }
    }

    static func presentURLForm(store: ShortcutStore) {
        present(id: "urlform", title: "添加网址", size: NSSize(width: 300, height: 190)) {
            URLFormView(store: store)
        }
    }

    static func presentSettings(store: ShortcutStore, weather: WeatherModel) {
        present(id: "settings", title: "快捷台 设置", size: NSSize(width: 360, height: 460)) {
            SettingsView(store: store, weather: weather)
        }
    }

    static func presentClipboardHistory(monitor: ClipboardMonitor) {
        present(id: "clipboard", title: "剪贴板历史", size: NSSize(width: 380, height: 480)) {
            ClipboardHistoryView(monitor: monitor)
        }
    }

    static func close(id: String) {
        panels[id]?.close()
        panels[id] = nil
    }

    private static func present<V: View>(id: String, title: String, size: NSSize, @ViewBuilder content: () -> V) {
        if let old = panels[id] { old.close() }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content())
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        if hosting.fittingSize.width > 50, hosting.fittingSize.height > 50 {
            panel.setContentSize(hosting.fittingSize)
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panels[id] = panel
    }

    static func pickFolder(store: ShortcutStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "选择要添加到快捷面板的文件夹"
        panel.prompt = "添加"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            store.addFolder(name: url.lastPathComponent, path: url.path)
        }
    }
}

// MARK: - App 选择器

struct AppPickerView: View {
    @ObservedObject var store: ShortcutStore
    @State private var query = ""
    @State private var apps: [InstalledApp] = []

    private var filtered: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 App 名称…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { app in
                        AppPickerRow(app: app, added: store.appItems.contains { $0.path == app.path }) {
                            store.addApp(name: app.name, path: app.path)
                        }
                    }
                    if filtered.isEmpty {
                        Text("没有找到匹配的 App")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 300, minHeight: 400)
        .onAppear { apps = AppScanner.scan() }
    }
}

struct AppPickerRow: View {
    let app: InstalledApp
    let added: Bool
    let onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 24, height: 24)
            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(added ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !added { onAdd() } }
    }
}

// MARK: - 系统功能选择器

struct ActionPickerView: View {
    @ObservedObject var store: ShortcutStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(SystemActions.all) { action in
                    let added = store.actionItems.contains { $0.actionID == action.id }
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 16))
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.title).font(.system(size: 12, weight: .medium))
                            Text(action.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(added ? Color.green : Color.secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                    .onTapGesture { if !added { store.addSystemAction(id: action.id) } }
                }
            }
            .padding(10)
        }
        .frame(minWidth: 310, minHeight: 380)
    }
}

// MARK: - 添加网址

struct URLFormView: View {
    @ObservedObject var store: ShortcutStore
    @State private var name = ""
    @State private var urlText = ""

    private var canAdd: Bool {
        let s = urlText.trimmingCharacters(in: .whitespaces)
        return !s.isEmpty && s.contains(".") && !s.contains(" ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("例如：百度", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("网址").font(.caption).foregroundStyle(.secondary)
                TextField("例如：baidu.com", text: $urlText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("取消") { close(id: "urlform") }
                Button("添加") {
                    var s = urlText.trimmingCharacters(in: .whitespaces)
                    if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
                        s = "https://" + s
                    }
                    store.addURL(name: name, urlString: s)
                    close(id: "urlform")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func close(id: String) { WindowManager.close(id: id) }
}
