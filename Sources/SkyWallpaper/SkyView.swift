#if canImport(AppKit)
import SwiftUI
import SkyCore

/// First-pass renderer using SwiftUI Canvas. It proves the scene model end to end;
/// milestone 4 moves clouds and precipitation into a Metal shader for richer looks.
struct SkyView: View {
    @EnvironmentObject var model: SkyModel
    @State private var starCache = StarCache()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / model.frameRate)) { timeline in
            Canvas { ctx, size in
                let date = timeline.date.addingTimeInterval(model.previewOffset)
                let builder = SkySceneBuilder(observer: model.observer, catalog: model.catalog)
                var scene = builder.scene(at: date, weather: model.weather, includeStars: false)
                scene.stars = starCache.stars(builder: builder, date: date, weather: model.weather)
                let t = timeline.date.timeIntervalSinceReferenceDate
                SkyPainter(scene: scene, size: size, time: t).paint(&ctx)
            }
        }
        .ignoresSafeArea()
    }
}

/// Star positions change slowly, so recompute them every few seconds rather than every frame.
final class StarCache {
    private var computedAt: Date = .distantPast
    private var cached: [VisibleStar] = []

    func stars(builder: SkySceneBuilder, date: Date, weather: WeatherConditions) -> [VisibleStar] {
        if abs(date.timeIntervalSince(computedAt)) > 5 {
            cached = builder.scene(at: date, weather: weather, includeStars: true).stars
            computedAt = date
        }
        return cached
    }
}

/// Maps sky directions to screen points. The view faces the equator (south in the northern
/// hemisphere), so the Sun rises at the left and sets at the right.
struct SkyProjection {
    var size: CGSize
    var facingAzimuth: Double
    var horizontalFOV: Double = 140
    var lowestAltitude: Double = -4
    var highestAltitude: Double = 66

    func point(_ h: HorizontalCoordinates) -> CGPoint? {
        let dAz = AstroMath.normalizeSigned(h.azimuth - facingAzimuth)
        guard abs(dAz) <= horizontalFOV / 2 + 5 else { return nil }
        let x = (dAz / horizontalFOV + 0.5) * size.width
        let y = (1 - (h.altitude - lowestAltitude) / (highestAltitude - lowestAltitude)) * size.height
        return CGPoint(x: x, y: y)
    }
}

struct SkyPainter {
    let scene: SkyScene
    let size: CGSize
    let time: TimeInterval

    private var projection: SkyProjection {
        SkyProjection(size: size, facingAzimuth: scene.observer.latitude >= 0 ? 180 : 0)
    }
    private var overcast: Double {
        max(scene.weather.cloudLow, scene.weather.cloudMid * 0.8, scene.weather.cloudHigh * 0.4)
    }

    func paint(_ ctx: inout GraphicsContext) {
        paintGradient(&ctx)
        paintStars(&ctx)
        paintSun(&ctx)
        paintClouds(&ctx)
        paintPrecipitation(&ctx)
        paintLightning(&ctx)
    }

    private func color(_ c: SkyColor, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
    }

    private func paintGradient(_ ctx: inout GraphicsContext) {
        // Overcast skies flatten towards grey.
        let grey = SkyColor(0.55, 0.58, 0.62)
        let dim = max(0.05, min(1, (scene.sun.horizontal.altitude + 8) / 20))
        let greyLit = SkyColor(grey.r * dim, grey.g * dim, grey.b * dim)
        let zenith = SkyColor.mix(scene.zenithColor, greyLit, overcast * 0.85)
        let horizon = SkyColor.mix(scene.horizonColor, greyLit, overcast * 0.85)
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [color(zenith), color(horizon)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    private func paintStars(_ ctx: inout GraphicsContext) {
        let fade = scene.starVisibility * (1 - overcast)
        guard fade > 0.01 else { return }
        for s in scene.stars {
            guard let p = projection.point(s.horizontal) else { continue }
            let m = s.star.magnitude
            let radius = max(0.5, 2.8 - 0.42 * m)
            // Twinkle more near the horizon, where we look through more air.
            let air = 1 - max(0, min(1, s.horizontal.altitude / 40))
            let twinkle = 1 - 0.35 * air * (0.5 + 0.5 * sin(time * (3 + Double(s.star.hr % 7)) + Double(s.star.hr)))
            let alpha = fade * twinkle * max(0.15, min(1, (6.8 - m) / 5))
            let c = blackBodyColor(kelvin: s.star.temperature)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: alpha)))
        }
    }

    private func paintSun(_ ctx: inout GraphicsContext) {
        guard let p = projection.point(scene.sun.horizontal) else { return }
        let h = scene.sun.horizontal.altitude
        let warmth = max(0, min(1, 1 - h / 12)) // redder near the horizon
        let glow = SkyColor.mix(SkyColor(1, 0.97, 0.88), SkyColor(1, 0.55, 0.25), warmth)
        let visible = 1 - overcast * 0.9
        let glowR = size.width * (0.12 + 0.18 * scene.sunGlow)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                 with: .radialGradient(Gradient(colors: [color(glow, 0.55 * visible), color(glow, 0)]),
                                       center: p, startRadius: 0, endRadius: glowR))
        guard h > -1.5 else { return }
        let r = size.width * 0.008
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .color(color(glow, visible)))
    }

    /// Simple placeholder clouds: soft blurred puffs in three parallax layers, drifting with the wind.
    private func paintClouds(_ ctx: inout GraphicsContext) {
        let w = scene.weather
        let h = scene.sun.horizontal.altitude
        let light = max(0.08, min(1, (h + 6) / 16))
        let sunset = max(0, 1 - abs(h - 2) / 8)
        let base = SkyColor.mix(SkyColor(light, light, light * 1.02), SkyColor(1, 0.6, 0.45), sunset * 0.6)
        let drift = (sin(w.windDirection * .pi / 180) >= 0 ? -1.0 : 1.0) * (0.002 + w.windSpeed * 0.0008)

        let layers: [(cover: Double, band: ClosedRange<Double>, count: Int, scale: Double, speed: Double, salt: Int)] = [
            (w.cloudHigh, 0.02...0.30, 18, 0.10, 0.4, 1),
            (w.cloudMid, 0.15...0.50, 22, 0.16, 0.7, 2),
            (w.cloudLow, 0.35...0.80, 26, 0.24, 1.0, 3),
        ]
        for layer in layers where layer.cover > 0.02 {
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: size.width * layer.scale * 0.18))
                let n = Int(Double(layer.count) * layer.cover) + 1
                for i in 0..<n {
                    let x = (rand(i, layer.salt) + time * drift * layer.speed).truncatingRemainder(dividingBy: 1.4)
                    let px = ((x < 0 ? x + 1.4 : x) - 0.2) * size.width
                    let band = layer.band
                    let py = (band.lowerBound + rand(i, layer.salt + 10) * (band.upperBound - band.lowerBound)) * size.height
                    let rw = size.width * layer.scale * (0.6 + rand(i, layer.salt + 20))
                    let rh = rw * (0.35 + 0.2 * rand(i, layer.salt + 30))
                    let shade = 0.75 + 0.25 * rand(i, layer.salt + 40)
                    let c = SkyColor(base.r * shade, base.g * shade, base.b * shade)
                    l.fill(Path(ellipseIn: CGRect(x: px - rw / 2, y: py - rh / 2, width: rw, height: rh)),
                           with: .color(color(c, 0.55 + 0.4 * layer.cover)))
                }
            }
        }
    }

    private func paintPrecipitation(_ ctx: inout GraphicsContext) {
        let w = scene.weather
        guard w.precipitation != .none else { return }
        let isSnow = w.precipitation == .snow
        let count = Int(min(600, 60 + w.precipitationRate * 120))
        let slant = -sin(w.windDirection * .pi / 180) * min(0.5, w.windSpeed / 20)
        let fall = isSnow ? 0.08 : 1.2 // screen heights per second
        for i in 0..<count {
            let speed = fall * (0.7 + 0.6 * rand(i, 50))
            let y = (rand(i, 51) + time * speed).truncatingRemainder(dividingBy: 1.0)
            var x = rand(i, 52) + slant * y
            if isSnow { x += 0.01 * sin(time * 1.5 + Double(i)) }
            let p = CGPoint(x: x * size.width, y: y * size.height)
            if isSnow {
                let r = 1.5 + 2 * rand(i, 53)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(0.75)))
            } else {
                var path = Path()
                let len = size.height * 0.025
                path.move(to: p)
                path.addLine(to: CGPoint(x: p.x - slant * len, y: p.y - len))
                ctx.stroke(path, with: .color(.white.opacity(0.28)), lineWidth: 1)
            }
        }
    }

    private func paintLightning(_ ctx: inout GraphicsContext) {
        guard scene.weather.isThunderstorm else { return }
        let slot = Int(time / 6)
        guard rand(slot, 90) > 0.7 else { return }
        let phase = time - Double(slot) * 6
        let flash = phase < 0.08 ? 0.6 : (phase > 0.16 && phase < 0.22 ? 0.4 : 0)
        guard flash > 0 else { return }
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(flash)))
    }

    /// Deterministic pseudo-random number in [0, 1) for element `i`.
    private func rand(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &* 73_856_093 ^ salt &* 19_349_663))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33; x &*= 0xc4ceb9fe1a85ec53; x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000
    }
}
#endif
