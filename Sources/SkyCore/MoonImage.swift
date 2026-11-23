import Foundation

/// An RGBA8 image in memory (top row first). Used for the Moon's surface map and the
/// rendered Moon disc, so SkyCore needs no platform image APIs.
public struct RGBAImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Bilinear sample at u, v in 0...1 (u wraps), returning linear-ish 0...1 RGB.
    func sample(u: Double, v: Double) -> (Double, Double, Double) {
        let x = (u - floor(u)) * Double(width) - 0.5
        let y = max(0, min(Double(height) - 1, v * Double(height) - 0.5))
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        func px(_ xi: Int, _ yi: Int) -> (Double, Double, Double) {
            let xx = ((xi % width) + width) % width, yy = max(0, min(height - 1, yi))
            let o = (yy * width + xx) * 4
            return (Double(pixels[o]) / 255, Double(pixels[o + 1]) / 255, Double(pixels[o + 2]) / 255)
        }
        let a = px(x0, y0), b = px(x0 + 1, y0), c = px(x0, y0 + 1), d = px(x0 + 1, y0 + 1)
        func lerp(_ p: Double, _ q: Double, _ t: Double) -> Double { p + (q - p) * t }
        return (lerp(lerp(a.0, b.0, fx), lerp(c.0, d.0, fx), fy),
                lerp(lerp(a.1, b.1, fx), lerp(c.1, d.1, fx), fy),
                lerp(lerp(a.2, b.2, fx), lerp(c.2, d.2, fx), fy))
    }
}

public enum MoonSurface {
    /// NASA LRO colour map bundled with SkyCore (public domain, NASA SVS 4720).
    public static var bundledMapURL: URL? { BundledResources.url(forResource: "moon", withExtension: "jpg") }
}

/// Renders the Moon as a lit sphere from an equirectangular surface map (longitude −180…180
/// left to right, the near side's centre in the middle; latitude +90 at the top), such as
/// NASA's LRO colour map. Lighting uses the Lommel–Seeliger law, which is why the real full
/// Moon looks flat rather than darkening towards the edge, with a soft terminator and
/// earthshine on the night side.
public struct MoonImageRenderer: Sendable {
    public let surface: RGBAImage

    public init(surface: RGBAImage) {
        self.surface = surface
    }

    /// - Parameters:
    ///   - size: output width and height in pixels.
    ///   - phaseAngle: Sun–Moon–Earth angle, degrees (0 = full, 180 = new).
    ///   - sunAngle: direction of the Sun on screen, radians, measured like `atan2(dy, dx)`
    ///     with y pointing down.
    ///   - northAngle: direction of lunar north on screen, same convention.
    ///   - earthshine: brightness of the unlit side relative to the lit side.
    ///   - darkSideOpacity: 1 at night (the dark limb hides the stars behind it); near 0 by day,
    ///     when the blue sky shows through the unlit part as it does in reality.
    /// - Returns: premultiplied RGBA, transparent outside the disc.
    public func render(size: Int, phaseAngle: Double, sunAngle: Double, northAngle: Double,
                       earthshine: Double = 0.05, darkSideOpacity: Double = 1) -> RGBAImage {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        let i = phaseAngle * AstroMath.deg2rad
        // View space: x right, y up, z towards the viewer. Screen angles have y down.
        let sun = (sin(i) * cos(sunAngle), -sin(i) * sin(sunAngle), cos(i))
        // Rotate screen coordinates so lunar north points up the map.
        let up = (cos(northAngle), -sin(northAngle))             // north in view x/y
        let right = (up.1, -up.0)                                 // east-west axis, 90° clockwise
        let half = Double(size) / 2

        for py in 0..<size {
            for px in 0..<size {
                let x = (Double(px) + 0.5 - half) / half
                let y = -(Double(py) + 0.5 - half) / half
                let rr = x * x + y * y
                // Anti-aliased edge over about one pixel.
                let edge = max(0, min(1, (1 - rr.squareRoot()) * half + 0.5))
                guard edge > 0 else { continue }
                let z = max(0, 1 - rr).squareRoot()

                // Lighting in view space.
                let mu0 = x * sun.0 + y * sun.1 + z * sun.2
                let mu = z
                let lit = mu0 > 0 ? 2 * mu0 / (mu0 + mu + 1e-6) : 0
                let terminator = smoothstep(-0.03, 0.06, mu0)
                let light = max(0, min(1.15, lit)) * terminator + earthshine * (1 - terminator)

                // Selenographic coordinates on the near side.
                let nx = x * right.0 + y * right.1    // towards lunar east... as seen, to the right
                let ny = x * up.0 + y * up.1          // towards lunar north
                let lat = asin(max(-1, min(1, ny)))
                let lon = atan2(nx, z)
                let tex = surface.sample(u: 0.5 + lon / (2 * .pi), v: 0.5 - lat / .pi)

                let a = edge * (darkSideOpacity + (1 - darkSideOpacity) * terminator)
                let o = (py * size + px) * 4
                out[o] = UInt8(max(0, min(255, tex.0 * light * 255 * a)))
                out[o + 1] = UInt8(max(0, min(255, tex.1 * light * 255 * a)))
                out[o + 2] = UInt8(max(0, min(255, tex.2 * light * 255 * a)))
                out[o + 3] = UInt8(max(0, min(255, 255 * a)))
            }
        }
        return RGBAImage(width: size, height: size, pixels: out)
    }
}
