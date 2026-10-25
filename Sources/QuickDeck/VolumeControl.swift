import Combine
import SwiftUI

/// 系统音量：osascript 读写（无需权限），静音按钮与滑块共用状态
final class VolumeControl: ObservableObject {
    @Published var level = 0
    @Published var muted = false

    private var timer: VisibilityAwareTimer?

    init() {
        refresh()
        // 其他途径（键盘、菜单栏）改了音量也能同步回来
        timer = VisibilityAwareTimer(
            interval: 10,
            onFire: { [weak self] in self?.refresh() },
            onResume: { [weak self] in self?.refresh() }
        )
    }

    func refresh() {
        guard let out = runCommand("/usr/bin/osascript", ["-e", "get volume settings"]) else { return }
        // 形如 "output volume:33, input volume:66, alert volume:100, output muted:false"
        for part in out.components(separatedBy: ",") {
            let kv = part.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "output volume", let v = Int(kv[1]) {
                level = v
            }
            if kv[0] == "output muted" {
                muted = (kv[1] == "true")
            }
        }
    }

    func setLevel(_ value: Int) {
        runCommand("/usr/bin/osascript", ["-e", "set volume output volume \(value)"])
        level = value
        if value > 0 && muted { muted = false }
    }

    func toggleMute() {
        runCommand("/usr/bin/osascript", ["-e", muted ? "set volume without output muted" : "set volume with output muted"])
        muted.toggle()
    }
}

struct VolumeRow: View {
    @ObservedObject var control: VolumeControl
    @State private var sliderValue: Double = 50

    var body: some View {
        HStack(spacing: 8) {
            Button {
                control.toggleMute()
            } label: {
                Image(systemName: control.muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 12))
                    .foregroundStyle(control.muted ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(control.muted ? "取消静音" : "静音")

            Slider(value: $sliderValue, in: 0...100, onEditingChanged: { ended in
                if ended { control.setLevel(Int(sliderValue)) }
            })
            .controlSize(.mini)

            Text("\(control.level)")
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .onAppear { sliderValue = Double(control.level) }
        .onChange(of: control.level) { _, new in
            sliderValue = Double(new)
        }
    }
}
