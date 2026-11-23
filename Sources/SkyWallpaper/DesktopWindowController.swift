#if canImport(AppKit)
import AppKit
import SwiftUI

/// Puts one borderless window per screen at desktop level: above the system wallpaper,
/// below the desktop icons, on every Space, and ignoring the mouse.
@MainActor
final class DesktopWindowController {
    private let model: SkyModel
    private var windows: [NSWindow] = []

    init(model: SkyModel) {
        self.model = model
    }

    func showOnAllScreens() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map(makeWindow(for:))
        windows.forEach { $0.orderFront(nil) }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                         backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.hasShadow = false
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SkyView(screenID: screen.displayID).environmentObject(model))
        w.setFrame(screen.frame, display: true)
        return w
    }
}
#endif
