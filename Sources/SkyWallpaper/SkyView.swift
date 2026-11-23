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
                effects.advance(to: now, weather: weather, glass: model.glassMode != .off, snowSpeed: model.snowSpeed)
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
    /// How long each cross-fade lasts: the time the last render took to arrive, so the fade
    /// finishes as the next one lands instead of holding still and then jumping.
    private var cloudFade = 0.5
    private var cloudStartedAt = -100.0
    private var cloudRendering = false
    private var cloudKey: (size: CGSize, observer: Observer, weather: WeatherConditions)?
    static let cloudInterval = 0.5

    func clouds(scene: SkyScene, size: CGSize, fov: Double, now: TimeInterval) -> CloudFrames? {
        let changed = cloudKey.map { $0.size != size || $0.observer != scene.observer || $0.weather != scene.weather } ?? true
        if let key = cloudKey, key.size != size {
            cloudPrevious = nil // the old render no longer fits the screen
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
                           mix: min(1, (now - cloudArrivedAt) / cloudFade))
    }

    private func cloudsArrived(_ image: RGBAImage) {
        cloudRendering = false
        let arrived = Date.timeIntervalSinceReferenceDate
        if cloudCurrent != nil {
            cloudFade = max(Self.cloudInterval, min(3, arrived - cloudArrivedAt))
        }
        cloudPrevious = cloudCurrent
        cloudCurrent = image.cgImage
        cloudArrivedAt = arrived
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
        paintSunThroughCloud(&ctx)
        paintSunInFog(&ctx)
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

    /// Draws one point of light as the eye sees it: a tiny core, plus a soft glow that grows
    /// with brightness, added as light. Faint stars look white; only bright ones show colour.
    private func paintPointLight(_ ctx: inout GraphicsContext, at p: CGPoint, magnitude m: Double,
                                 color tint: SkyColor, opacity: Double, isPlanet: Bool = false) {
        let flux = pow(10, -0.4 * (m - 1)) // 1 for a first-magnitude star
        let root = min(4, flux.squareRoot())
        let saturation = min(1, 0.2 + 0.5 * root)
        let c = SkyColor.mix(SkyColor(1, 1, 1), tint, saturation)
        if flux > 0.12 {
            let glow = min(isPlanet ? 14 : 9, 2.2 + 3.2 * root)
            let a = opacity * min(0.55, 0.2 * root) * (isPlanet ? 1.3 : 1)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(stops: [
                         .init(color: color(c, a), location: 0),
                         .init(color: color(c, a * 0.35), location: 0.25),
                         .init(color: color(c, a * 0.08), location: 0.6),
                         .init(color: color(c, 0), location: 1),
                     ]), center: p, startRadius: 0, endRadius: glow))
        }
        let core = (isPlanet ? 0.9 : 0.5) + 0.35 * min(2.5, root)
        let alpha = opacity * min(1, 0.18 + 0.82 * root)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)),
                 with: .radialGradient(Gradient(colors: [color(SkyColor.mix(c, SkyColor(1, 1, 1), 0.5), alpha),
                                                         color(c, alpha * 0.6), color(c, 0)]),
                                       center: p, startRadius: 0, endRadius: core * 1.25))
    }

    /// Air near the horizon dims and reddens light: extra magnitudes of extinction.
    private func extinction(altitude: Double) -> Double {
        let h = max(0.5, altitude)
        return 0.22 * (1 / AstroMath.sind(h + 244 / (165 + 47 * pow(h, 1.1))) - 1) * 0.5
    }

    private func paintStars(_ ctx: inout GraphicsContext) {
        let fade = scene.starVisibility * (1 - overcast)
        guard fade > 0.01 else { return }
        var light = ctx
        light.blendMode = .plusLighter
        for s in scene.stars {
            guard let p = point(s.horizontal) else { continue }
            let alt = s.horizontal.altitude
            // Scintillation: stronger and faster low down, where we look through more air.
            let air = 1 - max(0, min(1, alt / 45))
            let seed = Double(s.star.hr)
            let flicker = sin(time * (4.1 + Double(s.star.hr % 7)) + seed) * sin(time * (2.3 + Double(s.star.hr % 5) * 0.7) + seed * 0.3)
            let twinkle = 0.25 + 0.55 * air
            let m = s.star.magnitude + extinction(altitude: alt) - twinkle * 0.6 * flicker
            let c = blackBodyColor(kelvin: s.star.temperature)
            paintPointLight(&light, at: p, magnitude: m, color: SkyColor(c.red, c.green, c.blue),
                            opacity: fade * smoothstep01((alt + 0.5) / 3))
        }
    }

    /// Planets: a steady light (no twinkle), a little larger than a star of the same brightness,
    /// and out earlier in twilight, so Venus can be the "evening star".
    private func paintPlanets(_ ctx: inout GraphicsContext) {
        let fade = min(1, scene.starVisibility * 1.8) * (1 - overcast)
        guard fade > 0.01 else { return }
        var light = ctx
        light.blendMode = .plusLighter
        for pl in scene.planets where pl.horizontal.altitude > -0.5 {
            guard let p = point(pl.horizontal) else { continue }
            let m = pl.magnitude + extinction(altitude: pl.horizontal.altitude)
            paintPointLight(&light, at: p, magnitude: m, color: pl.planet.color,
                            opacity: fade * smoothstep01((pl.horizontal.altitude + 0.5) / 3), isPlanet: true)
        }
    }

    private func smoothstep01(_ x: Double) -> Double {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
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

    /// The Sun's light colour, brightest channel 1: white overhead, orange near the horizon.
    var sunLight: SkyColor {
        let c = CloudRenderer.sunlightColor(altitude: scene.sun.horizontal.altitude)
        let m = max(c.r, c.g, c.b, 1e-6)
        return SkyColor(c.r / m, c.g / m, c.b / m)
    }

    /// The Sun as a camera or eye sees it: an over-exposed disc with a soft edge (no visible
    /// limb darkening), a tight glare and a wide faint aureole, all added as light so they
    /// brighten the sky rather than paint over it. Near the horizon it turns orange and
    /// refraction squashes it a little. Clouds are drawn on top and hide it as they thicken.
    private func paintSun(_ ctx: inout GraphicsContext) {
        guard let p = point(scene.sun.horizontal) else { return }
        let h = scene.sun.horizontal.altitude
        let light = sunLight

        // Twilight glow on the Sun's side of the sky, around sunrise and sunset.
        let twilight = 1 - max(0, min(1, (h - 2) / 8))
        let glowR = size.width * (0.12 + 0.18 * scene.sunGlow)
        if twilight > 0 {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [color(light, 0.35 * twilight), color(light, 0)]),
                                           center: p, startRadius: 0, endRadius: glowR))
        }
        let r = size.width * 0.007
        // The horizon line on screen. The disc sinks behind it at sunset and rises from it at
        // sunrise, dimming and reddening through the thick air low down, rather than switching.
        let horizonY = projection.point(HorizontalCoordinates(altitude: 0, azimuth: scene.sun.horizontal.azimuth))?.y ?? size.height
        guard p.y - r * 4 < horizonY else { return }
        let raw = CloudRenderer.sunlightColor(altitude: h)
        let brightness = max(0.3, min(1, raw.r)) * smoothstep01((h + 2.5) / 3)
        guard brightness > 0.005 else { return }
        let warmth = max(0, min(1, 1 - h / 15))
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.opacity = brightness * sunClarity
        glow.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY + r * 0.15)))

        // Aureole: exp(−d / 5r), out to 20 r.
        let aureole = r * 20
        glow.fill(Path(ellipseIn: CGRect(x: p.x - aureole, y: p.y - aureole, width: aureole * 2, height: aureole * 2)),
                  with: .radialGradient(Gradient(stops: [
                      .init(color: color(light, 0.35), location: 0),
                      .init(color: color(light, 0.13), location: 0.25),
                      .init(color: color(light, 0.05), location: 0.5),
                      .init(color: color(light, 0.017), location: 0.75),
                      .init(color: color(light, 0), location: 1),
                  ]), center: p, startRadius: 0, endRadius: aureole))
        // Glare: exp(−(d / 1.8r)²), out to 4 r; weaker for the low Sun so its disc stands out.
        let glare = r * 4, g = 0.6 - 0.3 * warmth
        glow.fill(Path(ellipseIn: CGRect(x: p.x - glare, y: p.y - glare, width: glare * 2, height: glare * 2)),
                  with: .radialGradient(Gradient(stops: [
                      .init(color: color(light, g), location: 0),
                      .init(color: color(light, g * 0.78), location: 0.225),
                      .init(color: color(light, g * 0.37), location: 0.45),
                      .init(color: color(light, g * 0.105), location: 0.675),
                      .init(color: color(light, g * 0.018), location: 0.9),
                      .init(color: color(light, 0), location: 1),
                  ]), center: p, startRadius: 0, endRadius: glare))
        // The disc: near white, tinted only when low, with a soft 8% edge.
        var core = SkyColor.mix(SkyColor(1, 1, 1), light, 0.5 * warmth)
        let m = max(core.r, core.g, core.b)
        core = SkyColor(core.r / m, core.g / m, core.b / m)
        let flat = 1 - 0.18 * max(0, min(1, (4 - h) / 4))
        let disc = CGRect(x: p.x - r, y: p.y - r * flat, width: r * 2, height: r * 2 * flat)
        glow.fill(Path(ellipseIn: disc), with: .radialGradient(Gradient(stops: [
            .init(color: color(core, 0.9), location: 0),
            .init(color: color(core, 0.9), location: 0.92),
            .init(color: color(core, 0), location: 1),
        ]), center: p, startRadius: 0, endRadius: r))
    }

    /// How thick the cloud deck is, 0 (none or broken) ... 1 (a dark rain or storm deck).
    var cloudThickness: Double {
        let w = scene.weather
        var t = smoothstep01((max(w.cloudLow, w.cloudMid * 0.8) - 0.6) / 0.4)
        if w.precipitation != .none { t += 0.3 }
        if w.isThunderstorm { t += 0.3 }
        return min(1, t)
    }

    /// 0 in clear air ... 1 in thick fog.
    var fogginess: Double {
        1 - smoothstep01(((scene.weather.visibility ?? 30_000) - 300) / 4_700)
    }

    /// How much of the Sun's glare gets through: none under a thick deck, little in fog.
    var sunClarity: Double {
        pow(1 - cloudThickness, 2) * (1 - 0.85 * fogginess)
    }

    /// In fog or mist the Sun is a pale white disc you can look straight at, with no glare,
    /// fading out as the fog thickens.
    func paintSunInFog(_ ctx: inout GraphicsContext) {
        let f = fogginess
        guard f > 0.05, let p = point(scene.sun.horizontal) else { return }
        let h = scene.sun.horizontal.altitude
        let vis = scene.weather.visibility ?? 30_000
        let alpha = f * (1 - cloudThickness) * smoothstep01((vis - 120) / 500) * smoothstep01((h + 0.5) / 4) * 0.75
        guard alpha > 0.01 else { return }
        let r = size.width * 0.007
        let tint = SkyColor.mix(SkyColor(1, 1, 0.97), sunLight, 0.6)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 5, y: p.y - r * 5, width: r * 10, height: r * 10)),
                 with: .radialGradient(Gradient(colors: [color(tint, alpha * 0.25), color(tint, 0)]),
                                       center: p, startRadius: r, endRadius: r * 5))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(stops: [
                     .init(color: color(tint, alpha), location: 0),
                     .init(color: color(tint, alpha), location: 0.85),
                     .init(color: color(tint, 0), location: 1),
                 ]), center: p, startRadius: 0, endRadius: r))
    }

    /// Behind cloud the Sun is a brighter, diffuse patch rather than a disc.
    func paintSunThroughCloud(_ ctx: inout GraphicsContext) {
        guard clouds != nil, overcast > 0.05, let p = point(scene.sun.horizontal) else { return }
        let h = scene.sun.horizontal.altitude
        guard h > -1 else { return }
        // Bright through thin or broken cloud; under a thick, rainy deck only a faint lighter patch.
        let strength = (0.28 * min(1, overcast * 1.5) * pow(1 - cloudThickness, 1.5) + 0.05 * cloudThickness)
            * max(0, min(1, (h + 1) / 4)) * (1 - 0.7 * fogginess)
        let reach = size.width * 0.007 * 14
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.fill(Path(ellipseIn: CGRect(x: p.x - reach, y: p.y - reach, width: reach * 2, height: reach * 2)),
                  with: .radialGradient(Gradient(stops: [
                      .init(color: color(sunLight, strength), location: 0),
                      .init(color: color(sunLight, strength * 0.4), location: 0.3),
                      .init(color: color(sunLight, 0), location: 1),
                  ]), center: p, startRadius: 0, endRadius: reach))
    }

    /// Deterministic pseudo-random number in [0, 1) for element `i`.
    func rand(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &* 73_856_093 ^ salt &* 19_349_663))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33; x &*= 0xc4ceb9fe1a85ec53; x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000
    }
}
#endif
