import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject var weather: WeatherModel

    @State private var loginItemOn = SMAppService.mainApp.status == .enabled
    @State private var hotkeyIndex = HotkeyManager.shared.currentIndex
    @State private var message: String?

    @AppStorage("deck.show.clipboard") private var showClipboard = true
    @AppStorage("deck.show.volume") private var showVolume = true
    @AppStorage("deck.show.memo") private var showMemo = false
    @AppStorage("deck.show.lunar") private var showLunar = true
    @AppStorage("deck.show.monitor") private var showMonitor = true
    @AppStorage("deck.show.network") private var showNetwork = true
    @AppStorage("deck.panel.width") private var panelWidth = 380
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
            }

            Section("快捷键") {
                Picker("显示 / 隐藏面板", selection: $hotkeyIndex) {
                    ForEach(HotkeyManager.presets.indices, id: \.self) { index in
                        Text(HotkeyManager.presets[index].title).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: hotkeyIndex) { _, index in
                    HotkeyManager.shared.currentIndex = index
                }
                if HotkeyManager.shared.lastStatus != noErr {
                    Label("快捷键注册失败，可能与其他软件冲突，请换一个组合试试", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
        .frame(width: 340, height: 400)
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
