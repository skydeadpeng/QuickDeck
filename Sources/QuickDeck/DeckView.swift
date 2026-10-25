import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DeckView: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject var weather: WeatherModel
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var clipboard: ClipboardMonitor
    @ObservedObject var volume: VolumeControl
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var wifi: WiFiControl
    @ObservedObject var bluetooth: BluetoothControl
    @State private var editMode = false
    @State private var searchText = ""
    @State private var allApps: [InstalledApp] = []
    @State private var draggingID: UUID?

    @AppStorage("deck.show.clipboard") private var showClipboard = true
    @AppStorage("deck.show.volume") private var showVolume = true
    @AppStorage("deck.show.memo") private var showMemo = false
    @AppStorage("deck.show.lunar") private var showLunar = true
    @AppStorage("deck.show.monitor") private var showMonitor = true
    @AppStorage("deck.show.network") private var showNetwork = true
    @AppStorage("deck.panel.width") private var panelWidth = 380
    @AppStorage("deck.appgrid.iconsize") private var appIconSize = 38

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    var body: some View {
        VStack(spacing: 11) {
            header
            if showMonitor {
                sectionDivider
                MonitorSection(monitor: monitor)
            }
            if showNetwork {
                sectionDivider
                NetworkSection(wifi: wifi, bluetooth: bluetooth)
            }
            searchBar
            if searchText.isEmpty {
                if !store.appItems.isEmpty || editMode {
                    sectionDivider
                    appGrid
                }
                if !store.actionItems.isEmpty || editMode {
                    sectionDivider
                    actionGrid
                }
                if !store.linkItems.isEmpty || editMode {
                    sectionDivider
                    linkGrid
                }
                if showVolume {
                    sectionDivider
                    VolumeRow(control: volume)
                }
                if showClipboard {
                    sectionDivider
                    ClipboardSection(monitor: clipboard)
                }
                if showMemo {
                    sectionDivider
                    MemoSection()
                }
            } else {
                SearchResultsView(store: store, query: searchText, allApps: allApps) {
                    searchText = ""
                }
            }
        }
        .padding(14)
        .frame(width: CGFloat(panelWidth))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .contextMenu { contextMenu }
        .onAppear { allApps = AppScanner.scan() }
        .onChange(of: editMode) { _, _ in notifySizeChanged() }
        .onChange(of: searchText) { _, _ in notifySizeChanged() }
        .onChange(of: showClipboard) { _, _ in notifySizeChanged() }
        .onChange(of: showVolume) { _, _ in notifySizeChanged() }
        .onChange(of: showMemo) { _, _ in notifySizeChanged() }
        .onChange(of: showMonitor) { _, _ in notifySizeChanged() }
        .onChange(of: showNetwork) { _, _ in notifySizeChanged() }
        .onChange(of: panelWidth) { _, _ in notifySizeChanged() }
        .onChange(of: appIconSize) { _, _ in notifySizeChanged() }

    }

    private func notifySizeChanged() {
        NotificationCenter.default.post(name: .deckContentChanged, object: nil)
    }

    // MARK: - 顶部信息条

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(Self.timeFormatter.string(from: timeline.date))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Text(Self.dateFormatter.string(from: Date())
                     + (showLunar ? " · 农历" + LunarDate.string() : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 10) {
                    if let now = weather.current {
                        let info = WeatherModel.describe(code: now.code)
                        HStack(spacing: 4) {
                            Image(systemName: info.symbol)
                            Text("\(now.temperature)°")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .contentShape(Rectangle())
                        .onTapGesture { WindowManager.presentWeatherDetail(weather: weather) }
                        .help("\(weather.cityLabel) · \(info.text) · 点击查看 24 小时预报")
                    }
                    if let level = battery.level {
                        HStack(spacing: 3) {
                            Image(systemName: battery.symbolName)
                            Text("\(level)%")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(level <= 20 && !battery.charging ? Color.red : Color.secondary)
                        .help(battery.charging ? "正在充电" : "电池电量")
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        NotificationCenter.default.post(name: .deckHidePanel, object: nil)
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("隐藏面板（按 \(HotkeyManager.shared.currentTitle) 呼回）")

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { editMode.toggle() }
                    } label: {
                        Image(systemName: editMode ? "checkmark.circle.fill" : "pencil.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(editMode ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(editMode ? "完成编辑" : "编辑快捷方式")
                }
            }
        }
    }

    // MARK: - 搜索栏（面板项 + 全盘 App + 算式计算）

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索 App / 功能，或输入 12*8 算式", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { submitSearch() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空 (Esc)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .onExitCommand { searchText = "" }
    }

    /// 回车：优先算式（复制结果），其次面板项 / 已安装 App（直接打开）
    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if let value = MathParser.evaluate(query) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(MathParser.formatNumber(value), forType: .string)
        } else if let first = SearchEngine.shortcutMatches(store, query).first {
            store.performShortcut(first)
        } else if let first = SearchEngine.appMatches(allApps, store, query).first {
            NSWorkspace.shared.open(URL(fileURLWithPath: first.path))
        } else {
            return
        }
        searchText = ""
    }

    // MARK: - App 网格（列数随面板宽度与图标大小自适应）

    private var appGridColumns: [GridItem] {
        let count = max(4, Int((CGFloat(panelWidth) - 28) / (CGFloat(appIconSize) + 22)))
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: count)
    }

    private var appGrid: some View {
        LazyVGrid(columns: appGridColumns, spacing: 8) {
            ForEach(store.appItems) { item in
                AppCell(item: item, editing: editMode) {
                    store.performShortcut(item)
                } onDelete: {
                    store.remove(item)
                }
                .reorderable(if: editMode, item: item, dragging: $draggingID, store: store)
            }
            if editMode {
                AddCell(label: "App") {
                    WindowManager.presentAppPicker(store: store)
                }
            }
        }
    }

    // MARK: - 系统功能

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
            ForEach(store.actionItems) { item in
                ActionCell(item: item, editing: editMode) {
                    store.performShortcut(item)
                } onDelete: {
                    store.remove(item)
                }
                .reorderable(if: editMode, item: item, dragging: $draggingID, store: store)
            }
            if editMode {
                AddCell(label: "功能") {
                    WindowManager.presentActionPicker(store: store)
                }
            }
        }
    }

    // MARK: - 网址 / 文件夹

    private var linkGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6)], spacing: 6) {
            ForEach(store.linkItems) { item in
                LinkCell(item: item, editing: editMode) {
                    store.performShortcut(item)
                } onDelete: {
                    store.remove(item)
                }
                .reorderable(if: editMode, item: item, dragging: $draggingID, store: store)
            }
            if editMode {
                AddCell(label: "网址") { WindowManager.presentURLForm(store: store) }
                AddCell(label: "文件夹") { WindowManager.pickFolder(store: store) }
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    @ViewBuilder private var contextMenu: some View {
        Button(editMode ? "完成编辑" : "编辑快捷方式") { editMode.toggle() }
        Divider()
        Button("添加 App…") { WindowManager.presentAppPicker(store: store) }
        Button("添加网址…") { WindowManager.presentURLForm(store: store) }
        Button("添加文件夹…") { WindowManager.pickFolder(store: store) }
        Button("添加系统功能…") { WindowManager.presentActionPicker(store: store) }
        Divider()
        Button("设置…") { WindowManager.presentSettings(store: store, weather: weather) }
        Button("隐藏面板（\(HotkeyManager.shared.currentTitle) 呼回）") {
            NotificationCenter.default.post(name: .deckHidePanel, object: nil)
        }
        Button("退出 快捷台") { NSApp.terminate(nil) }
    }
}

// MARK: - 便签（自动保存）

struct MemoSection: View {
    @AppStorage("deck.memo.text") private var memo = ""

    var body: some View {
        TextField("便签：随手记录，自动保存", text: $memo, axis: .vertical)
            .lineLimit(2...6)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - 编辑模式下的拖动排序

struct ReorderDropDelegate: DropDelegate {
    let target: ShortcutItem
    @Binding var dragging: UUID?
    let store: ShortcutStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target.id else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            store.moveItem(dragging, before: target.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

extension View {
    /// 仅编辑模式下启用拖动排序
    @ViewBuilder
    func reorderable(if active: Bool, item: ShortcutItem, dragging: Binding<UUID?>, store: ShortcutStore) -> some View {
        if active {
            self.onDrag {
                dragging.wrappedValue = item.id
                return NSItemProvider(object: item.id.uuidString as NSString)
            }
            .onDrop(of: [.text, .utf8PlainText], delegate: ReorderDropDelegate(target: item, dragging: dragging, store: store))
        } else {
            self
        }
    }
}

// MARK: - 单元格

struct AppCell: View {
    let item: ShortcutItem
    let editing: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @AppStorage("deck.appgrid.iconsize") private var iconSize = 38

    private var appExists: Bool {
        item.path.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path ?? "/"))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: CGFloat(iconSize), height: CGFloat(iconSize))
                    .opacity(appExists ? 1 : 0.3)
                if editing {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .offset(x: 16, y: -16)
                        .onTapGesture(perform: onDelete)
                }
            }
            Text(item.title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .scaleEffect(hovering && !editing ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !editing && appExists { onOpen() } }
        .help(appExists ? "打开 \(item.title)" : "\(item.title) 已不存在，编辑模式下可移除")
        .wiggle(active: editing)
    }
}

struct ActionCell: View {
    let item: ShortcutItem
    let editing: Bool
    let onRun: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var action: SystemAction? { SystemActions.action(item.actionID ?? "") }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Image(systemName: action?.symbol ?? "questionmark")
                    .font(.system(size: 14, weight: .medium))
                if editing {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .offset(x: 14, y: -10)
                        .onTapGesture(perform: onDelete)
                }
            }
            Text(action?.title ?? item.title)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(hovering ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !editing { onRun() } }
        .help(action?.detail ?? "")
        .wiggle(active: editing)
    }
}

struct LinkCell: View {
    let item: ShortcutItem
    let editing: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var symbol: String { item.kind == .url ? "globe" : "folder.fill" }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(item.kind == .url ? Color.blue : Color.yellow)
            Text(item.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
            if editing {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .onTapGesture(perform: onDelete)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !editing { onOpen() } }
        .wiggle(active: editing)
    }
}

struct AddCell: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.secondary)
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .scaleEffect(hovering ? 1.06 : 1)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - 编辑模式的抖动效果

struct WiggleModifier: ViewModifier {
    let active: Bool
    @State private var shaking = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active && shaking ? 1.6 : -1.6))
            .onChange(of: active) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) {
                        shaking = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { shaking = false }
                }
            }
    }
}

extension View {
    func wiggle(active: Bool) -> some View {
        modifier(WiggleModifier(active: active))
    }
}
