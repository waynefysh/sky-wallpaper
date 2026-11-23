import Foundation

/// Smooth 2D gradient noise (Perlin style) with fractal sums, for clouds and fog.
public struct GradientNoise: Sendable {
    public let seed: UInt32

    public init(seed: UInt32 = 1) {
        self.seed = seed
    }

    @inline(__always) private func gradient(_ ix: Int32, _ iy: Int32) -> (Double, Double) {
        var h = UInt32(bitPattern: ix) &* 0x8da6b343 ^ UInt32(bitPattern: iy) &* 0xd8163841 ^ seed &* 0xcb1ab31f
        h ^= h >> 13
        h &*= 0x5bd1e995
        h ^= h >> 15
        let a = Double(h & 0xffff) * (2 * Double.pi / 65_536)
        return (cos(a), sin(a))
    }

    /// Noise at (x, y), roughly −0.7...0.7 with mean 0.
    @inline(__always) public func noise(_ x: Double, _ y: Double) -> Double {
        let fx = floor(x), fy = floor(y)
        let ix = Int32(truncatingIfNeeded: Int(fx)), iy = Int32(truncatingIfNeeded: Int(fy))
        let dx = x - fx, dy = y - fy
        @inline(__always) func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
        let g00 = gradient(ix, iy), g10 = gradient(ix &+ 1, iy)
        let g01 = gradient(ix, iy &+ 1), g11 = gradient(ix &+ 1, iy &+ 1)
        let n00 = g00.0 * dx + g00.1 * dy
        let n10 = g10.0 * (dx - 1) + g10.1 * dy
        let n01 = g01.0 * dx + g01.1 * (dy - 1)
        let n11 = g11.0 * (dx - 1) + g11.1 * (dy - 1)
        let u = fade(dx), v = fade(dy)
        let a = n00 + (n10 - n00) * u, b = n01 + (n11 - n01) * u
        return a + (b - a) * v
    }

    /// Fractal sum of `octaves` layers, mapped to roughly 0...1 with mean 0.5.
    @inline(__always) public func fbm(_ x: Double, _ y: Double, octaves: Int) -> Double {
        var sum = 0.0, amp = 0.5, freq = 1.0, norm = 0.0
        var px = x, py = y
        for _ in 0..<octaves {
            sum += amp * noise(px * freq, py * freq)
            norm += amp
            amp *= 0.5
            freq *= 2.03
            // Rotate each octave a little so the lattice does not line up.
            (px, py) = (px * 0.8 - py * 0.6 + 1.7, px * 0.6 + py * 0.8 + 9.2)
        }
        return 0.5 + sum / norm * 1.1
    }
}

/// One deck of cloud at a fixed height above the ground.
public struct CloudLayer: Sendable {
    public enum Kind: Sendable { case cirrus, altocumulus, cumulus }
    public var kind: Kind
    /// Fraction of the sky this layer covers, 0...1.
    public var cover: Double
    /// Height of the cloud base, km.
    public var height: Double
    /// Size of a typical cloud, km.
    public var featureSize: Double
    /// How far the wind has carried the layer, km east and north.
    public var offset: (east: Double, north: Double)

    /// The noise threshold that leaves about `cover` of the layer at least half-dense. The
    /// warped noise is close to normal with mean 0.5 and spread 0.144, so this is its quantile
    /// (via the logistic approximation to the inverse normal), less half the soft edge.
    static func threshold(cover: Double, softness: Double) -> Double {
        let c = max(0.02, min(0.98, cover))
        return 0.5 + 0.144 * log((1 - c) / c) / 1.702 - 0.5 * softness
    }

    /// Cloud density 0...1 at a point in the layer's plane (km east and north of the observer).
    func density(_ noise: GradientNoise, east: Double, north: Double, octaves: Int = 5) -> Double {
        guard cover > 0.01 else { return 0 }
        var u = (east + offset.east) / featureSize
        var v = (north + offset.north) / featureSize
        if kind == .cirrus { // long streaks across the wind
            (u, v) = (u * 0.5, v * 1.4)
        }
        // A gentle domain warp makes the edges billow instead of looking like blobs.
        let wu = noise.noise(u * 0.45 + 3.1, v * 0.45 + 7.7)
        let wv = noise.noise(u * 0.45 + 11.4, v * 0.45 + 1.9)
        var n = noise.fbm(u + 0.9 * wu, v + 0.9 * wv, octaves: octaves)
        if kind == .cumulus { n += 0.08 * noise.noise(u * 4.1, v * 4.1) } // puffier tops
        let soft = kind == .cirrus ? 0.30 : 0.16
        let t = Self.threshold(cover: cover, softness: soft)
        var d = max(0, min(1, (n - t) / soft))
        if cover > 0.85 { d = min(1, d + (cover - 0.85) * 5) } // closes up to a solid overcast
        return d
    }
}

/// Renders the cloud decks and fog for a scene into a small premultiplied RGBA image that sits
/// over the sky. Each screen pixel is a ray: it meets each deck where the deck's plane (on a
/// curved Earth) crosses it, so clouds shrink and crowd towards the horizon as real ones do.
/// Clouds are lit by the Sun (or the Moon at night) with self-shadowing, a bright silver lining
/// towards the Sun, sunset colours from the Sun's path through the air, and pink high cloud
/// after the Sun has set at the ground, because high cloud still sees it.
public struct CloudRenderer: Sendable {
    public var noise = GradientNoise(seed: 7)

    public init() {}

    static let earthRadius = 6371.0

    /// The decks for the scene's weather, moved by the wind for `time` seconds.
    public static func layers(for weather: WeatherConditions, time: TimeInterval) -> [CloudLayer] {
        // Wind blows FROM windDirection; upper winds are faster than the 10 m wind.
        let toward = (weather.windDirection + 180) * AstroMath.deg2rad
        let base = max(1.5, weather.windSpeed)
        func drift(_ factor: Double) -> (Double, Double) {
            let km = base * factor * time / 1000
            return (-km * sin(toward), -km * cos(toward)) // noise offset moves against the clouds
        }
        return [
            CloudLayer(kind: .cirrus, cover: weather.cloudHigh, height: 9, featureSize: 9, offset: drift(4)),
            CloudLayer(kind: .altocumulus, cover: weather.cloudMid, height: 4, featureSize: 2.6, offset: drift(2.5)),
            CloudLayer(kind: .cumulus, cover: weather.cloudLow, height: 1.4, featureSize: 2.2, offset: drift(1.6)),
        ]
    }

    /// Distance along the ground (km) to where a ray at `altitude` degrees meets a deck `height` km up.
    static func groundDistance(altitude: Double, height: Double) -> Double {
        let r = earthRadius, s = AstroMath.sind(altitude), c = AstroMath.cosd(altitude)
        let slant = ((r + height) * (r + height) - r * r * c * c).squareRoot() - r * s
        return slant * c
    }

    /// Colour of sunlight after its path through the air at a given (apparent) altitude.
    static func sunlightColor(altitude: Double) -> SkyColor {
        let h = max(-1.5, altitude)
        let airmass = 1 / (AstroMath.sind(max(0.01, h + 1.6)) + 0.50572 * pow(h + 1.6 + 6.07995, -1.6364))
        let k = min(airmass, 40)
        return SkyColor(exp(-0.020 * k), exp(-0.055 * k), exp(-0.135 * k))
    }

    public func render(scene: SkyScene, projection: SkyProjection, width: Int, height: Int,
                       time: TimeInterval) -> RGBAImage {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let w = scene.weather
        let layers = Self.layers(for: w, time: time).filter { $0.cover > 0.01 }
        let visibility = w.visibility ?? 30_000
        let fogOn = visibility < 8_000
        guard !layers.isEmpty || fogOn else { return RGBAImage(width: width, height: height, pixels: out) }

        let sunAlt = scene.sun.horizontal.altitude
        // Light source: the Sun, or the Moon once the Sun is well down.
        let moonUp = scene.moon.horizontal.altitude > 0
        let useMoon = sunAlt < -7 && moonUp
        let lightDir = useMoon ? scene.moon.horizontal : scene.sun.horizontal
        let lightAz = lightDir.azimuth * AstroMath.deg2rad
        let lightH = (sin(lightAz), cos(lightAz)) // east, north
        let moonStrength = useMoon ? 0.10 * scene.moon.illuminatedFraction : 0
        let lightVec = unit(altitude: lightDir.altitude, azimuth: lightDir.azimuth)

        // Ambient light from the sky: bright and bluish by day, dark at night, with a
        // little orange from town lights under low cloud.
        let day = smoothstep(-8, 10, sunAlt)
        let skyAmb = SkyColor.mix(scene.zenithColor, scene.horizonColor, 0.5)
        let urban = SkyColor(0.12, 0.085, 0.06) * (1 - day)
        let overcastDim = 1 - 0.45 * w.cloudLow * w.cloudMid // stacked decks shade the lower ones

        let sx = projection.width / Double(width), sy = projection.height / Double(height)
        let pixelAngle = (projection.highestAltitude - projection.lowestAltitude) / Double(height) * AstroMath.deg2rad
        let fogHeight = visibility < 1_000 ? 0.12 : 0.8 // km: ground fog or a deeper mist
        let fogTint = SkyColor.mix(SkyColor(0.04, 0.045, 0.055) + urban * 1.5,
                                   SkyColor(0.78, 0.80, 0.82) * (0.55 + 0.45 * smoothstep(0, 30, sunAlt)), day)
        let sunCol = Self.sunlightColor(altitude: sunAlt)
        let fogSun = sunCol * (0.35 * smoothstep(-2, 6, sunAlt))

        for j in 0..<height {
            for i in 0..<width {
                let dir = projection.direction(x: (Double(i) + 0.5) * sx, y: (Double(j) + 0.5) * sy)
                let az = dir.azimuth * AstroMath.deg2rad
                let view = unit(altitude: max(dir.altitude, 0), azimuth: dir.azimuth)
                let cosToLight = view.0 * lightVec.0 + view.1 * lightVec.1 + view.2 * lightVec.2
                var acc = SkyColor(0, 0, 0)  // premultiplied
                var alpha = 0.0

                if dir.altitude > 0.15 {
                    // Back to front: high, mid, low. Each nearer deck is composited over.
                    for layer in layers {
                        let d = Self.groundDistance(altitude: dir.altitude, height: layer.height)
                        let east = d * sin(az), north = d * cos(az)
                        // Far away, many clouds share one pixel: fade to their average density
                        // instead of aliasing into speckle near the horizon.
                        let footprint = d * pixelAngle / max(0.02, AstroMath.sind(max(dir.altitude, 0.15)))
                        let lod = smoothstep(0.15, 0.8, footprint / layer.featureSize)
                        let meanDensity = min(1, layer.cover * 0.75)
                        var dens = lod > 0.99 ? meanDensity
                            : layer.density(noise, east: east, north: north, octaves: d > 60 ? 3 : 5)
                        dens += (meanDensity - dens) * lod
                        guard dens > 0.005 else { continue }

                        // The Sun as seen from the cloud: it sets later up there.
                        let dip = acos(Self.earthRadius / (Self.earthRadius + layer.height)) * AstroMath.rad2deg
                        let sunHere = sunAlt + dip
                        let sunlit = useMoon ? moonStrength : smoothstep(-0.8, 1.0, sunHere)
                        let lightCol = useMoon ? SkyColor(0.75, 0.80, 0.95) : Self.sunlightColor(altitude: sunHere)

                        // Self-shadowing: how much cloud the light passes through on its way in.
                        let lowLight = 1 + 2.5 * (1 - max(0, AstroMath.sind(max(0, lightDir.altitude + dip))))
                        let step = 0.12 * layer.featureSize * lowLight
                        var s1 = meanDensity, s2 = meanDensity
                        if lod < 0.99 {
                            s1 = layer.density(noise, east: east + lightH.0 * step, north: north + lightH.1 * step, octaves: 3)
                            s2 = layer.density(noise, east: east + lightH.0 * step * 2.4, north: north + lightH.1 * step * 2.4, octaves: 2)
                            s1 += (meanDensity - s1) * lod
                            s2 += (meanDensity - s2) * lod
                        }
                        let thick: Double = layer.kind == .cirrus ? 0.4 : (layer.kind == .cumulus ? 1.0 : 0.8)
                        let transmit = exp(-thick * (1.2 * s1 + 0.8 * s2 + 0.6 * dens))
                        // Forward scattering: edges facing the light glow (the silver lining).
                        let silver = pow(max(0, cosToLight), 8) * (1.6 - dens) * 1.1
                        let direct = sunlit * (0.25 + 0.95 * transmit) * (0.85 + silver)

                        let bottomShade = 1 - 0.35 * dens * thick * (layer.kind == .cumulus ? 1 : 0.4)
                        let amb = (skyAmb * (0.75 + 0.25 * day) + SkyColor(0.12, 0.12, 0.13) * day + urban * (layer.kind == .cumulus ? 1.5 : 0.6))
                            * (bottomShade * overcastDim)
                        var c = lightCol * (direct * (layer.kind == .cirrus ? 0.85 : 0.72)) + amb * 0.8

                        // Aerial perspective: distant cloud fades into the horizon haze.
                        let haze = 1 - exp(-d / max(8, visibility / 1000 * 2.2))
                        c = SkyColor.mix(c, scene.horizonColor, 0.65 * haze)
                        let opacity = (layer.kind == .cirrus ? 0.75 : 1) * (1 - exp(-3.2 * dens)) * (1 - 0.35 * haze)
                            * smoothstep(0.15, 1.2, dir.altitude)
                        acc = c * opacity + acc * (1 - opacity)
                        alpha = opacity + alpha * (1 - opacity)
                    }
                }

                if fogOn {
                    // Path through a fog layer of fogHeight km; banks drift with the wind.
                    let sinAlt = AstroMath.sind(max(dir.altitude, 0.3))
                    var path = dir.altitude < 0 ? 40 : min(40, fogHeight / sinAlt)
                    let fx = (dir.azimuth / 9) + time * max(0.3, w.windSpeed) * 0.002
                    let fy = max(dir.altitude, -4) / 6
                    path *= 0.6 + 0.8 * noise.fbm(fx, fy + 30, octaves: 3)
                    let f = min(0.96, 1 - exp(-3.912 * path / (visibility / 1000)))
                    if f > 0.003 {
                        let glow = pow(max(0, cosToLight), 12) * (useMoon ? 0 : 1)
                        let c = fogTint + fogSun * glow
                        acc = c * f + acc * (1 - f)
                        alpha = f + alpha * (1 - f)
                    }
                }

                let o = (j * width + i) * 4
                out[o] = UInt8(max(0, min(255, acc.r * 255)))
                out[o + 1] = UInt8(max(0, min(255, acc.g * 255)))
                out[o + 2] = UInt8(max(0, min(255, acc.b * 255)))
                out[o + 3] = UInt8(max(0, min(255, alpha * 255)))
            }
        }
        return RGBAImage(width: width, height: height, pixels: out)
    }

    @inline(__always) private func unit(altitude: Double, azimuth: Double) -> (Double, Double, Double) {
        let ca = AstroMath.cosd(altitude)
        return (ca * AstroMath.sind(azimuth), ca * AstroMath.cosd(azimuth), AstroMath.sind(altitude))
    }
}

extension SkyColor {
    static func * (c: SkyColor, k: Double) -> SkyColor { SkyColor(c.r * k, c.g * k, c.b * k) }
    static func + (a: SkyColor, b: SkyColor) -> SkyColor { SkyColor(a.r + b.r, a.g + b.g, a.b + b.b) }
}
