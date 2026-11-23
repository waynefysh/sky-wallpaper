import Foundation

/// A small, fast, seedable random number generator (SplitMix64), so effects are repeatable in tests.
public struct SplitMix: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// One water drop on the glass, in points with the origin at the top left.
public struct GlassDrop: Sendable {
    public var x: Double
    public var y: Double
    public var radius: Double
    /// Downward speed, points per second (0 while it clings to the glass).
    public var speed: Double = 0
    /// Seconds until a sliding drop next sticks or lets go, which gives the stop-start motion.
    var stickTimer: Double = 0
    /// Distance slid since the drop last left a droplet behind.
    var sinceTrail: Double = 0

    public var isSliding: Bool { speed > 0 }
    var volume: Double { radius * radius * radius }
}

/// Rain on a window pane. Drops land at random, small ones cling, and once a drop grows past
/// a few points gravity wins: it slides down in fits and starts, wanders sideways, swallows
/// the drops in its path, and leaves a trail of tiny droplets behind. When the rain stops the
/// glass slowly dries.
public struct GlassRain: Sendable {
    public private(set) var drops: [GlassDrop] = []
    public var width: Double
    public var height: Double
    private var rng: SplitMix
    private var spawnDebt = 0.0

    /// Drops larger than this (points) start to slide.
    public static let slideRadius = 2.6
    static let maxDrops = 1_400

    public init(width: Double, height: Double, seed: UInt64 = 42) {
        self.width = width
        self.height = height
        rng = SplitMix(seed: seed)
    }

    /// Starts with the given drops (for tests).
    init(width: Double, height: Double, drops: [GlassDrop], seed: UInt64 = 42) {
        self.init(width: width, height: height, seed: seed)
        self.drops = drops
    }

    /// How hard it is raining on the glass, 0...1, from the weather.
    public static func intensity(for weather: WeatherConditions) -> Double {
        switch weather.precipitation {
        case .rain, .drizzle, .sleet, .hail:
            let base = weather.precipitation == .drizzle ? 0.15 : 0.3
            return min(1, base + weather.precipitationRate / 8)
        case .snow, .none:
            return 0
        }
    }

    /// Advances the simulation.
    /// - Parameters:
    ///   - dt: seconds since the last step (large gaps are clamped).
    ///   - intensity: 0 (dry) ... 1 (downpour).
    ///   - wind: sideways push, −1 (to the left) ... 1 (to the right).
    public mutating func step(dt rawDt: Double, intensity: Double, wind: Double = 0) {
        let dt = max(0, min(rawDt, 0.1))
        guard dt > 0, width > 0, height > 0 else { return }

        // New drops: about 5 per second per 100 000 square points at full rain.
        let area = width * height / 100_000
        spawnDebt += intensity * 5 * area * dt
        while spawnDebt >= 1 {
            spawnDebt -= 1
            guard drops.count < Self.maxDrops else { spawnDebt = 0; break }
            // Most drops are tiny; a few are big enough to run straight away.
            let u = rng.unit()
            let r = 0.6 + 3.2 * u * u * u
            drops.append(GlassDrop(x: rng.unit() * width, y: rng.unit() * height, radius: r))
        }

        var trail: [GlassDrop] = []
        for i in drops.indices {
            var d = drops[i]
            if d.radius >= Self.slideRadius {
                if d.stickTimer <= 0 {
                    // Alternate short slides and brief pauses, as a real drop catches on the glass.
                    let sliding = d.speed == 0 || rng.unit() < 0.8
                    d.speed = sliding ? 25 + 18 * (d.radius - Self.slideRadius) * (d.radius - Self.slideRadius) + 15 * rng.unit() : 0
                    d.stickTimer = sliding ? 0.15 + 0.6 * rng.unit() : 0.05 + 0.25 * rng.unit()
                }
                d.stickTimer -= dt
                if d.speed > 0 {
                    let dy = min(d.speed, 220) * dt
                    d.y += dy
                    d.x += (wind * 0.3 + (rng.unit() - 0.5) * 0.6) * dy
                    d.sinceTrail += dy
                    // Leave a droplet every few points, paying for it out of the drop's volume.
                    if d.sinceTrail > 3 + 4 * rng.unit() {
                        d.sinceTrail = 0
                        let tr = d.radius * (0.18 + 0.12 * rng.unit())
                        trail.append(GlassDrop(x: d.x + (rng.unit() - 0.5) * d.radius * 0.6, y: d.y - d.radius * 1.2, radius: tr))
                        d.radius = cbrt(max(0, d.volume - tr * tr * tr))
                    }
                }
            } else {
                d.speed = 0
            }
            // Evaporation, quicker once the rain has stopped.
            let dry = intensity > 0.01 ? 0.004 : 0.03
            d.radius -= dry * dt * (d.isSliding ? 0.2 : 1)
            drops[i] = d
        }

        merge()
        drops.append(contentsOf: trail.prefix(max(0, Self.maxDrops - drops.count)))
        drops.removeAll { $0.radius < 0.35 || $0.y - $0.radius > height || $0.x < -10 || $0.x > width + 10 }
    }

    /// Sliding drops absorb any drop they touch, conserving volume.
    private mutating func merge() {
        let cell = 12.0
        let cols = Int(width / cell) + 1
        var grid: [Int: [Int]] = [:]
        for (i, d) in drops.enumerated() {
            grid[Int(d.y / cell) * cols + Int(max(0, d.x) / cell), default: []].append(i)
        }
        var dead = Set<Int>()
        for i in drops.indices where drops[i].isSliding && !dead.contains(i) {
            let cx = Int(max(0, drops[i].x) / cell), cy = Int(drops[i].y / cell)
            for gy in (cy - 1)...(cy + 1) {
                for gx in (cx - 1)...(cx + 1) {
                    guard let bucket = grid[gy * cols + gx] else { continue }
                    for j in bucket where j != i && !dead.contains(j) {
                        let a = drops[i], b = drops[j]
                        let dx = a.x - b.x, dy = a.y - b.y
                        let reach = (a.radius + b.radius) * 0.85
                        guard dx * dx + dy * dy < reach * reach else { continue }
                        // The bigger drop keeps going with both volumes.
                        var keep = a.volume >= b.volume ? a : b
                        keep.radius = cbrt(a.volume + b.volume)
                        if !keep.isSliding { keep.speed = 1 }
                        drops[i] = keep
                        dead.insert(j)
                    }
                }
            }
        }
        if !dead.isEmpty {
            drops = drops.enumerated().filter { !dead.contains($0.offset) }.map(\.element)
        }
    }

    /// Total water on the glass, in cubic points (for tests).
    public var totalVolume: Double { drops.reduce(0) { $0 + $1.volume } }
}
