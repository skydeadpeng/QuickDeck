import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject var weather: WeatherModel
    @ObservedObject private var hotkeys = HotkeyManager.shared

    @State private var loginItemOn = SMAppService.mainApp.status == .enabled
    @State private var message: String?

    @AppStorage("deck.show.clipboard") private var showClipboard = true
    @AppStorage("deck.show.volume") private var showVolume = true
    @AppStorage("deck.show.memo") private var showMemo = false
    @AppStorage("deck.show.lunar") private var showLunar = true
    @AppStorage("deck.show.monitor") private var showMonitor = true
    @AppStorage("deck.show.network") private var showNetwork = true
    @AppStorage("deck.panel.width") private var panelWidth = 380
    @AppStorage("deck.appgrid.iconsize") private var appIconSize = 38
    @AppStorage("deck.clipboard.rows") private var clipboardRows = 4
    @State private var query = ""
    @State private var results: [SavedCity] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录 Mac 时自动打开", isOn: $loginItemOn)
                    .onChange(of: loginItemOn) { _, on in
                        toggleLoginItem(on)
                    }
                Button("恢复默认快捷方式") {
                    store.resetToDefault()
                    message = "已恢复为默认快捷方式"
                }
            }

            Section("显示内容") {
                Toggle("系统监控（CPU / 内存 / 网速）", isOn: $showMonitor)
                Toggle("网络与蓝牙（当前网络 / 蓝牙开关）", isOn: $showNetwork)
                Toggle("剪贴板历史", isOn: $showClipboard)
                Toggle("音量控制", isOn: $showVolume)
                Toggle("便签", isOn: $showMemo)
                Toggle("农历日期", isOn: $showLunar)
            }

            Section("面板宽度") {
                Picker("宽度", selection: $panelWidth) {
                    Text("紧凑 320").tag(320)
                    Text("标准 380").tag(380)
                    Text("宽敞 440").tag(440)
                }
                .pickerStyle(.segmented)
                Text("高度由开启的组件数量决定，在「显示内容」里增减即可")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("组件定制") {
                Picker("App 图标大小", selection: $appIconSize) {
                    Text("小").tag(32)
                    Text("中").tag(38)
                    Text("大").tag(46)
                }
                .pickerStyle(.segmented)
                Picker("剪贴板显示条数", selection: $clipboardRows) {
                    ForEach(2...8, id: \.self) { count in
                        Text("\(count) 条").tag(count)
                    }
                }
                Button("恢复默认界面") {
                    panelWidth = 380
                    appIconSize = 38
                    clipboardRows = 4
                    showMonitor = true
                    showNetwork = true
                    showClipboard = true
                    showVolume = true
                    showMemo = false
                    showLunar = true
                    message = "界面已恢复默认，面板位置和快捷方式不受影响"
                }
            }

            Section("快捷键（最多 \(HotkeyManager.maxSlots) 个，任意组合）") {
                ForEach(hotkeys.bindings.indices, id: \.self) { index in
                    HotkeySlotRow(index: index)
                }
                if hotkeys.bindings.count < HotkeyManager.maxSlots {
                    Menu {
                        ForEach(HotkeyAction.allCases) { action in
                            Button(action.title) {
                                hotkeys.appendBinding(action: action)
                            }
                        }
                    } label: {
                        Label("添加快捷键…", systemImage: "plus.circle")
                    }
                }
                if let error = hotkeys.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("点右侧按钮后直接按下想要的组合（如 ⌥C、⌘⇧K、F8），Esc 取消；建议至少保留一个「显示 / 隐藏面板」")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("天气城市（当前：\(weather.cityLabel)）") {
                TextField("输入城市名搜索，如：上海、Chengdu", text: $query)
                    .onChange(of: query) { _, q in scheduleSearch(q) }
                if !results.isEmpty {
                    ForEach(results, id: \.self) { city in
                        Button {
                            weather.setCity(city)
                            results = []
                            query = ""
                            message = "天气城市已切换为 \(city.name)"
                        } label: {
                            HStack {
                                Text(cityLabel(city))
                                Spacer()
                                if city == weather.city {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 560)
    }

    private func cityLabel(_ city: SavedCity) -> String {
        [city.name, city.admin, city.country].compactMap { $0 }.joined(separator: " · ")
    }

    private func toggleLoginItem(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
                message = "已开启开机自启（下次登录时生效）"
            } else {
                try SMAppService.mainApp.unregister()
                message = "已关闭开机自启"
            }
        } catch {
            loginItemOn = !on
            message = "设置失败：请先把 快捷台.app 放入「应用程序」文件夹后再开启"
        }
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let found = await WeatherModel.searchCities(trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run { results = found }
        }
    }
}

// MARK: - 快捷键槽位与录制器

struct HotkeySlotRow: View {
    @ObservedObject private var hotkeys = HotkeyManager.shared
    let index: Int

    var body: some View {
        let binding = hotkeys.bindings[index]
        HStack(spacing: 10) {
            Picker("动作", selection: actionSelection) {
                ForEach(HotkeyAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 158, alignment: .leading)
            Spacer(minLength: 0)
            HotkeyRecorder(text: HotkeyManager.comboText(binding)) { keyCode, modifiers in
                hotkeys.setBinding(index, HotkeyBinding(
                    action: binding.action,
                    keyCode: keyCode,
                    modifiers: modifiers
                ))
            }
            Button {
                hotkeys.removeBinding(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("删除该快捷键")
        }
    }

    private var actionSelection: Binding<HotkeyAction> {
        Binding(
            get: { hotkeys.bindings[index].action },
            set: { action in
                hotkeys.setBinding(index, HotkeyBinding(
                    action: action,
                    keyCode: hotkeys.bindings[index].keyCode,
                    modifiers: hotkeys.bindings[index].modifiers
                ))
            }
        )
    }
}

struct HotkeyRecorder: View {
    let text: String
    let onRecord: (Int, Int) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                if recording { stop() } else { start() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: recording ? "record.circle" : "keyboard")
                    Text(recording ? "按下组合键…" : text)
                }
                .frame(minWidth: 100)
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func start() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKey(event)
            return nil // 录制期间拦截按键，不透传给其他控件
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        let keyCode = Int(event.keyCode)
        let modifiers = HotkeyManager.carbonFlags(event.modifierFlags)
        let name = HotkeyManager.keyName(keyCode)
        let digits = name.dropFirst()
        let isFunctionKey = name.count >= 2 && name.first == "F" && digits.allSatisfy(\.isNumber)
        // 至少一个主要修饰键（⌘⌥⌃），或单独的功能键
        if modifiers & (cmdKey | optionKey | controlKey) == 0 && !isFunctionKey {
            hint = "需含 ⌘/⌥/⌃ 或用功能键"
            return
        }
        stop()
        onRecord(keyCode, modifiers)
    }
}
