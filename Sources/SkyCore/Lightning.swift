import Foundation

/// Lightning timing and bolt shapes. Everything is derived from the clock and a seed, so every
/// screen shows the same strike at the same moment without sharing any state.
public enum Lightning {
    /// One flash in progress.
    public struct Flash: Sendable, Equatable {
        /// Brightness of the flash right now, 0...1.
        public var intensity: Double
        /// Seed for the bolt's shape and position.
        public var seed: UInt64
        /// Cloud-to-ground strikes show a bolt; the rest light up the cloud from inside.
        public var isGroundStrike: Bool
        /// Horizontal position of the strike, 0...1 across the screen.
        public var x: Double
    }

    /// Seconds in each slot; at most one flash starts per slot.
    static let slot = 2.5

    /// The flash lighting the sky at `time` (seconds), or nil between flashes.
    /// - Parameter activity: storm strength 0...1 (0.6 gives a flash about every 8 s).
    public static func flash(at time: TimeInterval, activity: Double = 0.6) -> Flash? {
        let index = Int64((time / slot).rounded(.down))
        var rng = SplitMix(seed: UInt64(bitPattern: index) &* 0x2545f4914f6cdd1d &+ 17)
        guard rng.unit() < 0.15 + 0.35 * activity else { return nil }
        let start = Double(index) * slot + rng.unit() * (slot - 1)
        let t = time - start
        guard t >= 0, t < 0.9 else { return nil }
        // A lightning flash is several return strokes: bright peaks a few tens of ms apart,
        // each fading fast, with a dimmer flicker after.
        let strokes = 2 + Int(rng.unit() * 3)
        var level = 0.0
        var at = 0.0
        for k in 0..<strokes {
            let peak = k == 0 ? 1 : 0.5 + 0.4 * rng.unit()
            let dt = t - at
            if dt >= 0 { level = max(level, peak * exp(-dt / 0.045)) }
            at += 0.06 + 0.12 * rng.unit()
        }
        guard level > 0.02 else { return nil }
        let seed = rng.next()
        return Flash(intensity: min(1, level), seed: seed, isGroundStrike: rng.unit() < 0.35, x: 0.1 + 0.8 * rng.unit())
    }

    /// A line segment of a bolt in unit coordinates (x across, y down), with a relative width.
    public struct Segment: Sendable {
        public var x0: Double, y0: Double, x1: Double, y1: Double
        public var width: Double
    }

    /// A jagged bolt from the cloud base at (x, top) down to `bottom`, with forks.
    public static func bolt(seed: UInt64, x: Double, top: Double, bottom: Double) -> [Segment] {
        var rng = SplitMix(seed: seed)
        var segments: [Segment] = []
        func walk(_ x0: Double, _ y0: Double, length: Double, width: Double, depth: Int, rng: inout SplitMix) {
            var x = x0, y = y0
            var lean = (rng.unit() - 0.5) * 0.4
            var steps = 0
            while y < y0 + length, steps < 400 {
                steps += 1
                let ny = y + 0.012 + 0.012 * rng.unit()
                lean = max(-0.8, min(0.8, lean * 0.7 + (rng.unit() - 0.5) * 0.9))
                let nx = x + lean * (ny - y) * 1.6
                segments.append(Segment(x0: x, y0: y, x1: nx, y1: ny, width: width))
                x = nx
                y = ny
                if depth < 2, rng.unit() < 0.07 {
                    walk(x, y, length: length * (0.15 + 0.25 * rng.unit()), width: width * 0.45, depth: depth + 1, rng: &rng)
                }
            }
        }
        walk(x, top, length: bottom - top, width: 1, depth: 0, rng: &rng)
        return segments
    }
}
