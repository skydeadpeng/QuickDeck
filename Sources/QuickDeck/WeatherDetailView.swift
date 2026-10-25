import SwiftUI

/// 天气详情弹窗：当前天气 + 未来 24 小时逐时预报
struct WeatherDetailView: View {
    @ObservedObject var weather: WeatherModel

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH时"
        return f
    }()

    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            if weather.hourly.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在获取 24 小时预报…")
                    Spacer()
                }
                .padding(.vertical, 40)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(weather.hourly.enumerated()), id: \.element.id) { index, hour in
                            hourRow(hour, isNow: index == 0)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280, height: 400)
        .task {
            // 超过 30 分钟才重新拉取
            let stale = weather.hourlyUpdatedAt.map { Date().timeIntervalSince($0) > 1800 } ?? true
            if stale { await weather.fetchHourly() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(weather.cityLabel)
                    .font(.system(size: 14, weight: .semibold))
                if let now = weather.current {
                    let info = WeatherModel.describe(code: now.code)
                    HStack(spacing: 5) {
                        Image(systemName: info.symbol)
                        Text("\(now.temperature)° · \(info.text)")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let updated = weather.hourlyUpdatedAt {
                Text("更新于 \(Self.minuteFormatter.string(from: updated))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func hourRow(_ hour: HourForecast, isNow: Bool) -> some View {
        let info = WeatherModel.describe(code: hour.code)
        return HStack(spacing: 10) {
            Text(isNow ? "现在" : Self.hourFormatter.string(from: hour.time))
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isNow ? Color.primary : Color.secondary)
                .frame(width: 40, alignment: .leading)
            Image(systemName: info.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(info.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(hour.temperature)°")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isNow ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}
