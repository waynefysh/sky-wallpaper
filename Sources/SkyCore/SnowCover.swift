import Foundation

/// Snow lying along the bottom of the screen, and on any ledge such as the Dock's shelf.
///
/// The screen width is split into columns. Each column has a floor (the height, in points
/// above the bottom of the screen, of whatever the snow rests on) and a depth of snow.
/// Flakes land unevenly, snow slumps when a slope gets too steep (so it slides off the ends
/// of the Dock and piles up beside it), and it melts when it is above freezing, faster in rain.
public struct SnowCover: Sendable {
    public let columnWidth: Double
    public private(set) var floor: [Double]
    public private(set) var depth: [Double]
    private var rng: SplitMix

    /// The steepest step allowed between neighbouring columns, in points, before snow slides.
    static let maxStep = 1.6
    public static let maxDepth = 48.0

    public init(width: Double, columnWidth: Double = 3, seed: UInt64 = 7) {
        self.columnWidth = columnWidth
        let n = max(1, Int((width / columnWidth).rounded(.up)))
        floor = Array(repeating: 0, count: n)
        depth = Array(repeating: 0, count: n)
        rng = SplitMix(seed: seed)
    }

    public var columnCount: Int { depth.count }

    /// Puts a ledge `height` points up between x-positions `from` and `to`; elsewhere the floor
    /// is the bottom of the screen. Snow already on columns whose floor changes falls to the ground.
    public mutating func setLedge(from: Double, to: Double, height: Double) {
        for i in floor.indices {
            let x = (Double(i) + 0.5) * columnWidth
            let f = (x >= from && x <= to) ? height : 0
            if f != floor[i] {
                if f == 0 { depth[i] = min(Self.maxDepth, depth[i] * 0.5) } else { depth[i] = 0 }
                floor[i] = f
            }
        }
    }

    public mutating func clearLedge() { setLedge(from: 1, to: 0, height: 0) }

    /// The top of the snow (or the bare floor) in column `i`, points above the screen bottom.
    public func surface(_ i: Int) -> Double { floor[i] + depth[i] }

    /// Surface height at x (points), linearly interpolated.
    public func surface(atX x: Double) -> Double {
        let f = x / columnWidth - 0.5
        let i = max(0, min(columnCount - 1, Int(f.rounded(.down))))
        let j = min(columnCount - 1, i + 1)
        let t = max(0, min(1, f - Double(i)))
        return surface(i) + (surface(j) - surface(i)) * t
    }

    /// How deep the snow should settle towards when it is already lying outside (points),
    /// from the reported snow depth in metres.
    public static func lyingDepth(snowDepth metres: Double) -> Double {
        min(maxDepth * 0.6, metres * 250)
    }

    /// Advances the snow by `dt` seconds of the given weather.
    public mutating func step(dt rawDt: Double, weather: WeatherConditions) {
        let dt = max(0, min(rawDt, 0.5))
        guard dt > 0 else { return }
        let n = columnCount
        let snowing = weather.precipitation == .snow ? 1.0 : (weather.precipitation == .sleet ? 0.35 : 0)
        // Moderate snow (1 mm/h of water) builds about 20 pt in 20 minutes.
        let fall = snowing * max(0.4, weather.precipitationRate) * 0.017 * dt
        if fall > 0 {
            // Flakes land in clumps, which keeps the surface lumpy.
            let hits = max(1, Int(Double(n) * 0.25))
            for _ in 0..<hits {
                let i = Int(rng.unit() * Double(n)) % n
                depth[i] = min(Self.maxDepth, depth[i] + fall * Double(n) / Double(hits) * (0.5 + rng.unit()))
            }
        }

        // Snow already on the ground (from the forecast) appears gradually, not all at once.
        let lying = Self.lyingDepth(snowDepth: weather.snowDepth)
        if lying > 0 {
            for i in 0..<n where floor[i] == 0 && depth[i] < lying {
                depth[i] = min(lying, depth[i] + 0.05 * dt * (0.5 + rng.unit()))
            }
        }

        // Melting: above freezing, faster in the rain. Snow the forecast says is lying stays.
        let rainy = weather.precipitation == .rain || weather.precipitation == .drizzle
        let melt = max(0, weather.temperature) * 0.004 + (rainy ? 0.02 : 0)
        if melt > 0 {
            for i in 0..<n {
                let keep = floor[i] == 0 ? lying : 0
                if depth[i] > keep { depth[i] = max(keep, depth[i] - melt * dt) }
            }
        }

        slump()
    }

    /// Lets snow slide downhill wherever a step between columns is steeper than `maxStep`.
    private mutating func slump() {
        let n = columnCount
        guard n > 1 else { return }
        for _ in 0..<2 {
            for i in 0..<(n - 1) {
                // At the end of a ledge, compare with the ledge itself, not the drop below it:
                // the edge holds a little snow, and anything more slides off and falls.
                let a = surface(i), b = surface(i + 1)
                let down = a - max(b, floor[i]), up = b - max(a, floor[i + 1])
                if down > Self.maxStep, depth[i] > 0 {
                    let move = min(depth[i], (down - Self.maxStep) * 0.5)
                    depth[i] -= move
                    depth[i + 1] = min(Self.maxDepth, depth[i + 1] + move)
                } else if up > Self.maxStep, depth[i + 1] > 0 {
                    let move = min(depth[i + 1], (up - Self.maxStep) * 0.5)
                    depth[i + 1] -= move
                    depth[i] = min(Self.maxDepth, depth[i] + move)
                }
            }
        }
    }

    public var totalSnow: Double { depth.reduce(0, +) }
}
