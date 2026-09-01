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

        sectionContentView.onSelectApp = { [weak self] identifier in
            if identifier == "file-tray" {
                self?.selectSection(.tray)
                return
            }
            (self?.notchContentView as? NotchHomeView)?.selectApp(identifier: identifier)
            self?.selectSection(.home)
        }

        addSubview(notchContentView)
        sectionContentView.isHidden = true
        sectionContentView.alphaValue = 0
        addSubview(sectionContentView)
        addSubview(sectionSwitcher)
        sectionSwitcher.onSelection = { [weak self] section in
            self?.selectSection(section)
        }

        Publishers.CombineLatest(
            presentation.$appOpenProgress,
            presentation.$sectionExpansionProgress
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
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
        let previousSection = selectedSection
        selectedSection = section
        sectionSwitcher.setSelectedSection(section, animated: animated)

        if section == .home {
            presentation.setAlternateSectionVisible(false, animated: animated)
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
        presentation.setAlternateSectionVisible(true, animated: animated)
        notchContentView.setAppActive(false)
        sectionContentView.show(section, animated: animated && previousSection != .home)
        sectionContentView.isHidden = false
        if animated && previousSection == .home {
            sectionContentView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sectionContentView.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                guard self?.selectedSection != .home else { return }
                self?.notchContentView.isHidden = true
            }
        } else if !animated {
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
    private let selectionIndicator = NSView()
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

        selectionIndicator.wantsLayer = true
        selectionIndicator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.19).cgColor
        selectionIndicator.layer?.cornerRadius = 14
        addSubview(selectionIndicator)
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

    func setSelectedSection(_ section: NotchSection, animated: Bool = true) {
        selectedSection = section
        updateSelection()
        guard animated, bounds.width > 0 else {
            needsLayout = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            selectionIndicator.animator().frame = indicatorFrame(for: section)
        }
    }

    override func layout() {
        super.layout()
        let buttonWidth = bounds.width / 3
        selectionIndicator.frame = indicatorFrame(for: selectedSection)
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
        setSelectedSection(sender.section)
        onSelection?(sender.section)
    }

    private func updateSelection() {
        buttons.forEach { $0.setSelected($0.section == selectedSection) }
    }

    private func indicatorFrame(for section: NotchSection) -> NSRect {
        let index = NotchSection.allCases.firstIndex(of: section) ?? 0
        let buttonWidth = bounds.width / 3
        return NSRect(
            x: CGFloat(index) * buttonWidth + 3,
            y: 3,
            width: buttonWidth - 6,
            height: bounds.height - 6
        )
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
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = selected ? .white : .secondaryLabelColor
        CATransaction.commit()
    }
}

final class NotchSectionContentView: NSView {
    var onSelectApp: ((String) -> Void)?

    private let presentation: NotchPresentationModel
    private let clipMask = CAShapeLayer()
    private let trayView: NotchTrayView
    private let appsView: NotchAppsCarouselView
    private var currentSection: NotchSection?

    init(presentation: NotchPresentationModel) {
        self.presentation = presentation
        self.trayView = NotchTrayView(presentation: presentation)
        self.appsView = NotchAppsCarouselView(presentation: presentation)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        clipMask.fillColor = NSColor.black.cgColor
        layer?.mask = clipMask
        trayView.isHidden = true
        appsView.isHidden = true
        appsView.onSelectApp = { [weak self] identifier in
            self?.onSelectApp?(identifier)
        }
        addSubview(trayView)
        addSubview(appsView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ section: NotchSection, animated: Bool) {
        guard section != .home else { return }
        let incoming = section == .tray ? trayView : appsView
        let outgoing = currentSection == .tray ? trayView : currentSection == .apps ? appsView : nil
        currentSection = section

        guard incoming !== outgoing else { return }
        incoming.isHidden = false
        incoming.alphaValue = animated ? 0 : 1
        incoming.layer?.setAffineTransform(animated
            ? CGAffineTransform(scaleX: 0.96, y: 0.96)
            : .identity)
        needsLayout = true
        layoutSubtreeIfNeeded()

        guard animated else {
            outgoing?.isHidden = true
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            outgoing?.animator().alphaValue = 0
            incoming.animator().alphaValue = 1
        } completionHandler: {
            outgoing?.isHidden = true
            outgoing?.alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        incoming.layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipMask.frame = bounds
        clipMask.path = NotchSilhouette.path(in: bounds, presentation: presentation).cgPath
        CATransaction.commit()

        trayView.frame = bounds
        appsView.frame = bounds
        trayView.needsLayout = true
        appsView.needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NotchSilhouette.path(in: bounds, presentation: presentation).contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}

private final class NotchTrayView: NSView {
    private let presentation: NotchPresentationModel
    private let borderLayer = CAShapeLayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Tray")

    init(presentation: NotchPresentationModel) {
        self.presentation = presentation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.13).cgColor
        borderLayer.lineWidth = 2
        borderLayer.lineDashPattern = [6, 5]
        layer?.addSublayer(borderLayer)

        iconView.image = NSImage(
            systemSymbolName: "tray.full.fill",
            accessibilityDescription: "Tray"
        )?.withSymbolConfiguration(.init(pointSize: 23, weight: .medium))
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.43)
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.43)
        titleLabel.alignment = .center
        addSubview(iconView)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = presentation.currentWidth
        let height = presentation.currentHeight
        let left = bounds.midX - width / 2
        let bottom = bounds.maxY - height
        let dropFrame = NSRect(x: left + 36, y: bottom + 28, width: width - 72, height: height - 66)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = bounds
        borderLayer.path = NSBezierPath(
            roundedRect: dropFrame,
            xRadius: 18,
            yRadius: 18
        ).cgPath
        CATransaction.commit()

        iconView.frame = NSRect(x: dropFrame.midX - 18, y: dropFrame.midY + 1, width: 36, height: 28)
        titleLabel.frame = NSRect(x: dropFrame.midX - 60, y: dropFrame.midY - 23, width: 120, height: 19)
    }
}

private final class NotchAppsCarouselView: NSView {
    var onSelectApp: ((String) -> Void)?

    private let presentation: NotchPresentationModel
    private let scrollView = NSScrollView()
    private let stripView = NSView()
    private let tiles: [NotchAppTileView]

    init(presentation: NotchPresentationModel) {
        self.presentation = presentation
        let definitions: [(String, String, NSColor, String?, String?)] = [
            ("File Tray", "folder.fill", .systemBlue, "file-tray", "/System/Library/CoreServices/Finder.app"),
            ("Weather", "cloud.sun.fill", .systemCyan, nil, "/System/Applications/Weather.app"),
            ("Now Playing", "waveform", .systemRed, "now-playing", "/System/Applications/Music.app"),
            ("Notifications", "bell.fill", .systemRed, nil, nil),
            ("Camera", "video.fill", .systemGreen, nil, "/System/Applications/FaceTime.app"),
            ("Calendar", "calendar", .systemRed, nil, "/System/Applications/Calendar.app"),
            ("Notes", "note.text", .systemYellow, nil, "/System/Applications/Notes.app"),
            ("Clipboard", "clipboard.fill", .systemBlue, nil, nil),
            ("System Stats", "chart.bar.fill", .systemPurple, nil, nil)
        ]
        tiles = definitions.map {
            NotchAppTileView(
                title: $0.0,
                symbol: $0.1,
                color: $0.2,
                identifier: $0.3,
                applicationPath: $0.4
            )
        }
        super.init(frame: .zero)
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = stripView
        addSubview(scrollView)
        for tile in tiles {
            tile.onSelect = { [weak self] identifier in self?.onSelectApp?(identifier) }
            stripView.addSubview(tile)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = presentation.currentWidth
        let height = presentation.currentHeight
        let left = bounds.midX - width / 2
        let bottom = bounds.maxY - height
        scrollView.frame = NSRect(x: left + 24, y: bottom + 28, width: width - 48, height: height - 58)

        let tileWidth: CGFloat = 76
        let gap: CGFloat = 13
        let totalWidth = 20 + CGFloat(tiles.count) * tileWidth + CGFloat(tiles.count - 1) * gap + 20
        stripView.frame = NSRect(x: 0, y: 0, width: totalWidth, height: scrollView.contentSize.height)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: 20 + CGFloat(index) * (tileWidth + gap), y: 5, width: tileWidth, height: 103)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        let clipView = scrollView.contentView
        let maximumX = max(0, stripView.bounds.width - clipView.bounds.width)
        let nextX = min(maximumX, max(0, clipView.bounds.origin.x + delta))
        clipView.scroll(to: NSPoint(x: nextX, y: 0))
        scrollView.reflectScrolledClipView(clipView)
    }
}

private final class NotchAppTileView: NSView {
    var onSelect: ((String) -> Void)?

    private let iconBackground = NSView()
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let button = NSButton()
    private let appIdentifier: String?
    private let usesApplicationIcon: Bool

    init(
        title: String,
        symbol: String,
        color: NSColor,
        identifier: String?,
        applicationPath: String?
    ) {
        titleLabel = NSTextField(labelWithString: title)
        self.appIdentifier = identifier
        self.usesApplicationIcon = applicationPath.map(FileManager.default.fileExists) ?? false
        super.init(frame: .zero)

        iconBackground.wantsLayer = true
        iconBackground.layer?.backgroundColor = usesApplicationIcon
            ? NSColor.clear.cgColor
            : color.withAlphaComponent(0.86).cgColor
        iconBackground.layer?.cornerRadius = 14
        iconBackground.layer?.borderWidth = usesApplicationIcon ? 0 : 0.5
        iconBackground.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        if usesApplicationIcon, let applicationPath {
            iconView.image = NSWorkspace.shared.icon(forFile: applicationPath)
            iconView.contentTintColor = nil
            iconView.imageScaling = .scaleProportionallyUpOrDown
        } else {
            iconView.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: title
            )?.withSymbolConfiguration(.init(pointSize: 24, weight: .medium))
            iconView.contentTintColor = .white
            iconView.imageScaling = .scaleProportionallyDown
        }
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        addSubview(iconBackground)
        iconBackground.addSubview(iconView)
        addSubview(titleLabel)
        button.isBordered = false
        button.imagePosition = .noImage
        button.title = ""
        button.target = self
        button.action = #selector(activateApp)
        button.isEnabled = identifier != nil
        button.toolTip = identifier == nil ? "Coming soon" : "Open \(title)"
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = usesApplicationIcon ? 70 : 58
        iconBackground.frame = NSRect(
            x: bounds.midX - iconSize / 2,
            y: 63 - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        iconView.frame = usesApplicationIcon
            ? iconBackground.bounds
            : iconBackground.bounds.insetBy(dx: 12, dy: 12)
        titleLabel.frame = NSRect(x: 0, y: 9, width: bounds.width, height: 18)
        button.frame = bounds
    }

    @objc private func activateApp() {
        guard let appIdentifier else { return }
        onSelect?(appIdentifier)
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
