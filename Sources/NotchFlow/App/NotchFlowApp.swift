import AppKit
import PermissionFlow
import PermissionFlowInputMonitoringStatus
import SwiftUI

@main
struct NotchFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            VStack(alignment: .leading, spacing: 10) {
                Text("NotchFlow")
                    .font(.title2.bold())
                Text("Notch controls and permissions can be managed from the menu bar.")
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: 420, height: 150, alignment: .topLeading)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchWindow: NotchWindowController?
    private var permissionsWindow: PermissionsWindowController?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PermissionFlowInputMonitoringStatus.register()
        NSApp.setActivationPolicy(.accessory)
        notchWindow = NotchWindowController()
        notchWindow?.showWindow(nil)
        menuBarController = MenuBarController(
            showNowPlaying: { [weak self] in
                self?.notchWindow?.showNowPlaying()
            },
            showSettings: {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        )

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
