import AppKit
import PermissionFlow
import PermissionFlowInputMonitoringStatus
import SwiftUI

@main
struct NotchFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchWindow: NotchWindowController?
    private var permissionsWindow: PermissionsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PermissionFlowInputMonitoringStatus.register()
        NSApp.setActivationPolicy(.accessory)
        notchWindow = NotchWindowController()
        notchWindow?.showWindow(nil)

        let accessibility = PermissionStatusRegistry
            .provider(for: .accessibility)
            .authorizationState()
        let inputMonitoring = PermissionStatusRegistry
            .provider(for: .inputMonitoring)
            .authorizationState()
        guard accessibility != .granted || inputMonitoring != .granted else { return }

        let permissionsWindow = PermissionsWindowController()
        self.permissionsWindow = permissionsWindow
        permissionsWindow.present()
    }
}
