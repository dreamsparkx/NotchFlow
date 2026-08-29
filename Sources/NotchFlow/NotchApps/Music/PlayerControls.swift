import AppKit

final class PlayerControlButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var selectionHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelectionHighlighted(_ highlighted: Bool) {
        selectionHighlighted = highlighted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = highlighted
            ? NSColor.systemBlue.withAlphaComponent(0.30).cgColor
            : NSColor.clear.cgColor
        contentTintColor = highlighted ? .systemBlue : .white
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = selectionHighlighted
            ? NSColor.systemBlue.withAlphaComponent(0.40).cgColor
            : NSColor.white.withAlphaComponent(0.10).cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = selectionHighlighted
            ? NSColor.systemBlue.withAlphaComponent(0.30).cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.55
        displayIfNeeded()
        super.mouseDown(with: event)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            animator().alphaValue = 1
        }
    }
}

final class ResponsiveSlider: NSSlider {
    var onEditingEnded: ((Double) -> Void)?
    private(set) var isUserTracking = false

    override func mouseDown(with event: NSEvent) {
        isUserTracking = true
        super.mouseDown(with: event)
        isUserTracking = false
        onEditingEnded?(doubleValue)
    }
}

final class PlayerSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let slider = controlView as? NSSlider else { return }
        let trackHeight: CGFloat = 7
        let track = NSRect(x: rect.minX, y: rect.midY - trackHeight / 2, width: rect.width, height: trackHeight)
        NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()

        let range = max(0.0001, slider.maxValue - slider.minValue)
        let fraction = CGFloat((slider.doubleValue - slider.minValue) / range)
        let played = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: played, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) { }
}
