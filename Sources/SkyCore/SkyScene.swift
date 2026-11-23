import Foundation

/// A linear RGB colour, components 0...1.
public struct SkyColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    public static func mix(_ a: SkyColor, _ b: SkyColor, _ t: Double) -> SkyColor {
        let t = max(0, min(1, t))
        return SkyColor(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }
}

/// Where we are in the day, from the Sun's altitude.
public enum SkyPhase: String, Sendable {
    case night, astronomicalTwilight, nauticalTwilight, civilTwilight, goldenHour, day

    public init(sunAltitude h: Double) {
        switch h {
        case ..<(-18): self = .night
        case ..<(-12): self = .astronomicalTwilight
        case ..<(-6): self = .nauticalTwilight
        case ..<(-0.833): self = .civilTwilight
        case ..<6: self = .goldenHour
        default: self = .day
        }
    }
}

/// Everything the renderer needs for one frame. Built by `SkySceneBuilder`, drawn by the app.
public struct SkyScene: Sendable {
    public var date: Date
    public var observer: Observer
    public var sun: SolarPosition
    public var phase: SkyPhase
    /// Gradient from the zenith down to the horizon.
    public var zenithColor: SkyColor
    public var horizonColor: SkyColor
    /// Extra warm glow near the horizon in the Sun's direction (0...1).
    public var sunGlow: Double
    /// How visible the stars are (0 in daylight, 1 in full darkness), before cloud.
    public var starVisibility: Double
    public var stars: [VisibleStar]
    public var weather: WeatherConditions
}

/// Builds a `SkyScene` from location, time and weather. Pure and fast enough to run every frame;
/// the star list is the costly part, so callers may refresh it every few seconds instead.
public struct SkySceneBuilder: Sendable {
    public var observer: Observer
    public var catalog: StarCatalog?

    public init(observer: Observer, catalog: StarCatalog?) {
        self.observer = observer
        self.catalog = catalog
    }

    public func scene(at date: Date, weather: WeatherConditions,
                      includeStars: Bool = true) -> SkyScene {
        let sun = SolarCalculator(observer: observer).position(at: date)
        let h = sun.horizontal.altitude
        let (zenith, horizon) = Self.gradient(sunAltitude: h)
        // Stars fade in through nautical twilight and are fully out at astronomical night.
        let starVis = max(0, min(1, (-h - 4) / 12))
        let cloud = max(weather.cloudLow, weather.cloudMid * 0.8, weather.cloudHigh * 0.4)
        let stars = (includeStars && starVis > 0)
            ? (catalog?.visibleStars(observer: observer, at: date,
                                     limitingMagnitude: 2 + 4.5 * starVis * (1 - cloud)) ?? [])
            : []
        return SkyScene(
            date: date, observer: observer, sun: sun, phase: SkyPhase(sunAltitude: h),
            zenithColor: zenith, horizonColor: horizon,
            sunGlow: max(0, 1 - abs(h + 2) / 10),
            starVisibility: starVis, stars: stars, weather: weather)
    }

    /// Keyframed sky colours by solar altitude. A first pass; the Metal shader can replace it
    /// with a physical scattering model later.
    static let keys: [(alt: Double, zenith: SkyColor, horizon: SkyColor)] = [
        (-90, SkyColor(0.005, 0.008, 0.02), SkyColor(0.01, 0.015, 0.035)),
        (-18, SkyColor(0.005, 0.008, 0.02), SkyColor(0.01, 0.015, 0.035)),
        (-12, SkyColor(0.01, 0.02, 0.06), SkyColor(0.04, 0.05, 0.12)),
        (-6, SkyColor(0.03, 0.06, 0.18), SkyColor(0.30, 0.22, 0.35)),
        (-2, SkyColor(0.08, 0.14, 0.35), SkyColor(0.85, 0.45, 0.30)),
        (2, SkyColor(0.16, 0.30, 0.60), SkyColor(0.98, 0.65, 0.40)),
        (8, SkyColor(0.22, 0.45, 0.82), SkyColor(0.80, 0.80, 0.85)),
        (25, SkyColor(0.20, 0.45, 0.88), SkyColor(0.68, 0.80, 0.95)),
        (90, SkyColor(0.16, 0.40, 0.88), SkyColor(0.62, 0.78, 0.96)),
    ]

    public static func gradient(sunAltitude h: Double) -> (zenith: SkyColor, horizon: SkyColor) {
        for i in 1..<keys.count where h <= keys[i].alt {
            let a = keys[i - 1], b = keys[i]
            let t = (h - a.alt) / (b.alt - a.alt)
            return (SkyColor.mix(a.zenith, b.zenith, t), SkyColor.mix(a.horizon, b.horizon, t))
        }
        return (keys[keys.count - 1].zenith, keys[keys.count - 1].horizon)
    }
}
