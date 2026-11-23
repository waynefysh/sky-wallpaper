#if canImport(AppKit)
import AppKit
import ApplicationServices
import SkyCore

/// A copy of one screen's weather state for drawing, so painting needs no main-actor access.
struct WeatherSnapshot: Sendable {
    var glass: GlassRain
    var snow: SnowCover
    var shelf: CGRect?
}

/// Rain on the glass and lying snow for one screen. The wallpaper and the overlay window both
/// draw from it; whichever draws first in a frame moves it on.
@MainActor
final class ScreenWeather {
    let size: CGSize
    private(set) var glass: GlassRain
    private(set) var snow: SnowCover
    /// The Dock's shelf on this screen, in points from the screen's top-left corner.
    private(set) var shelf: CGRect?
    private var last: TimeInterval?

    init(size: CGSize) {
        self.size = size
        glass = GlassRain(width: size.width, height: size.height)
        snow = SnowCover(width: size.width)
    }

    func advance(to time: TimeInterval, weather: WeatherConditions, glass glassOn: Bool) {
        defer { last = time }
        guard let last, time > last else { return }
        let dt = time - last
        let wind = -sin(weather.windDirection * .pi / 180) * min(1, weather.windSpeed / 15)
        if glassOn || !glass.drops.isEmpty {
            glass.step(dt: dt, intensity: glassOn ? GlassRain.intensity(for: weather) : 0, wind: wind)
        }
        snow.step(dt: dt, weather: weather)
    }

    func setShelf(_ rect: CGRect?) {
        guard rect != shelf else { return }
        shelf = rect
        if let rect {
            snow.setLedge(from: rect.minX, to: rect.maxX, height: size.height - rect.minY)
        } else {
            snow.clearLedge()
        }
    }

    var snapshot: WeatherSnapshot { WeatherSnapshot(glass: glass, snow: snow, shelf: shelf) }

    /// Whether there is anything to draw on the Dock or over the windows.
    var hasVisibleEffects: Bool { !glass.drops.isEmpty || snow.totalSnow > 0.5 }
}

@MainActor
final class WeatherEffectsStore {
    private var screens: [CGDirectDisplayID: ScreenWeather] = [:]

    func screen(_ id: CGDirectDisplayID, size: CGSize) -> ScreenWeather {
        if let s = screens[id], s.size == size { return s }
        let s = ScreenWeather(size: size)
        screens[id] = s
        return s
    }

    /// Finds the Dock and tells each screen where its shelf is (or that it has none).
    func updateDock(enabled: Bool) {
        let shelf = enabled ? DockLocator.shelfFrame() : nil
        for screen in NSScreen.screens {
            let fx = self.screen(screen.displayID, size: screen.frame.size)
            guard let shelf, screen.frame.intersects(shelf),
                  shelf.width > shelf.height,                       // only a Dock along the bottom
                  shelf.minY - screen.frame.minY < 40 else {
                fx.setShelf(nil)
                continue
            }
            // To this screen's top-left coordinates. The icon list's frame starts a few points
            // above the visible glass of the shelf, so snow settles that much lower.
            let inset = DockLocator.shelfInset
            fx.setShelf(CGRect(x: shelf.minX - screen.frame.minX,
                               y: screen.frame.maxY - shelf.maxY + inset,
                               width: shelf.width, height: max(0, shelf.height - inset)))
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Finds the Dock's shelf through the Accessibility API, which needs the user's permission
/// (System Settings > Privacy & Security > Accessibility). macOS has no other way to learn
/// how wide the Dock is; without permission the Dock effects stay off.
enum DockLocator {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Points between the top of the Dock's icon list and the top edge of its glass shelf.
    static let shelfInset = 4.0

    /// Shows the system prompt that leads to the Accessibility setting.
    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// True when the Dock hides itself, so there is no shelf to land on most of the time.
    static var autohides: Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false
    }

    /// The Dock's row of icons in global AppKit coordinates (origin bottom-left of the main screen).
    static func shelfFrame() -> CGRect? {
        guard isTrusted, !autohides,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == (kAXListRole as String) else { continue }
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posRef, let sizeRef,
                  CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
            else { continue }
            var origin = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            guard size.width > 0, size.height > 0 else { continue }
            // Accessibility uses top-left coordinates from the main screen.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: origin.x, y: mainHeight - origin.y - size.height, width: size.width, height: size.height)
        }
        return nil
    }
}
#endif
