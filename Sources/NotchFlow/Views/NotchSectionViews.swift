import AppKit
import Combine

final class NotchHostView: NSView {
    private let notchContentView: NotchAppView
    private let presentation: NotchPresentationModel
    private let sectionSwitcher = NotchSectionSwitcherView()
    private let sectionContentView: NotchSectionContentView
    private var selectedSection: NotchSection = .home
    private var cancellables = Set<AnyCancellable>()

    init(notchContentView: NotchAppView, presentation: NotchPresentationModel) {
        self.notchContentView = notchContentView
        self.presentation = presentation
        self.sectionContentView = NotchSectionContentView(presentation: presentation)
        super.init(frame: .zero)

        addSubview(notchContentView)
        sectionContentView.isHidden = true
        sectionContentView.alphaValue = 0
        addSubview(sectionContentView)
        addSubview(sectionSwitcher)
        sectionSwitcher.onSelection = { [weak self] section in
            self?.selectSection(section)
        }

        presentation.$appOpenProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.needsLayout = true
                self?.sectionContentView.needsLayout = true
            }
            .store(in: &cancellables)

        presentation.$isAppOpen
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.selectSection(.home, animated: false) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        notchContentView.frame = bounds
        sectionContentView.frame = bounds

        let progress = smoothstep(max(0, min(1, (presentation.appOpenProgress - 0.58) / 0.42)))
        let size = NSSize(width: 112, height: 34)
        let notchBottom = bounds.maxY - presentation.currentHeight
        sectionSwitcher.frame = NSRect(
            x: bounds.midX - size.width / 2,
            y: notchBottom - 12 - size.height + 6 * (1 - progress),
            width: size.width,
            height: size.height
        )
        sectionSwitcher.alphaValue = progress
        sectionSwitcher.isHidden = progress < 0.01
    }

    private func selectSection(_ section: NotchSection, animated: Bool = true) {
        guard selectedSection != section else { return }
        selectedSection = section
        sectionSwitcher.setSelectedSection(section)

        if section == .home {
            notchContentView.isHidden = false
            notchContentView.setAppActive(true)
            guard animated else {
                sectionContentView.alphaValue = 0
                sectionContentView.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sectionContentView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard self?.selectedSection == .home else { return }
                self?.sectionContentView.isHidden = true
            }
            return
        }

        // The selected section becomes the sole responder before its visual
        // transition begins, preventing any event from reaching Now Playing.
        notchContentView.setAppActive(false)
        sectionContentView.configure(for: section)
        sectionContentView.isHidden = false
        if animated {
            sectionContentView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sectionContentView.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                guard self?.selectedSection != .home else { return }
                self?.notchContentView.isHidden = true
            }
        } else {
            sectionContentView.alphaValue = 1
            notchContentView.isHidden = true
        }
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }
}

final class NotchSectionSwitcherView: NSView {
    var onSelection: ((NotchSection) -> Void)?

    private let buttons: [NotchSectionButton]
    private let separators = [NSView(), NSView()]
    private var selectedSection: NotchSection = .home

    override init(frame frameRect: NSRect) {
        let sections: [(NotchSection, String, String)] = [
            (.home, "house.fill", "Home"),
            (.tray, "tray.full.fill", "Tray"),
            (.apps, "square.grid.2x2.fill", "Apps")
        ]
        buttons = sections.map { NotchSectionButton(section: $0.0, symbol: $0.1, label: $0.2) }
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.94).cgColor
        layer?.cornerRadius = 17
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 6
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        for button in buttons {
            button.target = self
            button.action = #selector(selectSection(_:))
            addSubview(button)
        }
        for separator in separators {
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
            addSubview(separator)
        }
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelectedSection(_ section: NotchSection) {
        selectedSection = section
        updateSelection()
    }

    override func layout() {
        super.layout()
        let buttonWidth = bounds.width / 3
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: CGFloat(index) * buttonWidth + 3,
                y: 3,
                width: buttonWidth - 6,
                height: bounds.height - 6
            )
        }
        for (index, separator) in separators.enumerated() {
            separator.frame = NSRect(
                x: CGFloat(index + 1) * buttonWidth - 0.5,
                y: 9,
                width: 1,
                height: bounds.height - 18
            )
        }
    }

    @objc private func selectSection(_ sender: NotchSectionButton) {
        guard selectedSection != sender.section else { return }
        selectedSection = sender.section
        updateSelection()
        onSelection?(sender.section)
    }

    private func updateSelection() {
        buttons.forEach { $0.setSelected($0.section == selectedSection) }
    }
}

private final class NotchSectionButton: NSButton {
    let section: NotchSection

    init(section: NotchSection, symbol: String, label: String) {
        self.section = section
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 14
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ selected: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = selected
            ? NSColor.white.withAlphaComponent(0.19).cgColor
            : NSColor.clear.cgColor
        contentTintColor = selected ? .white : .secondaryLabelColor
        CATransaction.commit()
    }
}

final class NotchSectionContentView: NSView {
    private let presentation: NotchPresentationModel
    private let clipMask = CAShapeLayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let detailPill = NSView()
    private let detailIcon = NSImageView()
    private let detailLabel = NSTextField(labelWithString: "")

    init(presentation: NotchPresentationModel) {
        self.presentation = presentation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        clipMask.fillColor = NSColor.black.cgColor
        layer?.mask = clipMask

        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        detailPill.wantsLayer = true
        detailPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        detailPill.layer?.cornerRadius = 11
        detailIcon.contentTintColor = .white
        detailIcon.imageScaling = .scaleProportionallyDown
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .white

        [iconView, titleLabel, subtitleLabel, detailPill].forEach(addSubview)
        detailPill.addSubview(detailIcon)
        detailPill.addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(for section: NotchSection) {
        switch section {
        case .home:
            break
        case .tray:
            setSymbol("tray.full.fill", for: iconView, pointSize: 29)
            titleLabel.stringValue = "Tray"
            subtitleLabel.stringValue = "Drop files here for quick access"
            setSymbol("plus", for: detailIcon, pointSize: 10)
            detailLabel.stringValue = "Ready for files"
        case .apps:
            setSymbol("square.grid.2x2.fill", for: iconView, pointSize: 27)
            titleLabel.stringValue = "Notch Apps"
            subtitleLabel.stringValue = "Choose what appears in your notch"
            setSymbol("music.note", for: detailIcon, pointSize: 10)
            detailLabel.stringValue = "Now Playing"
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipMask.frame = bounds
        clipMask.path = NotchSilhouette.path(in: bounds, presentation: presentation).cgPath
        CATransaction.commit()

        let visibleWidth = presentation.currentWidth
        let visibleHeight = presentation.currentHeight
        let visibleBottom = bounds.maxY - visibleHeight
        let centerX = bounds.midX
        let contentCenterY = visibleBottom + (visibleHeight - 24) / 2
        let contentLeft = centerX - visibleWidth / 2 + 26
        let contentWidth = visibleWidth - 52
        iconView.frame = NSRect(x: centerX - 20, y: contentCenterY + 22, width: 40, height: 40)
        titleLabel.frame = NSRect(x: contentLeft, y: contentCenterY - 4, width: contentWidth, height: 23)
        subtitleLabel.frame = NSRect(x: contentLeft, y: contentCenterY - 25, width: contentWidth, height: 17)
        detailPill.frame = NSRect(x: centerX - 59, y: contentCenterY - 58, width: 118, height: 23)
        detailIcon.frame = NSRect(x: 10, y: 5, width: 13, height: 13)
        detailLabel.frame = NSRect(x: 29, y: 3, width: 79, height: 17)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        NotchSilhouette.path(in: bounds, presentation: presentation).contains(point) ? self : nil
    }

    private func setSymbol(_ name: String, for imageView: NSImageView, pointSize: CGFloat) {
        imageView.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
    }
}

enum NotchSilhouette {
    static func path(in bounds: NSRect, presentation: NotchPresentationModel) -> NSBezierPath {
        let width = presentation.currentWidth
        let height = presentation.currentHeight
        let left = bounds.midX - width / 2
        let right = bounds.midX + width / 2
        let top = bounds.maxY
        let bottom = top - height
        let compactShoulder = min(18, presentation.hoverHeight * 0.26)
        let compactRadius = min(18, presentation.hoverHeight * 0.28)
        let shoulder = interpolate(compactShoulder, 26, progress: presentation.appOpenProgress)
        let radius = interpolate(compactRadius, 30, progress: presentation.appOpenProgress)
        let leftWall = left + shoulder
        let rightWall = right - shoulder

        let path = NSBezierPath()
        path.move(to: NSPoint(x: left, y: top))
        path.line(to: NSPoint(x: right, y: top))
        path.curve(
            to: NSPoint(x: rightWall, y: top - shoulder),
            controlPoint1: NSPoint(x: right - shoulder * 0.55, y: top),
            controlPoint2: NSPoint(x: rightWall, y: top - shoulder * 0.48)
        )
        path.line(to: NSPoint(x: rightWall, y: bottom + radius))
        path.curve(
            to: NSPoint(x: rightWall - radius, y: bottom),
            controlPoint1: NSPoint(x: rightWall, y: bottom + radius * 0.35),
            controlPoint2: NSPoint(x: rightWall - radius * 0.35, y: bottom)
        )
        path.line(to: NSPoint(x: leftWall + radius, y: bottom))
        path.curve(
            to: NSPoint(x: leftWall, y: bottom + radius),
            controlPoint1: NSPoint(x: leftWall + radius * 0.35, y: bottom),
            controlPoint2: NSPoint(x: leftWall, y: bottom + radius * 0.35)
        )
        path.line(to: NSPoint(x: leftWall, y: top - shoulder))
        path.curve(
            to: NSPoint(x: left, y: top),
            controlPoint1: NSPoint(x: leftWall, y: top - shoulder * 0.48),
            controlPoint2: NSPoint(x: left + shoulder * 0.55, y: top)
        )
        path.close()
        return path
    }

    private static func interpolate(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}
