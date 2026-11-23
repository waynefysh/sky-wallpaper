#if canImport(AppKit)
import Foundation
import ServiceManagement

/// Opens Sky when you log in, through macOS's login items (System Settings > General >
/// Login Items). Only works for the packaged app, not for `swift run`.
@MainActor
enum LaunchAtLogin {
    /// Whether this copy is a packaged app that macOS can open at login.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on or off. Returns a reason when macOS refuses, or nil on success.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        guard isAvailable else { return "Build the app with Scripts/package.sh to open it at login." }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if on, SMAppService.mainApp.status == .requiresApproval {
                return "Allow Sky in System Settings > General > Login Items."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
