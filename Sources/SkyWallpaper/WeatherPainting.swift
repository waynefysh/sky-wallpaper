#if canImport(AppKit)
import SwiftUI
import SkyCore

/// The cloud and fog layer: the latest render fading in over the one before.
struct CloudFrames {
    var previous: CGImage?
    var current: CGImage
    var mix: Double

    /// Cloud render size: 320 pixels across, matching the screen's shape.
    static func resolution(for size: CGSize) -> (Int, Int) {
        let w = 320
        return (w, max(40, Int(Double(w) * size.height / max(1, size.width))))
    }
}

extension RGBAImage {
    /// A premultiplied sRGB CGImage of the pixels.
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Weather drawing that both the wallpaper and the overlay windows use.
struct WeatherLook {
    let scene: SkyScene

    /// 0 at night ... 1 in full daylight.
    var daylight: Double { max(0, min(1, (scene.sun.horizontal.altitude + 6) / 16)) }

    /// Snow takes on the light around it: white by day, blue-grey at night.
    var snowColor: SkyColor {
        let d = daylight
        let overcast = max(scene.weather.cloudLow, scene.weather.cloudMid * 0.8)
        let day = SkyColor(0.93 - 0.08 * overcast, 0.95 - 0.07 * overcast, 0.98 - 0.04 * overcast)
        let night = SkyColor(0.20, 0.23, 0.30)
        return SkyColor.mix(night, day, d)
    }

    /// Rain intensity 0...1 for drawing streaks and splashes.
    var rain: Double { GlassRain.intensity(for: scene.weather) }

    static func color(_ c: SkyColor, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: max(0, min(1, c.r)), green: max(0, min(1, c.g)), blue: max(0, min(1, c.b)), opacity: opacity)
    }

    static func hash(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &* 73_856_093 ^ salt &* 19_349_663))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33; x &*= 0xc4ceb9fe1a85ec53; x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000
    }

    /// Snow lying on columns of `snow`, drawn as a filled drift. `onLedge` picks the snow on
    /// the Dock's shelf; otherwise the snow on the ground. `offset` moves from screen points
    /// (origin top left) to the drawing context.
    func paintSnow(_ ctx: inout GraphicsContext, snow: SnowCover, screenHeight: Double,
                   onLedge: Bool, offset: CGPoint = .zero) {
        guard snow.totalSnow > 0.5 else { return }
        let c = snowColor
        var path = Path()
        var open = false
        var lastX = 0.0
        for i in 0..<snow.columnCount {
            let isLedge = snow.floor[i] > 0
            let x = (Double(i) + 0.5) * snow.columnWidth - offset.x
            guard isLedge == onLedge, snow.depth[i] > 0.05 else {
                if open {
                    path.addLine(to: CGPoint(x: lastX + snow.columnWidth / 2, y: screenHeight - snow.floor[max(0, i - 1)] - offset.y))
                    path.closeSubpath()
                    open = false
                }
                continue
            }
            let base = screenHeight - snow.floor[i] - offset.y
            let top = base - snow.depth[i]
            if !open {
                path.move(to: CGPoint(x: x - snow.columnWidth / 2, y: base))
                path.addLine(to: CGPoint(x: x - snow.columnWidth / 2, y: top))
                open = true
            }
            path.addLine(to: CGPoint(x: x, y: top))
            lastX = x
        }
        if open {
            path.addLine(to: CGPoint(x: lastX + snow.columnWidth / 2, y: screenHeight - snow.floor[snow.columnCount - 1] - offset.y))
            path.closeSubpath()
        }
        // A soft blue shadow under a bright crust, like fresh snow.
        let shade = SkyColor(c.r * 0.78, c.g * 0.84, c.b * 0.95)
        let bounds = path.boundingRect
        ctx.fill(path, with: .linearGradient(Gradient(colors: [Self.color(c), Self.color(shade)]),
                                             startPoint: CGPoint(x: 0, y: bounds.minY),
                                             endPoint: CGPoint(x: 0, y: bounds.maxY)))
        ctx.stroke(path, with: .color(Self.color(SkyColor(1, 1, 1), 0.25 * daylight + 0.1)), lineWidth: 0.8)
    }

    /// Raindrops splashing on a surface: little crowns of droplets and a ripple, at random
    /// spots along `from...to`, with the surface height given by `surfaceY`.
    func paintSplashes(_ ctx: inout GraphicsContext, time: TimeInterval, from: Double, to: Double,
                       salt: Int, surfaceY: (Double) -> Double) {
        let intensity = rain
        guard intensity > 0.01, to > from else { return }
        let emitters = Int((to - from) / 40 * (0.3 + intensity * 1.7))
        let c = Self.color(SkyColor.mix(SkyColor(0.55, 0.6, 0.7), SkyColor(0.95, 0.97, 1), daylight))
        for k in 0..<emitters {
            let period = 0.35 + 0.6 * Self.hash(k, salt)
            let shifted = time + period * Self.hash(k, salt + 1)
            let cycle = Int((shifted / period).rounded(.down))
            let t = shifted - Double(cycle) * period
            let life = 0.28
            guard t < life else { continue }
            let p = t / life
            let x = from + Self.hash(k &* 7919 &+ cycle, salt + 2) * (to - from)
            let y = surfaceY(x)
            let fade = 1 - p
            // Ripple.
            let rw = 2 + 7 * p
            ctx.stroke(Path(ellipseIn: CGRect(x: x - rw, y: y - rw * 0.18, width: rw * 2, height: rw * 0.36)),
                       with: .color(c.opacity(0.35 * fade)), lineWidth: 0.6)
            // Crown: a few droplets thrown up and out, falling back under gravity.
            let drops = 3 + Int(Self.hash(k &+ cycle, salt + 3) * 3)
            for d in 0..<drops {
                let a = (Double(d) / Double(drops - 1) - 0.5) * 2.2 + (Self.hash(k &+ d, cycle &+ salt) - 0.5) * 0.3
                let speed = 30 + 40 * Self.hash(d &+ cycle, k &+ salt)
                let dx = sin(a) * speed * t
                let dy = -cos(a) * speed * 1.4 * t + 0.5 * 600 * t * t
                guard dy < 1 else { continue }
                let r = 0.7 + 0.5 * Self.hash(d, k)
                ctx.fill(Path(ellipseIn: CGRect(x: x + dx - r, y: y + dy - r, width: r * 2, height: r * 2)),
                         with: .color(c.opacity(0.75 * fade)))
            }
        }
    }

    /// Water drops on the glass. With `sample`, each drop shows the sky behind it upside down,
    /// as a real drop does (it is a tiny lens); without it, a neutral drop that reads on any app.
    func paintGlass(_ ctx: inout GraphicsContext, glass: GlassRain, offset: CGPoint = .zero,
                    sample: ((Double, Double) -> SkyColor)?) {
        let light = 0.35 + 0.65 * daylight
        for d in glass.drops {
            let x = d.x - offset.x, y = d.y - offset.y, r = d.radius
            // Sliding drops stretch a little and lean their weight to the bottom.
            let stretch = d.isSliding ? 1 + min(0.5, d.speed / 160) : 1
            let rect = CGRect(x: x - r, y: y - r * stretch + r * (stretch - 1) * 0.6, width: r * 2, height: r * 2 * stretch)
            let shape = Path(ellipseIn: rect)
            if r < 1.1 {
                if let sample {
                    let c = sample(x, y + 8 * r)
                    ctx.fill(shape, with: .color(Self.color(SkyColor(c.r * 0.8, c.g * 0.8, c.b * 0.85), 0.7)))
                } else {
                    ctx.fill(shape, with: .color(.white.opacity(0.16 * light)))
                }
                continue
            }
            if let sample {
                // Upside down: the top of the drop shows what is below it, the bottom the sky above.
                let top = sample(x, y + 10 * r), bottom = sample(x, y - 10 * r)
                ctx.fill(shape, with: .linearGradient(
                    Gradient(colors: [Self.color(SkyColor(top.r * 0.75, top.g * 0.75, top.b * 0.8)),
                                      Self.color(SkyColor(bottom.r * 1.15 + 0.05, bottom.g * 1.15 + 0.05, bottom.b * 1.1 + 0.05))]),
                    startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: rect.maxY)))
            } else {
                ctx.fill(shape, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.04), .white.opacity(0.20 * light)]),
                    startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: rect.maxY)))
            }
            // A darker rim where light bends away, and a bright glint.
            ctx.stroke(shape, with: .color(.black.opacity(sample == nil ? 0.22 : 0.28)), lineWidth: max(0.5, r * 0.18))
            let g = r * 0.32
            ctx.fill(Path(ellipseIn: CGRect(x: x - r * 0.42 - g / 2, y: rect.minY + r * 0.35 - g / 2, width: g, height: g * 0.8)),
                     with: .color(.white.opacity(0.75 * light)))
            // A caustic: light focused through the drop onto the glass just below it.
            ctx.fill(Path(ellipseIn: CGRect(x: x - r * 0.5, y: rect.maxY - r * 0.45, width: r, height: r * 0.35)),
                     with: .color(.white.opacity(0.22 * light)))
        }
    }
}

extension SkyPainter {
    private var look: WeatherLook { WeatherLook(scene: scene) }

    /// Clouds and fog, with lightning lighting the cloud from inside.
    func paintClouds(_ ctx: inout GraphicsContext, flash: Lightning.Flash?) {
        guard let clouds else { return }
        let rect = CGRect(origin: .zero, size: size)
        ctx.drawLayer { layer in
            // A true cross-fade: (1 − mix) of the old render plus mix of the new one, added
            // together. Drawing the new one over the old instead would stack the semi-transparent
            // parts (thin cloud, fog) and make them pulse brighter every time a render arrives.
            let mix = clouds.previous == nil ? 1 : max(0, min(1, clouds.mix))
            if let previous = clouds.previous, mix < 1 {
                var old = layer
                old.opacity = 1 - mix
                old.draw(Image(decorative: previous, scale: 1).interpolation(.high).resizable(), in: rect)
            }
            var new = layer
            new.opacity = mix
            new.blendMode = .plusLighter
            new.draw(Image(decorative: clouds.current, scale: 1).interpolation(.high).resizable(), in: rect)
            if let flash {
                // Only where there is cloud: the flash glows through it.
                layer.blendMode = .sourceAtop
                let centre = CGPoint(x: flash.x * size.width, y: size.height * 0.3)
                let reach = size.width * (flash.isGroundStrike ? 0.35 : 0.25)
                layer.fill(Path(rect), with: .radialGradient(
                    Gradient(colors: [Color(.sRGB, red: 0.85, green: 0.88, blue: 1, opacity: 0.9 * flash.intensity),
                                      Color(.sRGB, red: 0.75, green: 0.8, blue: 1, opacity: 0.25 * flash.intensity),
                                      .clear]),
                    center: centre, startRadius: 0, endRadius: reach))
            }
        }
    }

    /// A cloud-to-ground bolt, and the whole sky brightening with each stroke.
    func paintLightning(_ ctx: inout GraphicsContext, flash: Lightning.Flash?) {
        guard let flash else { return }
        let rect = CGRect(origin: .zero, size: size)
        var sky = ctx
        sky.blendMode = .plusLighter
        sky.fill(Path(rect), with: .color(Color(.sRGB, red: 0.6, green: 0.65, blue: 0.8, opacity: 0.18 * flash.intensity)))
        guard flash.isGroundStrike, flash.intensity > 0.08 else { return }
        let horizon = projection.point(HorizontalCoordinates(altitude: 0, azimuth: projection.facingAzimuth))?.y ?? size.height * 0.94
        let segments = Lightning.bolt(seed: flash.seed, x: flash.x, top: 0.22, bottom: horizon / size.height)
        var core = Path(), glow = Path()
        for s in segments {
            let a = CGPoint(x: s.x0 * size.width, y: s.y0 * size.height)
            let b = CGPoint(x: s.x1 * size.width, y: s.y1 * size.height)
            if s.width > 0.9 { core.move(to: a); core.addLine(to: b) }
            glow.move(to: a); glow.addLine(to: b)
        }
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 6))
            l.stroke(glow, with: .color(Color(.sRGB, red: 0.7, green: 0.75, blue: 1, opacity: 0.8 * flash.intensity)), lineWidth: 6)
        }
        ctx.stroke(glow, with: .color(.white.opacity(0.6 * flash.intensity)), lineWidth: 1)
        ctx.stroke(core, with: .color(.white.opacity(flash.intensity)), lineWidth: 2.2)
    }

    /// Falling rain or snow, in two depths: faint and slow far away, larger and faster near.
    func paintPrecipitation(_ ctx: inout GraphicsContext) {
        let w = scene.weather
        guard w.precipitation != .none else { return }
        let isSnow = w.precipitation == .snow
        let slant = -sin(w.windDirection * .pi / 180) * min(0.6, w.windSpeed / 18)
        let light = 0.35 + 0.65 * look.daylight
        let total = Int(min(900, 80 + w.precipitationRate * 140))
        for i in 0..<total {
            let near = rand(i, 49) < 0.3
            let speed = (isSnow ? 0.06 : 1.1) * (near ? 1.6 : 0.8) * (0.8 + 0.4 * rand(i, 50)) // screen heights per second
            let y = (rand(i, 51) + time * speed).truncatingRemainder(dividingBy: 1.0)
            var x = rand(i, 52) + slant * y
            x -= x.rounded(.down)
            if isSnow { x += (near ? 0.012 : 0.006) * sin(time * (0.8 + rand(i, 54)) + Double(i)) }
            let p = CGPoint(x: x * size.width, y: y * size.height)
            if isSnow {
                let r = (near ? 2.2 : 1.0) + 1.6 * rand(i, 53)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity((near ? 0.85 : 0.55) * (0.5 + 0.5 * light))))
            } else {
                var path = Path()
                let len = size.height * (near ? 0.04 : 0.02)
                path.move(to: p)
                path.addLine(to: CGPoint(x: p.x - slant * len, y: p.y - len))
                ctx.stroke(path, with: .color(.white.opacity((near ? 0.32 : 0.18) * light)), lineWidth: near ? 1.2 : 0.7)
            }
        }
    }

    func paintGroundSnow(_ ctx: inout GraphicsContext, snow: SnowCover) {
        look.paintSnow(&ctx, snow: snow, screenHeight: size.height, onLedge: false)
    }

    /// Splashes along the bottom of the screen, on top of any snow, except under the Dock.
    func paintGroundSplashes(_ ctx: inout GraphicsContext, effects: WeatherSnapshot) {
        let snow = effects.snow
        let h = size.height
        let segments: [(Double, Double)]
        if let shelf = effects.shelf {
            segments = [(0, shelf.minX), (shelf.maxX, size.width)]
        } else {
            segments = [(0, size.width)]
        }
        for (k, seg) in segments.enumerated() {
            look.paintSplashes(&ctx, time: time, from: seg.0, to: seg.1, salt: 300 + k * 10) { x in
                h - snow.surface(atX: x)
            }
        }
    }

    func paintGlass(_ ctx: inout GraphicsContext, glass: GlassRain, refracting: Bool) {
        guard !glass.drops.isEmpty else { return }
        let sampler: ((Double, Double) -> SkyColor)? = refracting ? { x, y in sampleSky(x: x, y: y) } : nil
        look.paintGlass(&ctx, glass: glass, sample: sampler)
    }

    /// The sky colour behind a screen point, from the low-resolution background, greyed by cloud.
    private func sampleSky(x: Double, y: Double) -> SkyColor {
        guard let bg = backgroundPixels else { return scene.horizonColor }
        let i = max(0, min(bg.width - 1, Int(x / size.width * Double(bg.width))))
        let j = max(0, min(bg.height - 1, Int(y / size.height * Double(bg.height))))
        let o = (j * bg.width + i) * 4
        let c = SkyColor(Double(bg.pixels[o]) / 255, Double(bg.pixels[o + 1]) / 255, Double(bg.pixels[o + 2]) / 255)
        let grey = look.daylight * 0.6 + 0.08
        return SkyColor.mix(c, SkyColor(grey, grey, grey * 1.04), overcast * 0.8)
    }
}
#endif
