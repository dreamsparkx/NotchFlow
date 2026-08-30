import AppKit
import PermissionFlow
import SwiftUI

final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let contentView = PermissionSetupView()
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Set Up NotchFlow"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 430, height: 310))
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PermissionSetupView: View {
    private let appURL = Bundle.main.bundleURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Finish setting up NotchFlow")
                    .font(.title2.bold())
                Text("These permissions let NotchFlow detect media-key presses and replace the standard brightness and volume overlays.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                PermissionFlowButton(
                    title: "Accessibility",
                    pane: .accessibility,
                    suggestedAppURLs: [appURL]
                )
                PermissionFlowButton(
                    title: "Input Monitoring",
                    pane: .inputMonitoring,
                    suggestedAppURLs: [appURL]
                )
            }
            .controlSize(.large)

            Text("PermissionFlow opens the correct System Settings page. macOS still requires you to approve or drag NotchFlow into the list.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Continue") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430, height: 310)
    }
}
