import AppKit

enum NotchSection: CaseIterable, Equatable {
    case home
    case tray
    case apps
}

/// A self-contained feature rendered inside the notch host.
///
/// Each notch app owns its feature model and creates its own view. The window
/// controller only hosts the returned view and routes generic pointer events.
protocol NotchApp: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    func makeView(presentation: NotchPresentationModel) -> NotchAppView
}

/// Base view contract used by the generic notch window.
class NotchAppView: NSView {
    var hasContent: Bool { false }
    private(set) var isAppActive = true

    func setAppActive(_ active: Bool) {
        isAppActive = active
    }

    func isPointerOverPrimaryContent(_ screenPoint: NSPoint) -> Bool {
        false
    }
}

/// Hosts the user's enabled Home apps while exposing one active app to the
/// notch at a time. Adding another Home app no longer requires changing the
/// window controller or the global section navigation.
final class NotchHomeView: NotchAppView {
    private struct Entry {
        let app: any NotchApp
        let view: NotchAppView
    }

    private let entries: [Entry]
    private var activeIndex = 0

    init(apps: [any NotchApp], presentation: NotchPresentationModel) {
        precondition(!apps.isEmpty, "Home requires at least one notch app")
        entries = apps.map { Entry(app: $0, view: $0.makeView(presentation: presentation)) }
        super.init(frame: .zero)

        for (index, entry) in entries.enumerated() {
            entry.view.isHidden = index != activeIndex
            entry.view.setAppActive(index == activeIndex)
            addSubview(entry.view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var hasContent: Bool { activeView.hasContent }

    var availableApps: [(identifier: String, displayName: String)] {
        entries.map { ($0.app.identifier, $0.app.displayName) }
    }

    override func layout() {
        super.layout()
        entries.forEach { $0.view.frame = bounds }
    }

    override func setAppActive(_ active: Bool) {
        super.setAppActive(active)
        activeView.setAppActive(active)
    }

    override func isPointerOverPrimaryContent(_ screenPoint: NSPoint) -> Bool {
        guard isAppActive else { return false }
        return activeView.isPointerOverPrimaryContent(screenPoint)
    }

    func selectApp(identifier: String) {
        guard let newIndex = entries.firstIndex(where: { $0.app.identifier == identifier }),
              newIndex != activeIndex else { return }
        entries[activeIndex].view.setAppActive(false)
        entries[activeIndex].view.isHidden = true
        activeIndex = newIndex
        activeView.isHidden = false
        activeView.setAppActive(isAppActive)
        needsLayout = true
    }

    private var activeView: NotchAppView { entries[activeIndex].view }
}
