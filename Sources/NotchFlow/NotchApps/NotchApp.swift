import AppKit

/// A self-contained feature rendered inside the notch host.
///
/// Each notch app owns its feature model and creates its own view. The window
/// controller only hosts the returned view and routes generic pointer events.
protocol NotchApp: AnyObject {
    var identifier: String { get }
    func makeView(presentation: NotchPresentationModel) -> NotchAppView
}

/// Base view contract used by the generic notch window.
class NotchAppView: NSView {
    var hasContent: Bool { false }

    func isPointerOverPrimaryContent(_ screenPoint: NSPoint) -> Bool {
        false
    }
}
