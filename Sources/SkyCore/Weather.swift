import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the renderer needs to know about the weather outside.
public struct WeatherConditions: Equatable, Sendable, Codable {
    public enum Precipitation: String, Sendable, Codable { case none, drizzle, rain, snow, sleet, hail }

    /// Cloud cover 0...1 in three height bands, drawn as parallax layers.
    public var cloudLow: Double
    public var cloudMid: Double
    public var cloudHigh: Double
    public var precipitation: Precipitation
    /// Precipitation rate in mm/h.
    public var precipitationRate: Double
    public var isThunderstorm: Bool
    /// Wind at 10 m: speed in m/s and the direction it blows FROM, degrees.
    public var windSpeed: Double
    public var windDirection: Double
    /// Visibility in metres (drives fog/haze), nil if unknown.
    public var visibility: Double?
    public var temperature: Double
    /// WMO weather interpretation code as reported.
    public var weatherCode: Int
    public var observedAt: Date

    public static let clear = WeatherConditions(
        cloudLow: 0, cloudMid: 0, cloudHigh: 0, precipitation: .none, precipitationRate: 0,
        isThunderstorm: false, windSpeed: 2, windDirection: 270, visibility: 30_000,
        temperature: 15, weatherCode: 0, observedAt: .distantPast)
}

/// A source of current weather. Open-Meteo is the default; WeatherKit can be added later.
public protocol WeatherProvider: Sendable {
    func currentConditions(for observer: Observer) async throws -> WeatherConditions
}

/// Free Open-Meteo forecast API (no key needed for personal, non-commercial use).
/// https://open-meteo.com/en/docs
public struct OpenMeteoProvider: WeatherProvider {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    static let fields = [
        "temperature_2m", "precipitation", "rain", "showers", "snowfall", "weather_code",
        "cloud_cover", "cloud_cover_low", "cloud_cover_mid", "cloud_cover_high",
        "wind_speed_10m", "wind_direction_10m", "visibility",
    ]

    public func requestURL(for observer: Observer) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", observer.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", observer.longitude)),
            URLQueryItem(name: "current", value: Self.fields.joined(separator: ",")),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        return c.url!
    }

    public func currentConditions(for observer: Observer) async throws -> WeatherConditions {
        let (data, response) = try await session.data(from: requestURL(for: observer))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try Self.parse(data)
    }

    struct Response: Decodable {
        struct Current: Decodable {
            var time: Double
            var temperature_2m: Double?
            var precipitation: Double?
            var rain: Double?
            var showers: Double?
            var snowfall: Double?
            var weather_code: Int?
            var cloud_cover: Double?
            var cloud_cover_low: Double?
            var cloud_cover_mid: Double?
            var cloud_cover_high: Double?
            var wind_speed_10m: Double?
            var wind_direction_10m: Double?
            var visibility: Double?
        }
        var current: Current
    }

    public static func parse(_ data: Data) throws -> WeatherConditions {
        let c = try JSONDecoder().decode(Response.self, from: data).current
        let code = c.weather_code ?? 0
        let total = c.cloud_cover ?? 0
        return WeatherConditions(
            cloudLow: (c.cloud_cover_low ?? total) / 100,
            cloudMid: (c.cloud_cover_mid ?? 0) / 100,
            cloudHigh: (c.cloud_cover_high ?? 0) / 100,
            precipitation: precipitationKind(weatherCode: code),
            precipitationRate: c.precipitation ?? ((c.rain ?? 0) + (c.showers ?? 0)),
            isThunderstorm: (95...99).contains(code),
            windSpeed: c.wind_speed_10m ?? 0,
            windDirection: c.wind_direction_10m ?? 0,
            visibility: c.visibility,
            temperature: c.temperature_2m ?? 15,
            weatherCode: code,
            observedAt: Date(timeIntervalSince1970: c.time)
        )
    }

    /// Maps WMO weather codes (as used by Open-Meteo) to a precipitation kind.
    public static func precipitationKind(weatherCode code: Int) -> WeatherConditions.Precipitation {
        switch code {
        case 51...55: return .drizzle
        case 56, 57, 66, 67: return .sleet
        case 61...65, 80...82, 95: return .rain
        case 71...77, 85, 86: return .snow
        case 96, 99: return .hail
        default: return .none
        }
    }
}

/// Polls a provider and keeps the last good result, so the sky still works offline.
public actor WeatherService {
    private let provider: WeatherProvider
    public private(set) var latest: WeatherConditions = .clear
    public var refreshInterval: TimeInterval = 15 * 60
    private var lastAttempt: Date = .distantPast

    public init(provider: WeatherProvider = OpenMeteoProvider()) {
        self.provider = provider
    }

    /// Makes the next `refreshIfNeeded` fetch immediately (for example after the location changes).
    public func forceNextRefresh() {
        lastAttempt = .distantPast
    }

    /// Fetches if the cached value is older than `refreshInterval`. Errors keep the old value.
    @discardableResult
    public func refreshIfNeeded(for observer: Observer, now: Date = Date()) async -> WeatherConditions {
        guard now.timeIntervalSince(lastAttempt) >= refreshInterval else { return latest }
        lastAttempt = now
        if let fresh = try? await provider.currentConditions(for: observer) {
            latest = fresh
        }
        return latest
    }
}
