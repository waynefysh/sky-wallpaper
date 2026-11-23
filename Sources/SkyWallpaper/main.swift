#if canImport(AppKit)
import AppKit

// Top-level code always runs on the main thread, so it is safe to assume main-actor isolation.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
#else
print("SkyWallpaper runs on macOS only. SkyCore and its tests build on any platform.")
#endif
