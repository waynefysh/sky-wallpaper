#if canImport(AppKit)
import SwiftUI
import ImageIO
import SkyCore

/// The live sky: redraws at the chosen frame rate behind the desktop icons.
struct SkyView: View {
    @EnvironmentObject var model: SkyModel
    /// The screen this view fills, so rain on the glass and snow are kept per screen.
    let screenID: CGDirectDisplayID
    @State private var caches = SkyCaches()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / model.frameRate)) { timeline in
            Canvas { ctx, size in
                let date = timeline.date.addingTimeInterval(model.previewOffset)
                let now = timeline.date.timeIntervalSinceReferenceDate
                let weather = model.effectiveWeather
                let scene = caches.scene(model: model, date: date, weather: weather)
                let fov = caches.fieldOfView(scene: scene)
                let background = caches.background(scene: scene, size: size, fov: fov)
                let effects = model.effects.screen(screenID, size: size)
                effects.advance(to: now, weather: weather, glass: model.glassMode != .off)
                var painter = SkyPainter(scene: scene, size: size, time: now, fov: fov, background: background,
                                         moonImage: caches.moonImage(scene: scene, size: size, fov: fov))
                painter.clouds = caches.clouds(scene: scene, size: size, fov: fov, now: now)
                painter.effects = effects.snapshot
                painter.glassOnDesktop = model.glassMode == .desktop
                painter.backgroundPixels = caches.backgroundPixels
                painter.paint(&ctx)
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
    var moonImage: CGImage? = nil
    var clouds: CGImage? = nil

    var body: some View {
        Canvas { ctx, size in
            var painter = SkyPainter(scene: scene, size: size, time: 0, fov: fov, background: background,
                                     moonImage: moonImage)
            painter.clouds = clouds.map { CloudFrames(previous: nil, current: $0, mix: 1) }
            painter.paint(&ctx)
        }
    }
}

/// Work that does not need redoing every frame: star positions (every 5 s) and the
/// low-resolution sky background (every 2 s of sky time, or when something changes).
@MainActor
final class SkyCaches {
    private var starsAt: Date = .distantPast
    private var stars: [VisibleStar] = []
    private var planets: [PlanetState] = []
    private var backgroundKey: (date: Date, size: CGSize, observer: Observer, weather: WeatherConditions)?
    private var backgroundImage: CGImage?
    private var fovKey: (day: Date, observer: Observer)?
    private var fov: Double = 140
    private var starsWeather: WeatherConditions?
    /// The sky background's pixels, for drops on the glass to refract.
    private(set) var backgroundPixels: (pixels: [UInt8], width: Int, height: Int)?

    // Clouds are rendered off the main thread about twice a second and cross-faded.
    private let epoch = Date.timeIntervalSinceReferenceDate
    private var cloudCurrent: CGImage?
    private var cloudPrevious: CGImage?
    private var cloudArrivedAt = 0.0
    private var cloudStartedAt = -100.0
    private var cloudRendering = false
    private var cloudKey: (size: CGSize, observer: Observer, weather: WeatherConditions)?
    static let cloudInterval = 0.5

    func clouds(scene: SkyScene, size: CGSize, fov: Double, now: TimeInterval) -> CloudFrames? {
        let changed = cloudKey.map { $0.size != size || $0.observer != scene.observer || $0.weather != scene.weather } ?? true
        if changed {
            cloudPrevious = nil // a new look: don't fade from clouds that no longer apply
        }
        if !cloudRendering, changed || now - cloudStartedAt >= Self.cloudInterval {
            cloudRendering = true
            cloudStartedAt = now
            cloudKey = (size, scene.observer, scene.weather)
            let projection = SkyBackground.projection(for: scene, size: size, fov: fov)
            let (w, h) = CloudFrames.resolution(for: size)
            let windTime = now - epoch
            Task.detached(priority: .userInitiated) { [weak self, scene] in
                let image = CloudRenderer().render(scene: scene, projection: projection, width: w, height: h, time: windTime)
                await self?.cloudsArrived(image)
            }
        }
        guard let cloudCurrent else { return nil }
        return CloudFrames(previous: cloudPrevious, current: cloudCurrent,
                           mix: min(1, (now - cloudArrivedAt) / Self.cloudInterval))
    }

    private func cloudsArrived(_ image: RGBAImage) {
        cloudRendering = false
        cloudPrevious = cloudCurrent
        cloudCurrent = image.cgImage
        cloudArrivedAt = Date.timeIntervalSinceReferenceDate
    }

    /// Field of view for the scene's day, recomputed once per local day or when the location changes.
    func fieldOfView(scene: SkyScene) -> Double {
        let day = Calendar.current.startOfDay(for: scene.date)
        if let k = fovKey, k.day == day, k.observer == scene.observer { return fov }
        fov = SkyProjection.seasonalFieldOfView(observer: scene.observer, date: scene.date)
        fovKey = (day, scene.observer)
        return fov
    }

    func scene(model: SkyModel, date: Date, weather: WeatherConditions) -> SkyScene {
        let builder = SkySceneBuilder(observer: model.observer, catalog: model.catalog)
        var scene = builder.scene(at: date, weather: weather, includeStars: false)
        if abs(date.timeIntervalSince(starsAt)) > 5 || weather != starsWeather {
            starsWeather = weather
            let full = builder.scene(at: date, weather: weather, includeStars: true)
            stars = full.stars
            planets = full.planets
            starsAt = date
        }
        scene.stars = stars
        scene.planets = planets
        return scene
    }

    private var moonKey: (phase: Double, sun: Double, north: Double, daylight: Double, pixels: Int)?
    private var moonCG: CGImage?

    /// The Moon disc changes slowly: re-render when its phase or orientation moves noticeably.
    func moonImage(scene: SkyScene, size: CGSize, fov: Double) -> CGImage? {
        guard let layout = MoonLayout(scene: scene, size: size, fov: fov) else { return nil }
        let key = (layout.phaseAngle, layout.sunAngle, layout.northAngle, layout.daylight, layout.pixels)
        if let k = moonKey, abs(k.phase - key.0) < 0.3, abs(k.sun - key.1) < 0.02, abs(k.north - key.2) < 0.02,
           abs(k.daylight - key.3) < 0.05, k.pixels == key.4, let img = moonCG {
            return img
        }
        moonCG = layout.render()
        moonKey = key
        return moonCG
    }

    func background(scene: SkyScene, size: CGSize, fov: Double) -> CGImage? {
        if let k = backgroundKey, abs(scene.date.timeIntervalSince(k.date)) < 2, k.size == size,
           k.observer == scene.observer, k.weather == scene.weather, let img = backgroundImage {
            return img
        }
        let (w, h) = SkyBackground.resolution
        let bytes = SkyBackground.pixels(scene: scene, size: size, fov: fov)
        backgroundImage = SkyBackground.image(pixels: bytes)
        backgroundPixels = (bytes, w, h)
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

    static func pixels(scene: SkyScene, size: CGSize, fov: Double) -> [UInt8] {
        let (w, h) = resolution
        return SkyGradientRenderer().render(scene: scene, projection: projection(for: scene, size: size, fov: fov),
                                            width: w, height: h)
    }

    static func image(scene: SkyScene, size: CGSize, fov: Double) -> CGImage? {
        image(pixels: pixels(scene: scene, size: size, fov: fov))
    }

    static func image(pixels bytes: [UInt8]) -> CGImage? {
        let (w, h) = resolution
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Where and how the Moon sits on screen, shared by the renderer and the painter.
struct MoonLayout {
    static let radiusFraction = 0.016 // of the screen width; larger than life so the surface reads
    let center: CGPoint
    let radius: Double
    let phaseAngle: Double
    /// Screen directions (atan2 with y down) of the Sun and of lunar (≈ celestial) north.
    let sunAngle: Double
    let northAngle: Double
    let daylight: Double
    let pixels: Int

    init?(scene: SkyScene, size: CGSize, fov: Double) {
        let m = scene.moon
        let pr = SkyBackground.projection(for: scene, size: size, fov: fov)
        guard m.horizontal.altitude > -1, let p = pr.point(m.horizontal) else { return nil }
        func raw(_ h: HorizontalCoordinates) -> CGPoint {
            let dAz = AstroMath.normalizeSigned(h.azimuth - pr.facingAzimuth)
            return CGPoint(x: (dAz / pr.horizontalFOV + 0.5) * size.width,
                           y: (1 - (h.altitude - pr.lowestAltitude) / (pr.highestAltitude - pr.lowestAltitude)) * size.height)
        }
        center = CGPoint(x: p.x, y: p.y)
        radius = size.width * Self.radiusFraction
        phaseAngle = m.phaseAngle
        let s = raw(scene.sun.horizontal)
        sunAngle = atan2(s.y - center.y, s.x - center.x)
        let jd = AstroMath.julianDay(scene.date)
        let n = raw(scene.observer.horizontal(rightAscension: m.rightAscension,
                                              declination: min(89.9, m.declination + 1), jd: jd))
        let m0 = raw(scene.observer.horizontal(rightAscension: m.rightAscension, declination: m.declination, jd: jd))
        northAngle = atan2(n.y - m0.y, n.x - m0.x)
        daylight = max(0, min(1, (scene.sun.horizontal.altitude + 4) / 10))
        pixels = max(16, Int(radius * 4)) // 2× for Retina
    }

    func render() -> CGImage? {
        guard let surface = MoonTexture.surface else { return nil }
        let img = MoonImageRenderer(surface: surface).render(
            size: pixels, phaseAngle: phaseAngle, sunAngle: sunAngle, northAngle: northAngle,
            earthshine: 0.06 * (1 - daylight), darkSideOpacity: 1 - daylight)
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: img.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The NASA LRO colour map, decoded once into RGBA.
enum MoonTexture {
    static let surface: RGBAImage? = {
        guard let url = MoonSurface.bundledMapURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? RGBAImage(width: w, height: h, pixels: pixels) : nil
    }()
}

struct SkyPainter {
    let scene: SkyScene
    let size: CGSize
    let time: TimeInterval
    let fov: Double
    let background: CGImage?
    /// The textured, phase-lit Moon disc, if the surface map loaded.
    var moonImage: CGImage? = nil
    /// The cloud and fog layer, cross-fading between renders.
    var clouds: CloudFrames? = nil
    /// Rain on the glass and lying snow for this screen (live view only).
    var effects: WeatherSnapshot? = nil
    /// Draw drops on the glass here (rather than on the overlay, or not at all).
    var glassOnDesktop = false
    var backgroundPixels: (pixels: [UInt8], width: Int, height: Int)? = nil

    var projection: SkyProjection { SkyBackground.projection(for: scene, size: size, fov: fov) }
    var overcast: Double {
        max(scene.weather.cloudLow, scene.weather.cloudMid * 0.8, scene.weather.cloudHigh * 0.4)
    }

    private func point(_ h: HorizontalCoordinates) -> CGPoint? {
        projection.point(h).map { CGPoint(x: $0.x, y: $0.y) }
    }

    func paint(_ ctx: inout GraphicsContext) {
        paintBackground(&ctx)
        paintStars(&ctx)
        paintPlanets(&ctx)
        paintSun(&ctx)
        paintMoon(&ctx)
        let flash = scene.weather.isThunderstorm ? Lightning.flash(at: time, activity: 0.6) : nil
        paintClouds(&ctx, flash: flash)
        paintLightning(&ctx, flash: flash)
        paintPrecipitation(&ctx)
        if let effects {
            paintGroundSnow(&ctx, snow: effects.snow)
            paintGroundSplashes(&ctx, effects: effects)
            if glassOnDesktop { paintGlass(&ctx, glass: effects.glass, refracting: true) }
        }
    }

    func color(_ c: SkyColor, _ opacity: Double = 1) -> Color {
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
        ctx.fill(Path(rect), with: .color(color(SkyColor(0.55 * dim, 0.58 * dim, 0.62 * dim), overcast * 0.45)))
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

    /// Planets: steady (no twinkle), slightly larger than stars of the same brightness,
    /// and showing earlier in twilight, so Venus can be the "evening star".
    private func paintPlanets(_ ctx: inout GraphicsContext) {
        let fade = min(1, scene.starVisibility * 1.8) * (1 - overcast)
        guard fade > 0.01 else { return }
        for pl in scene.planets where pl.horizontal.altitude > -0.5 {
            guard let p = point(pl.horizontal) else { continue }
            let radius = max(1.2, 3.4 - 0.45 * pl.magnitude)
            let c = pl.planet.color
            let glow = radius * 3
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [color(c, 0.35 * fade), color(c, 0)]),
                                           center: p, startRadius: 0, endRadius: glow))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(color(c, fade)))
        }
    }

    /// Screen position without the off-screen cut-off, used for directions (e.g. towards the Sun).
    private func unclampedPoint(_ h: HorizontalCoordinates) -> CGPoint {
        let pr = projection
        let dAz = AstroMath.normalizeSigned(h.azimuth - pr.facingAzimuth)
        return CGPoint(x: (dAz / pr.horizontalFOV + 0.5) * size.width,
                       y: (1 - (h.altitude - pr.lowestAltitude) / (pr.highestAltitude - pr.lowestAltitude)) * size.height)
    }

    /// The Moon with its real phase, the lit side turned towards the Sun, a faint earthshine
    /// on the dark side at night, and a halo when it is bright.
    private func paintMoon(_ ctx: inout GraphicsContext) {
        let m = scene.moon
        guard m.horizontal.altitude > -1, let p = point(m.horizontal) else { return }
        let r = size.width * MoonLayout.radiusFraction
        let k = m.illuminatedFraction
        let daylight = max(0, min(1, (scene.sun.horizontal.altitude + 4) / 10))
        let visible = (1 - overcast * 0.95) * (1 - 0.55 * daylight)
        guard visible > 0.02 else { return }
        let lowWarmth = max(0, min(1, 1 - m.horizontal.altitude / 10))
        let lit = SkyColor.mix(SkyColor(0.97, 0.96, 0.92), SkyColor(1.0, 0.80, 0.55), lowWarmth)

        let halo = r * 6
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                 with: .radialGradient(Gradient(colors: [color(lit, 0.28 * k * visible * (1 - daylight)), color(lit, 0)]),
                                       center: p, startRadius: r, endRadius: halo))
        if let moonImage {
            // Real surface, lit for the phase; reddened and dimmed near the horizon.
            var layer = ctx
            layer.opacity = visible
            layer.draw(Image(decorative: moonImage, scale: 1).interpolation(.high).resizable(),
                       in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if lowWarmth > 0.01 {
                layer.blendMode = .multiply
                layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                           with: .color(color(SkyColor(1, 0.78, 0.55), lowWarmth * 0.8)))
            }
            return
        }
        // Fallback without the surface map. Dark side: earthshine at night, sky colour by day.
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .color(color(SkyColor(0.30, 0.33, 0.40), 0.18 * visible * (1 - daylight))))

        // Lit part in Moon-centred coordinates with +x towards the Sun: the bright limb is a
        // semicircle, the terminator a half-ellipse whose width follows the phase.
        let s = unclampedPoint(scene.sun.horizontal)
        let angle = atan2(s.y - p.y, s.x - p.x)
        let e = r * (1 - 2 * k)
        var shape = Path()
        for deg in stride(from: -90.0, through: 90.0, by: 6) {
            let t = deg * .pi / 180
            let q = CGPoint(x: r * cos(t), y: r * sin(t))
            if deg == -90 { shape.move(to: q) } else { shape.addLine(to: q) }
        }
        for deg in stride(from: 90.0, through: -90.0, by: -6) {
            let t = deg * .pi / 180
            shape.addLine(to: CGPoint(x: e * cos(t), y: r * sin(t)))
        }
        shape.closeSubpath()
        let transform = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: angle)
        ctx.fill(shape.applying(transform), with: .color(color(lit, visible)))
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

    /// Deterministic pseudo-random number in [0, 1) for element `i`.
    func rand(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &* 73_856_093 ^ salt &* 19_349_663))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33; x &*= 0xc4ceb9fe1a85ec53; x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000
    }
}
#endif
