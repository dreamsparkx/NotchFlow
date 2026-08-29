import AppKit

/// Shared compact overlay used for both display brightness and system volume.
final class SystemHUDView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Display")
    private let levelView = SystemLevelBarView()
    private let valueLabel = NSTextField(labelWithString: "50")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .left
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        valueLabel.alignment = .right

        [iconView, titleLabel, levelView, valueLabel].forEach(addSubview)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(kind: SystemHUDKind, level: Double, isMuted: Bool, progress: CGFloat) {
        let isVolume = kind == .volume
        let symbolName: String
        if isVolume {
            symbolName = isMuted || level <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        } else {
            symbolName = "sun.max.fill"
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isVolume ? "Volume" : "Display brightness"
        )?.withSymbolConfiguration(configuration)
        titleLabel.stringValue = isVolume ? "Volume" : "Display"
        levelView.fillColor = isVolume ? .systemGreen : NSColor(
            calibratedRed: 1,
            green: 0.82,
            blue: 0.03,
            alpha: 1
        )
        levelView.level = level
        valueLabel.stringValue = String(Int((level * 100).rounded()))
        alphaValue = progress
    }

    func layoutHUD(
        in containerBounds: NSRect,
        visibleWidth: CGFloat,
        visibleHeight: CGFloat,
        hardwareNotchWidth: CGFloat,
        animationProgress: CGFloat
    ) {
        frame = containerBounds
        let left = bounds.midX - visibleWidth / 2
        let bottom = bounds.maxY - visibleHeight
        let centerY = bottom + visibleHeight / 2 - 1
        let enteringOffset = 5 * (1 - animationProgress)
        let hardwareRightEdge = bounds.midX + hardwareNotchWidth / 2
        let labelRowY = centerY - 11 + enteringOffset

        // SF Symbols include optical padding, so the glyph is lifted one point
        // relative to the text frame for a visually shared baseline.
        let iconFrame = NSRect(x: left + 32, y: labelRowY + 2, width: 20, height: 20)
        iconView.frame = iconFrame
        titleLabel.frame = NSRect(x: iconFrame.maxX + 7, y: labelRowY, width: 104, height: 22)

        // Keep the complete level control outside the physical camera housing.
        let levelX = hardwareRightEdge + 14
        levelView.frame = NSRect(x: levelX, y: centerY - 4 + enteringOffset, width: 105, height: 8)
        valueLabel.frame = NSRect(x: levelX + 117, y: centerY - 10 + enteringOffset, width: 34, height: 22)
    }
}

private final class SystemLevelBarView: NSView {
    var level: Double = 0.5 {
        didSet { needsDisplay = true }
    }
    var fillColor = NSColor.systemYellow {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = bounds.insetBy(dx: 0, dy: 0.5)
        let radius = track.height / 2
        fillColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let fraction = CGFloat(min(1, max(0, level)))
        guard fraction > 0 else { return }
        let fill = NSRect(
            x: track.minX,
            y: track.minY,
            width: max(track.height, track.width * fraction),
            height: track.height
        )
        fillColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
