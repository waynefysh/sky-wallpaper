#if canImport(AppKit)
import SwiftUI
import SkyCore

/// The live sky: redraws at the chosen frame rate behind the desktop icons.
/// Clouds and precipitation move to a Metal shader in a later milestone.
struct SkyView: View {
    @EnvironmentObject var model: SkyModel
    @State private var caches = SkyCaches()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / model.frameRate)) { timeline in
            Canvas { ctx, size in
                let date = timeline.date.addingTimeInterval(model.previewOffset)
                let scene = caches.scene(model: model, date: date)
                let fov = caches.fieldOfView(scene: scene)
                let background = caches.background(scene: scene, size: size, fov: fov)
                SkyPainter(scene: scene, size: size, time: timeline.date.timeIntervalSinceReferenceDate,
                           fov: fov, background: background).paint(&ctx)
            }
        }
        .ignoresSafeArea()
    }
}

/// One frozen frame of the sky, used for still-image wallpaper mode.
struct StillSkyView: View {
    let scene: SkyScene
    let fov: Double
    let background: CGImage?

    var body: some View {
        Canvas { ctx, size in
            SkyPainter(scene: scene, size: size, time: 0, fov: fov, background: background).paint(&ctx)
        }
    }
}

/// Work that does not need redoing every frame: star positions (every 5 s) and the
/// low-resolution sky background (every 2 s of sky time, or when something changes).
@MainActor
final class SkyCaches {
    private var starsAt: Date = .distantPast
    private var stars: [VisibleStar] = []
    private var backgroundKey: (date: Date, size: CGSize, observer: Observer, weather: WeatherConditions)?
    private var backgroundImage: CGImage?
    private var fovKey: (day: Date, observer: Observer)?
    private var fov: Double = 140

    /// Field of view for the scene's day, recomputed once per local day or when the location changes.
    func fieldOfView(scene: SkyScene) -> Double {
        let day = Calendar.current.startOfDay(for: scene.date)
        if let k = fovKey, k.day == day, k.observer == scene.observer { return fov }
        fov = SkyProjection.seasonalFieldOfView(observer: scene.observer, date: scene.date)
        fovKey = (day, scene.observer)
        return fov
    }

    func scene(model: SkyModel, date: Date) -> SkyScene {
        let builder = SkySceneBuilder(observer: model.observer, catalog: model.catalog)
        var scene = builder.scene(at: date, weather: model.weather, includeStars: false)
        if abs(date.timeIntervalSince(starsAt)) > 5 {
            stars = builder.scene(at: date, weather: model.weather, includeStars: true).stars
            starsAt = date
        }
        scene.stars = stars
        return scene
    }

    func background(scene: SkyScene, size: CGSize, fov: Double) -> CGImage? {
        if let k = backgroundKey, abs(scene.date.timeIntervalSince(k.date)) < 2, k.size == size,
           k.observer == scene.observer, k.weather == scene.weather, let img = backgroundImage {
            return img
        }
        backgroundImage = SkyBackground.image(scene: scene, size: size, fov: fov)
        backgroundKey = (scene.date, size, scene.observer, scene.weather)
        return backgroundImage
    }
}

enum SkyBackground {
    static let resolution = (width: 128, height: 80)

    static func projection(for scene: SkyScene, size: CGSize, fov: Double) -> SkyProjection {
        SkyProjection(width: size.width, height: size.height,
                      facingAzimuth: SkyProjection.equatorFacingAzimuth(for: scene.observer),
                      horizontalFOV: fov)
    }

    static func image(scene: SkyScene, size: CGSize, fov: Double) -> CGImage? {
        let (w, h) = resolution
        let bytes = SkyGradientRenderer().render(scene: scene, projection: projection(for: scene, size: size, fov: fov),
                                                 width: w, height: h)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct SkyPainter {
    let scene: SkyScene
    let size: CGSize
    let time: TimeInterval
    let fov: Double
    let background: CGImage?

    private var projection: SkyProjection { SkyBackground.projection(for: scene, size: size, fov: fov) }
    private var overcast: Double {
        max(scene.weather.cloudLow, scene.weather.cloudMid * 0.8, scene.weather.cloudHigh * 0.4)
    }

    private func point(_ h: HorizontalCoordinates) -> CGPoint? {
        projection.point(h).map { CGPoint(x: $0.x, y: $0.y) }
    }

    func paint(_ ctx: inout GraphicsContext) {
        paintBackground(&ctx)
        paintStars(&ctx)
        paintSun(&ctx)
        paintClouds(&ctx)
        paintPrecipitation(&ctx)
        paintLightning(&ctx)
    }

    private func color(_ c: SkyColor, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
    }

    private func paintBackground(_ ctx: inout GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        if let background {
            ctx.draw(Image(decorative: background, scale: 1).interpolation(.high).resizable(), in: rect)
        } else {
            ctx.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [color(scene.zenithColor), color(scene.horizonColor)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        // Overcast skies flatten towards grey, dimmer as the light fades.
        guard overcast > 0.02 else { return }
        let dim = max(0.05, min(1, (scene.sun.horizontal.altitude + 8) / 20))
        ctx.fill(Path(rect), with: .color(color(SkyColor(0.55 * dim, 0.58 * dim, 0.62 * dim), overcast * 0.85)))
    }

    private func paintStars(_ ctx: inout GraphicsContext) {
        let fade = scene.starVisibility * (1 - overcast)
        guard fade > 0.01 else { return }
        for s in scene.stars {
            guard let p = point(s.horizontal) else { continue }
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

    /// The Sun: a twilight glow (the daylight model already brightens the sky around the Sun),
    /// a soft bloom, and a limb-darkened disc that reddens near the horizon.
    private func paintSun(_ ctx: inout GraphicsContext) {
        guard let p = point(scene.sun.horizontal) else { return }
        let h = scene.sun.horizontal.altitude
        let warmth = max(0, min(1, 1 - h / 12))
        let tint = SkyColor.mix(SkyColor(1, 0.97, 0.90), SkyColor(1, 0.50, 0.22), warmth)
        let visible = 1 - overcast * 0.9

        let twilight = 1 - max(0, min(1, (h - 2) / 8))
        let glowR = size.width * (0.12 + 0.18 * scene.sunGlow)
        if twilight > 0 {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [color(tint, 0.5 * visible * twilight), color(tint, 0)]),
                                           center: p, startRadius: 0, endRadius: glowR))
        }
        guard h > -1.5 else { return }
        let r = size.width * 0.007
        let bloom = r * 6
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - bloom, y: p.y - bloom, width: bloom * 2, height: bloom * 2)),
                 with: .radialGradient(Gradient(colors: [color(tint, 0.6 * visible), color(tint, 0)]),
                                       center: p, startRadius: r, endRadius: bloom))
        let limb = SkyColor(tint.r * 0.92, tint.g * 0.80, tint.b * 0.65)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [color(SkyColor(1, 1, 0.97), visible), color(limb, visible)]),
                                       center: p, startRadius: 0, endRadius: r))
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
