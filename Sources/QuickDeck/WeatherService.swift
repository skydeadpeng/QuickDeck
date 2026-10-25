import Foundation

struct SavedCity: Codable, Hashable {
    var name: String
    var admin: String?
    var country: String?
    var lat: Double
    var lon: Double
}

struct WeatherNow: Codable, Hashable {
    var temperature: Int
    var code: Int
}

struct HourForecast: Hashable, Identifiable {
    let time: Date
    let temperature: Int
    let code: Int
    var id: Date { time }
}

/// Open-Meteo 免费 API（无需 Key），结果缓存 30 分钟，断网时保留最后结果显示
final class WeatherModel: ObservableObject {
    @Published private(set) var current: WeatherNow?
    @Published private(set) var city: SavedCity
    @Published private(set) var hourly: [HourForecast] = []
    @Published private(set) var hourlyUpdatedAt: Date?

    private let defaults = UserDefaults.standard
    private let cityKey = "deck.weather.city"
    private let cacheKey = "deck.weather.cache"

    private struct Cache: Codable {
        var now: WeatherNow
        var at: Date
    }

    init() {
        if let data = defaults.data(forKey: cityKey),
           let saved = try? JSONDecoder().decode(SavedCity.self, from: data) {
            city = saved
        } else {
            city = SavedCity(name: "北京", admin: "北京市", country: "中国", lat: 39.9042, lon: 116.4074)
        }
        if let data = defaults.data(forKey: cacheKey),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           Date().timeIntervalSince(cache.at) < 1800 {
            current = cache.now
        }
        Task { await refresh() }
    }

    func setCity(_ newCity: SavedCity) {
        city = newCity
        if let data = try? JSONEncoder().encode(newCity) {
            defaults.set(data, forKey: cityKey)
        }
        current = nil
        hourly = []
        hourlyUpdatedAt = nil
        Task { await refresh() }
    }

    func refresh() async {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(city.lat)),
            URLQueryItem(name: "longitude", value: String(city.lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url else { return }
        struct Response: Codable {
            struct Current: Codable {
                var temperature_2m: Double
                var weather_code: Int
            }
            var current: Current
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(Response.self, from: data)
            let now = WeatherNow(
                temperature: Int(response.current.temperature_2m.rounded()),
                code: response.current.weather_code
            )
            await MainActor.run {
                current = now
                if let data = try? JSONEncoder().encode(Cache(now: now, at: Date())) {
                    defaults.set(data, forKey: cacheKey)
                }
            }
        } catch {
            // 网络失败：保留缓存显示，下次再试
        }
    }

    /// 24 小时逐时预报（每 3 小时取一个点，紧凑显示），打开详情时拉取
    func fetchHourly() async {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(city.lat)),
            URLQueryItem(name: "longitude", value: String(city.lon)),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url else { return }
        struct Response: Codable {
            struct Hourly: Codable {
                var time: [String]
                var temperature_2m: [Double]
                var weather_code: [Int]
            }
            var hourly: Hourly
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(Response.self, from: data)
            let formatter = ISO8601DateFormatter()
            let now = Date().addingTimeInterval(-1800)
            let all: [HourForecast] = zip(zip(response.hourly.time, response.hourly.temperature_2m),
                                          response.hourly.weather_code).compactMap { pair, code in
                guard let date = formatter.date(from: pair.0),
                      date > now, date < now.addingTimeInterval(24 * 3600)
                else { return nil }
                return HourForecast(time: date, temperature: Int(pair.1.rounded()), code: code)
            }
            let sampled = Array(stride(from: 0, to: all.count, by: 3).map { all[$0] })
            await MainActor.run {
                hourly = sampled
                hourlyUpdatedAt = Date()
            }
        } catch {
            // 网络失败：保留旧数据
        }
    }

    static func searchCities(_ query: String) async -> [SavedCity] {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return [] }
        struct Geo: Codable {
            var name: String
            var latitude: Double
            var longitude: Double
            var admin1: String?
            var country: String?
        }
        struct Response: Codable { var results: [Geo]? }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(Response.self, from: data)
            return (response.results ?? []).map {
                SavedCity(name: $0.name, admin: $0.admin1, country: $0.country, lat: $0.latitude, lon: $0.longitude)
            }
        } catch {
            return []
        }
    }

    /// WMO 天气码 → 中文描述 + SF Symbol
    static func describe(code: Int) -> (text: String, symbol: String) {
        switch code {
        case 0: return ("晴", "sun.max.fill")
        case 1, 2: return ("多云", "cloud.sun.fill")
        case 3: return ("阴", "cloud.fill")
        case 45, 48: return ("雾", "cloud.fog.fill")
        case 51...57: return ("毛毛雨", "cloud.drizzle.fill")
        case 61...65: return ("雨", "cloud.rain.fill")
        case 66, 67: return ("冻雨", "cloud.sleet.fill")
        case 71...77: return ("雪", "snowflake")
        case 80...82: return ("阵雨", "cloud.heavyrain.fill")
        case 85, 86: return ("阵雪", "cloud.snow.fill")
        case 95...99: return ("雷雨", "cloud.bolt.rain.fill")
        default: return ("未知", "cloud.fill")
        }
    }

    var cityLabel: String {
        if let admin = city.admin, admin != city.name { return "\(city.name) · \(admin)" }
        return city.name
    }
}
