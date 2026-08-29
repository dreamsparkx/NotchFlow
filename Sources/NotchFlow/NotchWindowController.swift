import AppKit
import Combine
import CoreAudio

final class NotchWindowController: NSWindowController {
    private let nowPlaying = NowPlayingModel()
    private let presentation = NotchPresentationModel()
    private var hoverTimer: Timer?
    private var collapseWorkItem: DispatchWorkItem?
    private var pointerIsInside = false
    private var notchContentView: NotchContainerView!
    private var cancellables = Set<AnyCancellable>()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var hardwareKeyMonitor: HardwareKeyMonitor?

    init() {
        let size = NSSize(width: 620, height: 90)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let contentView = NotchContainerView(nowPlaying: nowPlaying, presentation: presentation)
        notchContentView = contentView
        panel.contentView = contentView

        super.init(window: panel)
        updateCompactMetrics()
        position(panel, size: size)
        panel.orderFrontRegardless()
        startHoverTracking()
        startOutsideClickTracking()
        hardwareKeyMonitor = HardwareKeyMonitor(
            onBrightnessChanged: { [weak self] level in
                guard let self else { return }
                self.prepareForSystemHUD()
                self.presentation.showBrightness(level)
            },
            onVolumeChanged: { [weak self] level, isMuted in
                guard let self else { return }
                self.prepareForSystemHUD()
                self.presentation.showVolume(level, isMuted: isMuted)
            }
        )
        hardwareKeyMonitor?.start()

        presentation.$isPlayerOpen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isOpen in
                if isOpen { self?.resizeWindow(forPlayer: true) }
            }
            .store(in: &cancellables)

        presentation.$playerProgress
            .removeDuplicates()
            .filter { [weak self] progress in progress <= 0 && self?.presentation.isPlayerOpen == false }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeWindow(forPlayer: false) }
            .store(in: &cancellables)

        presentation.$isQueueOpen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isOpen in
                if isOpen { self?.resizeWindow(forPlayer: true, queueOpen: true) }
            }
            .store(in: &cancellables)

        presentation.$queueProgress
            .removeDuplicates()
            .filter { [weak self] progress in
                progress <= 0 && self?.presentation.isPlayerOpen == true
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeWindow(forPlayer: true) }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let panel = self?.window else { return }
            self?.updateCompactMetrics()
            self?.position(panel, size: size)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        hoverTimer?.invalidate()
        collapseWorkItem?.cancel()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }

    private func position(_ panel: NSWindow, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        ))
    }

    private func updateCompactMetrics() {
        guard let screen = NSScreen.main else { return }
        let safeAreaHeight = screen.safeAreaInsets.top
        let visibleFrameHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let statusBarHeight = NSStatusBar.system.thickness
        var measuredHeight = max(safeAreaHeight, max(visibleFrameHeight, statusBarHeight))

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // These rectangles are the usable menu-bar strips directly beside
            // the camera housing. Their height is the most reliable physical
            // notch depth on scaled Retina modes.
            measuredHeight = max(measuredHeight, max(left.height, right.height))
            let hardwareNotchWidth = max(180, right.minX - left.maxX)
            presentation.hardwareNotchWidth = hardwareNotchWidth
            presentation.compactWidth = min(360, hardwareNotchWidth + 124)
        } else {
            presentation.hardwareNotchWidth = 186
            presentation.compactWidth = 310
        }
        presentation.compactHeight = measuredHeight > 0 ? measuredHeight : 32
    }

    private func startHoverTracking() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let panel = self.window else { return }
            if self.presentation.isPlayerOpen || self.presentation.isSystemHUDVisible {
                self.presentation.setMediaDetailsVisible(false)
                return
            }
            let width = self.presentation.currentWidth
            let height = self.presentation.currentHeight
            guard let screen = panel.screen ?? NSScreen.main else { return }
            let visibleShape = NSRect(
                x: panel.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            ).insetBy(dx: -8, dy: -6)
            self.setPointerInside(visibleShape.contains(NSEvent.mouseLocation))
            self.presentation.setMediaDetailsVisible(
                self.notchContentView.isPointerOverMedia(NSEvent.mouseLocation) && self.nowPlaying.hasTrack
            )
        }
    }

    private func resizeWindow(forPlayer isOpen: Bool, queueOpen: Bool = false) {
        guard let panel = window, let screen = panel.screen ?? NSScreen.main else { return }
        let size: NSSize
        if queueOpen {
            size = NSSize(width: 980, height: 195)
        } else {
            size = isOpen ? NSSize(width: 620, height: 195) : NSSize(width: 620, height: 90)
        }
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: false)
    }

    private func startOutsideClickTracking() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async { self?.presentation.setPlayerOpen(false) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if self?.presentation.isPlayerOpen == true, event.window !== self?.window {
                self?.presentation.setPlayerOpen(false)
            }
            return event
        }
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != pointerIsInside else { return }
        pointerIsInside = inside
        collapseWorkItem?.cancel()

        if inside {
            presentation.setExpanded(true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.pointerIsInside else { return }
                self.presentation.setExpanded(false)
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
        }
    }

    private func prepareForSystemHUD() {
        collapseWorkItem?.cancel()
        pointerIsInside = false
    }
}

/// Draws the silhouette in native AppKit coordinates. This avoids SwiftUI's
/// automatic camera-safe-area padding changing the visible height.
private final class NotchContainerView: NSView {
    private let presentation: NotchPresentationModel
    private let nowPlaying: NowPlayingModel
    private let artworkView = NSImageView()
    private let waveformView = AppKitWaveformView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pauseButton = PlayerControlButton()
    private let fullTitleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")
    private let progressSlider = ResponsiveSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let queueButton = PlayerControlButton()
    private let previousButton = PlayerControlButton()
    private let fullPlayPauseButton = PlayerControlButton()
    private let nextButton = PlayerControlButton()
    private let outputButton = PlayerControlButton()
    private let queueDividerView = NSView()
    private let queueHeadingLabel = NSTextField(labelWithString: "Playing Next")
    private let queueMessageLabel = NSTextField(labelWithString: "")
    private let queueRows = (0..<3).map { _ in QueueTrackRowView() }
    private let brightnessCoverView = NSView()
    private let brightnessIconView = NSImageView()
    private let brightnessTitleLabel = NSTextField(labelWithString: "Display")
    private let brightnessLevelView = BrightnessLevelView()
    private let brightnessValueLabel = NSTextField(labelWithString: "50")
    private let clipMask = CAShapeLayer()
    private var cancellables = Set<AnyCancellable>()

    init(nowPlaying: NowPlayingModel, presentation: NotchPresentationModel) {
        self.presentation = presentation
        self.nowPlaying = nowPlaying
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 90))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        clipMask.fillColor = NSColor.black.cgColor
        layer?.mask = clipMask

        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.masksToBounds = true
        addSubview(artworkView)
        addSubview(waveformView)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alphaValue = 0
        addSubview(titleLabel)

        pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        pauseButton.imagePosition = .imageOnly
        pauseButton.isBordered = false
        pauseButton.contentTintColor = .white
        pauseButton.target = self
        pauseButton.action = #selector(togglePlayback)
        pauseButton.alphaValue = 0
        addSubview(pauseButton)

        configureFullPlayerControls()
        configureQueuePanel()
        configureBrightnessHUD()

        Publishers.CombineLatest(nowPlaying.$hasTrack, nowPlaying.$artwork)
            .receive(on: RunLoop.main)
            .sink { [weak self] hasTrack, artwork in
                self?.artworkView.isHidden = !hasTrack
                self?.waveformView.isHidden = !hasTrack
                self?.artworkView.image = artwork ?? NSImage(
                    systemSymbolName: "music.note",
                    accessibilityDescription: "Album artwork"
                )
                self?.artworkView.contentTintColor = artwork == nil ? .white : nil
                self?.artworkView.layer?.backgroundColor = artwork == nil
                    ? NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.24, alpha: 1).cgColor
                    : NSColor.clear.cgColor
            }
            .store(in: &cancellables)

        nowPlaying.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                let symbol = isPlaying ? "pause.fill" : "play.fill"
                let description = isPlaying ? "Pause" : "Play"
                self?.pauseButton.image = self?.configuredSymbol(symbol, description: description, pointSize: 13)
                self?.fullPlayPauseButton.image = self?.configuredSymbol(symbol, description: description, pointSize: 20)
                self?.waveformView.isAnimating = isPlaying
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(nowPlaying.$title, nowPlaying.$artist)
            .receive(on: RunLoop.main)
            .sink { [weak self] title, artist in
                self?.titleLabel.stringValue = artist.isEmpty ? title : "\(title) · \(artist)"
                self?.fullTitleLabel.stringValue = title
                self?.artistLabel.stringValue = artist
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(nowPlaying.$hasTrack, presentation.$showsMediaDetails, presentation.$isPlayerOpen)
            .receive(on: RunLoop.main)
            .sink { [weak self] hasTrack, details, playerOpen in
                self?.updateMediaVisibility(hasTrack: hasTrack, details: details, playerOpen: playerOpen)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(nowPlaying.$elapsed, nowPlaying.$duration)
            .receive(on: RunLoop.main)
            .sink { [weak self] elapsed, duration in self?.updateProgress(elapsed: elapsed, duration: duration) }
            .store(in: &cancellables)

        nowPlaying.$accentColor
            .receive(on: RunLoop.main)
            .sink { [weak self] color in
                self?.waveformView.transition(to: color)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            presentation.$expansionProgress,
            presentation.$compactWidth,
            presentation.$compactHeight
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.needsLayout = true
        }
        .store(in: &cancellables)

        presentation.$playerProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.needsLayout = true
            }
            .store(in: &cancellables)

        presentation.$queueProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsLayout = true }
            .store(in: &cancellables)

        Publishers.CombineLatest(nowPlaying.$queueTracks, nowPlaying.$queueMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] tracks, message in
                self?.updateQueue(tracks: tracks, message: message)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(presentation.$brightnessProgress, presentation.$brightnessLevel)
            .receive(on: RunLoop.main)
            .sink { [weak self] progress, level in
                guard let self else { return }
                [self.brightnessCoverView, self.brightnessIconView, self.brightnessTitleLabel,
                 self.brightnessLevelView, self.brightnessValueLabel].forEach { $0.alphaValue = progress }
                self.brightnessLevelView.level = level
                self.brightnessValueLabel.stringValue = String(Int((level * 100).rounded()))
                self.needsLayout = true
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(presentation.$systemHUDKind, presentation.$systemHUDIsMuted)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateSystemHUDAppearance() }
            .store(in: &cancellables)

        presentation.$brightnessLevel
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateSystemHUDAppearance() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateClipMask()
        layoutMediaViews()
    }

    override func mouseDown(with event: NSEvent) {
        guard nowPlaying.hasTrack, !presentation.isSystemHUDVisible else { return }
        presentation.setPlayerOpen(!presentation.isPlayerOpen)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let interactiveButtons = [pauseButton, progressSlider, queueButton, previousButton, fullPlayPauseButton, nextButton, outputButton]
        for view in interactiveButtons where !view.isHidden && view.alphaValue > 0.05 && view.frame.contains(point) {
            return view
        }
        return silhouettePath().contains(point) ? self : nil
    }

    func isPointerOverMedia(_ screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        return artworkView.frame.insetBy(dx: -8, dy: -8).contains(localPoint)
            || waveformView.frame.insetBy(dx: -8, dy: -8).contains(localPoint)
            || pauseButton.frame.insetBy(dx: -8, dy: -8).contains(localPoint)
    }

    @objc private func togglePlayback() {
        nowPlaying.togglePlayback()
    }

    @objc private func previousTrack() { nowPlaying.previousTrack() }
    @objc private func nextTrack() { nowPlaying.nextTrack() }
    @objc private func toggleQueue() {
        let opening = !presentation.isQueueOpen
        presentation.setQueueOpen(opening)
        if opening { nowPlaying.refreshQueue() }
    }
    @objc private func showAudioOutputs(_ sender: NSButton) {
        let menu = NSMenu(title: "Audio Output")
        let devices = AudioOutputManager.availableDevices()
        if devices.isEmpty {
            let unavailable = NSMenuItem(title: "No audio outputs found", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        } else {
            for device in devices {
                let item = NSMenuItem(
                    title: device.name,
                    action: #selector(selectAudioOutput(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NSNumber(value: device.id)
                item.state = device.isDefault ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Sound Settings…",
            action: #selector(openSoundSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        guard let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: sender)
    }

    @objc private func selectAudioOutput(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? NSNumber else { return }
        _ = AudioOutputManager.select(AudioDeviceID(identifier.uint32Value))
    }

    @objc private func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func previewSeek(_ sender: NSSlider) {
        elapsedLabel.stringValue = formatTime(sender.doubleValue)
        remainingLabel.stringValue = "-" + formatTime(max(0, sender.maxValue - sender.doubleValue))
    }

    private func updateMediaVisibility(hasTrack: Bool, details: Bool, playerOpen: Bool) {
        let compactDetails = hasTrack && details && !playerOpen
        artworkView.isHidden = !hasTrack
        waveformView.isHidden = !hasTrack
        pauseButton.isHidden = !hasTrack
        titleLabel.isHidden = !hasTrack
        fullPlayerViews.forEach { $0.isHidden = !hasTrack }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            waveformView.animator().alphaValue = hasTrack && (!details || playerOpen) ? 1 : 0
            pauseButton.animator().alphaValue = compactDetails ? 1 : 0
            titleLabel.animator().alphaValue = compactDetails ? 1 : 0
        }
        needsLayout = true
    }

    private func layoutMediaViews() {
        let progress = presentation.expansionProgress
        let width = presentation.hoverWidth
        let height = presentation.hoverHeight
        let compactArtwork = max(18, presentation.compactHeight - 16)
        let artworkSize = interpolate(compactArtwork, compactArtwork + 4, progress)
        let sidePadding = interpolate(26, 32, progress)
        let waveWidth = interpolate(34, 37, progress)
        let compactWaveHeight = max(8, presentation.compactHeight - 22)
        let waveHeight = interpolate(compactWaveHeight, compactWaveHeight + 2, progress)
        // Media stays centered in the original notch band; expansion grows
        // downward to make room for the title without moving the side items.
        let centerY = bounds.maxY - presentation.compactHeight / 2
        let left = bounds.midX - width / 2
        let right = bounds.midX + width / 2

        let compactArtworkFrame = NSRect(
            x: left + sidePadding,
            y: centerY - artworkSize / 2,
            width: artworkSize,
            height: artworkSize
        )
        let compactWaveformFrame = NSRect(
            x: right - sidePadding - waveWidth,
            y: centerY - waveHeight / 2,
            width: waveWidth,
            height: waveHeight
        )
        artworkView.frame = compactArtworkFrame
        artworkView.layer?.cornerRadius = interpolate(6, 8, progress)
        waveformView.frame = compactWaveformFrame
        pauseButton.frame = compactWaveformFrame
        titleLabel.frame = NSRect(
            x: bounds.midX - min(260, width - 140) / 2,
            y: bounds.maxY - height + 4,
            width: min(260, width - 140),
            height: 18
        )

        // Always run the zero-progress layout too. It clears every full-player
        // control after an interruption such as the brightness HUD.
        layoutFullPlayer(fromArtwork: compactArtworkFrame, fromWaveform: compactWaveformFrame)
        layoutBrightnessHUD()
    }

    private var fullPlayerViews: [NSView] {
        [fullTitleLabel, artistLabel, elapsedLabel, remainingLabel, progressSlider,
         queueButton, previousButton, fullPlayPauseButton, nextButton, outputButton]
    }

    private func configureFullPlayerControls() {
        fullTitleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        fullTitleLabel.textColor = .white
        fullTitleLabel.lineBreakMode = .byTruncatingTail
        artistLabel.font = .systemFont(ofSize: 14, weight: .medium)
        artistLabel.textColor = .secondaryLabelColor
        [elapsedLabel, remainingLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            $0.textColor = .secondaryLabelColor
        }

        progressSlider.target = self
        progressSlider.action = #selector(previewSeek(_:))
        progressSlider.isContinuous = true
        progressSlider.controlSize = .small
        progressSlider.cell = PlayerSliderCell()
        progressSlider.onEditingEnded = { [weak self] value in self?.nowPlaying.seek(to: value) }

        configureButton(queueButton, symbol: "list.bullet", pointSize: 17, action: #selector(toggleQueue))
        queueButton.toolTip = "Playing Next"
        configureButton(previousButton, symbol: "backward.fill", pointSize: 20, action: #selector(previousTrack))
        configureButton(fullPlayPauseButton, symbol: "pause.fill", pointSize: 20, action: #selector(togglePlayback))
        configureButton(nextButton, symbol: "forward.fill", pointSize: 20, action: #selector(nextTrack))
        configureButton(outputButton, symbol: "airplayaudio", pointSize: 17, action: #selector(showAudioOutputs(_:)))
        outputButton.toolTip = "Choose audio output"

        fullPlayerViews.forEach { view in
            view.alphaValue = 0
            view.isHidden = true
            addSubview(view)
        }
    }

    private func configureQueuePanel() {
        queueDividerView.wantsLayer = true
        queueDividerView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        queueHeadingLabel.font = .systemFont(ofSize: 17, weight: .bold)
        queueHeadingLabel.textColor = .white
        queueMessageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        queueMessageLabel.textColor = .secondaryLabelColor
        queueMessageLabel.lineBreakMode = .byTruncatingTail

        let views: [NSView] = [queueDividerView, queueHeadingLabel, queueMessageLabel] + queueRows
        views.forEach {
            $0.alphaValue = 0
            addSubview($0)
        }
    }

    private func updateQueue(tracks: [QueuedTrack], message: String) {
        for (index, row) in queueRows.enumerated() {
            if index < tracks.count {
                row.configure(with: tracks[index])
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        queueMessageLabel.stringValue = message
        queueMessageLabel.isHidden = message.isEmpty
        needsLayout = true
    }

    private func configureBrightnessHUD() {
        brightnessCoverView.wantsLayer = true
        brightnessCoverView.layer?.backgroundColor = NSColor.black.cgColor

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        brightnessIconView.image = NSImage(
            systemSymbolName: "sun.max.fill",
            accessibilityDescription: "Display brightness"
        )?.withSymbolConfiguration(symbolConfig)
        brightnessIconView.contentTintColor = .white
        brightnessIconView.imageScaling = .scaleProportionallyDown

        brightnessTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        brightnessTitleLabel.textColor = .white
        brightnessTitleLabel.alignment = .left

        brightnessValueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        brightnessValueLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        brightnessValueLabel.alignment = .right

        [brightnessCoverView, brightnessIconView, brightnessTitleLabel,
         brightnessLevelView, brightnessValueLabel].forEach {
            $0.alphaValue = 0
            addSubview($0)
        }
        updateSystemHUDAppearance()
    }

    private func updateSystemHUDAppearance() {
        let isVolume = presentation.systemHUDKind == .volume
        let symbolName: String
        if isVolume {
            symbolName = presentation.systemHUDIsMuted || presentation.brightnessLevel <= 0.001
                ? "speaker.slash.fill"
                : "speaker.wave.2.fill"
        } else {
            symbolName = "sun.max.fill"
        }
        let description = isVolume ? "Sound volume" : "Display brightness"
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        brightnessIconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        )?.withSymbolConfiguration(symbolConfig)
        brightnessTitleLabel.stringValue = isVolume ? "Sound" : "Display"
        brightnessLevelView.fillColor = isVolume
            ? NSColor.systemGreen
            : NSColor(calibratedRed: 1, green: 0.82, blue: 0.03, alpha: 1)
    }

    private func layoutBrightnessHUD() {
        let progress = presentation.brightnessProgress
        let width = presentation.currentWidth
        let height = presentation.currentHeight
        let left = bounds.midX - width / 2
        let bottom = bounds.maxY - height
        let centerY = bottom + height / 2 - 1
        let enteringOffset = 5 * (1 - progress)
        let hardwareRightEdge = bounds.midX + presentation.hardwareNotchWidth / 2

        brightnessCoverView.frame = bounds
        let labelRowY = centerY - 11 + enteringOffset
        // SF Symbols include optical padding around their paths. Lift the sun
        // one point and use a tighter gap so its visible glyph—not its image
        // frame—aligns with the label's cap height and baseline.
        let iconFrame = NSRect(x: left + 32, y: labelRowY + 2, width: 20, height: 20)
        brightnessIconView.frame = iconFrame
        brightnessTitleLabel.frame = NSRect(x: iconFrame.maxX + 7, y: labelRowY, width: 104, height: 22)

        // The physical camera housing sits above the center of this window and
        // obscures pixels. Keep the complete level control in the right wing.
        let levelX = hardwareRightEdge + 14
        brightnessLevelView.frame = NSRect(x: levelX, y: centerY - 4 + enteringOffset, width: 105, height: 8)
        brightnessValueLabel.frame = NSRect(x: levelX + 117, y: centerY - 10 + enteringOffset, width: 34, height: 22)
    }

    private func configureButton(_ button: PlayerControlButton, symbol: String, pointSize: CGFloat, action: Selector?) {
        button.image = configuredSymbol(symbol, description: nil, pointSize: pointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.contentTintColor = .white
        button.target = self
        button.action = action
    }

    private func configuredSymbol(_ name: String, description: String?, pointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
    }

    private func layoutFullPlayer(fromArtwork compactArtwork: NSRect, fromWaveform compactWaveform: NSRect) {
        let progress = presentation.playerProgress
        let queueProgress = presentation.queueProgress
        let metadataProgress = revealProgress(progress, start: 0.22)
        let timelineProgress = revealProgress(progress, start: 0.34)
        let controlsProgress = revealProgress(progress, start: 0.44)
        let width = presentation.fullPlayerWidth
        let height = presentation.fullPlayerHeight
        let playerCenterX = bounds.midX
            - (presentation.queuePlayerWidth - presentation.fullPlayerWidth) * queueProgress / 2
        let left = playerCenterX - width / 2
        let right = playerCenterX + width / 2
        let top = bounds.maxY
        let bottom = top - height

        let fullArtwork = NSRect(x: left + 40, y: top - 100, width: 76, height: 76)
        let fullWaveform = NSRect(x: right - 76, y: top - 57, width: 34, height: 16)
        artworkView.frame = interpolate(compactArtwork, fullArtwork, progress)
        artworkView.layer?.cornerRadius = interpolate(8, 14, progress)
        waveformView.frame = interpolate(compactWaveform, fullWaveform, progress)
        fullTitleLabel.frame = enteringFrame(
            NSRect(x: left + 138, y: top - 59, width: 288, height: 25),
            progress: metadataProgress,
            offset: 12
        )
        artistLabel.frame = enteringFrame(
            NSRect(x: left + 138, y: top - 82, width: 288, height: 21),
            progress: metadataProgress,
            offset: 12
        )

        elapsedLabel.frame = enteringFrame(
            NSRect(x: left + 40, y: bottom + 43, width: 54, height: 19),
            progress: timelineProgress,
            offset: 10
        )
        let finalSliderFrame = NSRect(x: left + 102, y: bottom + 43, width: width - 204, height: 19)
        let compressedSliderFrame = finalSliderFrame.insetBy(dx: 34, dy: 0).offsetBy(dx: 0, dy: 10)
        progressSlider.frame = interpolate(compressedSliderFrame, finalSliderFrame, timelineProgress)
        remainingLabel.frame = enteringFrame(
            NSRect(x: right - 94, y: bottom + 43, width: 54, height: 19),
            progress: timelineProgress,
            offset: 10
        )
        remainingLabel.alignment = .right

        let controlY = bottom + 6
        queueButton.frame = enteringFrame(NSRect(x: left + 40, y: controlY, width: 32, height: 32), progress: controlsProgress, offset: 9)
        previousButton.frame = enteringFrame(NSRect(x: playerCenterX - 106, y: controlY, width: 34, height: 32), progress: controlsProgress, offset: 9)
        fullPlayPauseButton.frame = enteringFrame(NSRect(x: playerCenterX - 17, y: controlY, width: 34, height: 32), progress: controlsProgress, offset: 9)
        nextButton.frame = enteringFrame(NSRect(x: playerCenterX + 72, y: controlY, width: 34, height: 32), progress: controlsProgress, offset: 9)
        outputButton.frame = enteringFrame(NSRect(x: right - 72, y: controlY, width: 32, height: 32), progress: controlsProgress, offset: 9)

        fullTitleLabel.alphaValue = metadataProgress
        artistLabel.alphaValue = metadataProgress
        elapsedLabel.alphaValue = timelineProgress
        progressSlider.alphaValue = timelineProgress
        remainingLabel.alphaValue = timelineProgress
        [queueButton, previousButton, fullPlayPauseButton, nextButton, outputButton]
            .forEach { $0.alphaValue = controlsProgress }
        layoutQueuePanel(playerRight: right, top: top, bottom: bottom)
    }

    private func layoutQueuePanel(playerRight: CGFloat, top: CGFloat, bottom: CGFloat) {
        let progress = revealProgress(presentation.queueProgress, start: 0.08) * presentation.playerProgress
        let offset = 18 * (1 - progress)
        let queueRight = bounds.midX + presentation.queuePlayerWidth / 2
        let contentLeft = playerRight + 34
        let contentWidth = max(180, queueRight - contentLeft - 28)
        let headingY = top - presentation.compactHeight - 27

        queueDividerView.frame = NSRect(x: playerRight + 10, y: bottom + 14, width: 1, height: top - bottom - presentation.compactHeight - 4)
        queueHeadingLabel.frame = NSRect(x: contentLeft + offset, y: headingY, width: contentWidth, height: 24)
        queueMessageLabel.frame = NSRect(x: contentLeft + offset, y: headingY - 34, width: contentWidth, height: 22)
        queueDividerView.alphaValue = progress
        queueHeadingLabel.alphaValue = progress
        queueMessageLabel.alphaValue = progress

        for (index, row) in queueRows.enumerated() {
            let rowProgress = revealProgress(presentation.queueProgress, start: 0.18 + CGFloat(index) * 0.10)
                * presentation.playerProgress
            row.frame = NSRect(
                x: contentLeft + 18 * (1 - rowProgress),
                y: headingY - 35 - CGFloat(index) * 31,
                width: contentWidth,
                height: 29
            )
            row.alphaValue = rowProgress
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        queueButton.layer?.backgroundColor = presentation.isQueueOpen
            ? NSColor.white.withAlphaComponent(0.13).cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
    }

    private func interpolate(_ start: NSRect, _ end: NSRect, _ progress: CGFloat) -> NSRect {
        NSRect(
            x: interpolate(start.minX, end.minX, progress),
            y: interpolate(start.minY, end.minY, progress),
            width: interpolate(start.width, end.width, progress),
            height: interpolate(start.height, end.height, progress)
        )
    }

    private func enteringFrame(_ finalFrame: NSRect, progress: CGFloat, offset: CGFloat) -> NSRect {
        finalFrame.offsetBy(dx: 0, dy: offset * (1 - progress))
    }

    private func revealProgress(_ progress: CGFloat, start: CGFloat) -> CGFloat {
        let normalized = min(1, max(0, (progress - start) / (1 - start)))
        return normalized * normalized * (3 - 2 * normalized)
    }

    private func updateClipMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipMask.frame = bounds
        clipMask.path = silhouettePath().cgPath
        CATransaction.commit()
    }

    private func updateProgress(elapsed: Double, duration: Double) {
        progressSlider.maxValue = max(1, duration)
        guard !progressSlider.isUserTracking else { return }
        progressSlider.doubleValue = min(duration, max(0, elapsed))
        elapsedLabel.stringValue = formatTime(elapsed)
        remainingLabel.stringValue = "-" + formatTime(max(0, duration - elapsed))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    private func silhouettePath() -> NSBezierPath {
        let width = presentation.currentWidth
        let height = presentation.currentHeight
        let left = bounds.midX - width / 2
        let right = bounds.midX + width / 2
        let top = bounds.maxY
        let bottom = top - height
        let compactShoulder = min(28, presentation.hoverHeight * 0.42)
        let compactRadius = min(26, presentation.hoverHeight * 0.38)
        let shoulder = interpolate(compactShoulder, 26, presentation.playerProgress)
        let radius = interpolate(compactRadius, 30, presentation.playerProgress)
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

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}

private final class PlayerControlButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
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

private final class QueueTrackRowView: NSView {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let addIconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 7
        artworkView.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        artistLabel.font = .systemFont(ofSize: 12, weight: .regular)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        addIconView.image = NSImage(
            systemSymbolName: "text.badge.plus",
            accessibilityDescription: "Queued track"
        )?.withSymbolConfiguration(config)
        addIconView.contentTintColor = .secondaryLabelColor
        addIconView.imageScaling = .scaleProportionallyDown

        [artworkView, titleLabel, artistLabel, addIconView].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with track: QueuedTrack) {
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artist
        artworkView.image = track.artwork ?? NSImage(
            systemSymbolName: "music.note",
            accessibilityDescription: "Track artwork"
        )
        artworkView.contentTintColor = track.artwork == nil ? .white : nil
        artworkView.layer?.backgroundColor = track.artwork == nil
            ? NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
            : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        artworkView.frame = NSRect(x: 0, y: 1, width: 27, height: 27)
        addIconView.frame = NSRect(x: bounds.width - 22, y: 5, width: 20, height: 20)
        let textWidth = max(40, bounds.width - 66)
        titleLabel.frame = NSRect(x: 38, y: 14, width: textWidth, height: 16)
        artistLabel.frame = NSRect(x: 38, y: 0, width: textWidth, height: 15)
    }
}

private final class ResponsiveSlider: NSSlider {
    var onEditingEnded: ((Double) -> Void)?
    private(set) var isUserTracking = false

    override func mouseDown(with event: NSEvent) {
        isUserTracking = true
        super.mouseDown(with: event)
        isUserTracking = false
        onEditingEnded?(doubleValue)
    }
}

private final class PlayerSliderCell: NSSliderCell {
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

private final class BrightnessLevelView: NSView {
    var level: Double = 0.5 {
        didSet { needsDisplay = true }
    }
    var fillColor = NSColor(calibratedRed: 1, green: 0.82, blue: 0.03, alpha: 1) {
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

private final class AppKitWaveformView: NSView {
    private let ratios: [CGFloat] = [0.16, 0.44, 0.82, 0.54, 1.0, 0.62, 0.22]
    private var timer: Timer?
    private var displayedColor = NSColor(calibratedRed: 0.38, green: 0.55, blue: 1, alpha: 1)
    private var targetColor = NSColor(calibratedRed: 0.38, green: 0.55, blue: 1, alpha: 1)
    var isAnimating = true {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.advanceColorTransition()
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    func transition(to color: NSColor) {
        targetColor = color.usingColorSpace(.sRGB) ?? color
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let barWidth: CGFloat = 3
        let spacing = (bounds.width - barWidth * CGFloat(ratios.count)) / CGFloat(ratios.count - 1)
        let time = Date.timeIntervalSinceReferenceDate
        displayedColor.setFill()

        for (index, ratio) in ratios.enumerated() {
            let pulse = isAnimating
                ? 0.68 + 0.32 * abs(sin(time * 4.5 + Double(index) * 0.9))
                : 0.74
            let height = max(3, bounds.height * ratio * pulse)
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + spacing),
                y: bounds.midY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func advanceColorTransition() {
        guard let current = displayedColor.usingColorSpace(.sRGB),
              let target = targetColor.usingColorSpace(.sRGB) else {
            displayedColor = targetColor
            return
        }
        let amount: CGFloat = 0.08
        displayedColor = NSColor(
            calibratedRed: current.redComponent + (target.redComponent - current.redComponent) * amount,
            green: current.greenComponent + (target.greenComponent - current.greenComponent) * amount,
            blue: current.blueComponent + (target.blueComponent - current.blueComponent) * amount,
            alpha: 1
        )
    }
}

enum SystemHUDKind {
    case brightness
    case volume
}

final class NotchPresentationModel: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var expansionProgress: CGFloat = 0
    @Published private(set) var showsMediaDetails = false
    @Published private(set) var isPlayerOpen = false
    @Published private(set) var playerProgress: CGFloat = 0
    @Published private(set) var isQueueOpen = false
    @Published private(set) var queueProgress: CGFloat = 0
    @Published private(set) var brightnessProgress: CGFloat = 0
    @Published private(set) var brightnessLevel: Double = 0.5
    @Published private(set) var systemHUDKind: SystemHUDKind = .brightness
    @Published private(set) var systemHUDIsMuted = false
    @Published var compactWidth: CGFloat = 310
    @Published var compactHeight: CGFloat = 32
    @Published var hardwareNotchWidth: CGFloat = 186
    private var animationTimer: Timer?
    private var playerAnimationTimer: Timer?
    private var queueAnimationTimer: Timer?
    private var brightnessAnimationTimer: Timer?
    private var brightnessHideWorkItem: DispatchWorkItem?

    var expandedWidth: CGFloat { compactWidth + 72 }
    var expandedHeight: CGFloat { compactHeight + 18 }
    let fullPlayerWidth: CGFloat = 520
    let fullPlayerHeight: CGFloat = 165
    let queuePlayerWidth: CGFloat = 900
    var brightnessHUDWidth: CGFloat { min(600, max(560, hardwareNotchWidth + 380)) }
    var brightnessHUDHeight: CGFloat { compactHeight }
    var hoverWidth: CGFloat { interpolate(compactWidth, expandedWidth) }
    var hoverHeight: CGFloat { interpolate(compactHeight, expandedHeight) }
    private var expandedPlayerWidth: CGFloat {
        fullPlayerWidth + (queuePlayerWidth - fullPlayerWidth) * queueProgress
    }
    private var playerWidth: CGFloat { hoverWidth + (expandedPlayerWidth - hoverWidth) * playerProgress }
    private var playerHeight: CGFloat { hoverHeight + (fullPlayerHeight - hoverHeight) * playerProgress }
    var currentWidth: CGFloat { playerWidth + (brightnessHUDWidth - playerWidth) * brightnessProgress }
    var currentHeight: CGFloat { playerHeight + (brightnessHUDHeight - playerHeight) * brightnessProgress }
    var isSystemHUDVisible: Bool { brightnessProgress > 0.001 || brightnessHideWorkItem != nil }

    deinit {
        animationTimer?.invalidate()
        playerAnimationTimer?.invalidate()
        queueAnimationTimer?.invalidate()
        brightnessAnimationTimer?.invalidate()
        brightnessHideWorkItem?.cancel()
    }

    func setExpanded(_ expanded: Bool) {
        guard !isSystemHUDVisible else { return }
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        animationTimer?.invalidate()

        let start = expansionProgress
        let target: CGFloat = expanded ? 1 : 0
        let distance = abs(target - start)
        let fullDuration = expanded ? 0.22 : 0.10
        let duration = max(0.06, fullDuration * Double(distance))
        let startedAt = Date.timeIntervalSinceReferenceDate

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date.timeIntervalSinceReferenceDate - startedAt
            let linear = min(1, elapsed / duration)
            let eased = linear * linear * (3 - 2 * linear)
            self.expansionProgress = start + (target - start) * CGFloat(eased)
            if linear >= 1 {
                self.expansionProgress = target
                timer.invalidate()
                self.animationTimer = nil
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setMediaDetailsVisible(_ visible: Bool) {
        guard visible != showsMediaDetails else { return }
        showsMediaDetails = visible
    }

    func setPlayerOpen(_ open: Bool) {
        guard !isSystemHUDVisible else { return }
        guard open != isPlayerOpen else { return }
        animationTimer?.invalidate()
        playerAnimationTimer?.invalidate()
        queueAnimationTimer?.invalidate()
        if !open {
            isQueueOpen = false
            queueProgress = 0
        }
        expansionProgress = open ? 1 : 0
        isExpanded = open
        showsMediaDetails = false
        isPlayerOpen = open

        let start = playerProgress
        let target: CGFloat = open ? 1 : 0
        let distance = abs(target - start)
        let fullDuration = open ? 0.28 : 0.20
        let duration = max(0.10, fullDuration * Double(distance))
        let startedAt = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date.timeIntervalSinceReferenceDate - startedAt
            let linear = min(1, elapsed / duration)
            let eased = 1 - pow(1 - linear, 3)
            self.playerProgress = start + (target - start) * CGFloat(eased)
            if linear >= 1 {
                self.playerProgress = target
                timer.invalidate()
                self.playerAnimationTimer = nil
            }
        }
        playerAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setQueueOpen(_ open: Bool) {
        guard isPlayerOpen, open != isQueueOpen else { return }
        isQueueOpen = open
        queueAnimationTimer?.invalidate()
        let start = queueProgress
        let target: CGFloat = open ? 1 : 0
        let distance = abs(target - start)
        let duration = max(0.09, (open ? 0.26 : 0.18) * Double(distance))
        let startedAt = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let linear = min(1, (Date.timeIntervalSinceReferenceDate - startedAt) / duration)
            let eased = 1 - pow(1 - linear, 3)
            self.queueProgress = start + (target - start) * CGFloat(eased)
            if linear >= 1 {
                self.queueProgress = target
                timer.invalidate()
                self.queueAnimationTimer = nil
            }
        }
        queueAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func showBrightness(_ level: Double) {
        showSystemHUD(kind: .brightness, level: level, isMuted: false)
    }

    func showVolume(_ level: Double, isMuted: Bool) {
        showSystemHUD(kind: .volume, level: isMuted ? 0 : level, isMuted: isMuted)
    }

    private func showSystemHUD(kind: SystemHUDKind, level: Double, isMuted: Bool) {
        systemHUDKind = kind
        systemHUDIsMuted = isMuted
        brightnessLevel = min(1, max(0, level))
        brightnessHideWorkItem?.cancel()

        animationTimer?.invalidate()
        playerAnimationTimer?.invalidate()
        queueAnimationTimer?.invalidate()
        expansionProgress = 0
        isExpanded = false
        showsMediaDetails = false
        isPlayerOpen = false
        playerProgress = 0
        isQueueOpen = false
        queueProgress = 0

        if brightnessProgress < 1 {
            animateBrightness(to: 1, duration: 0.15)
        }

        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.brightnessHideWorkItem = nil
            self.animateBrightness(to: 0, duration: 0.18)
        }
        brightnessHideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: hide)
    }

    private func animateBrightness(to target: CGFloat, duration: TimeInterval) {
        brightnessAnimationTimer?.invalidate()
        let start = brightnessProgress
        let distance = abs(target - start)
        guard distance > 0.001 else {
            brightnessProgress = target
            return
        }
        let actualDuration = max(0.06, duration * Double(distance))
        let startedAt = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let linear = min(1, (Date.timeIntervalSinceReferenceDate - startedAt) / actualDuration)
            let eased = linear * linear * (3 - 2 * linear)
            self.brightnessProgress = start + (target - start) * CGFloat(eased)
            if linear >= 1 {
                self.brightnessProgress = target
                timer.invalidate()
                self.brightnessAnimationTimer = nil
            }
        }
        brightnessAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
        start + (end - start) * expansionProgress
    }
}
