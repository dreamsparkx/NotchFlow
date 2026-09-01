import AppKit
import Combine
import CoreAudio

/// Draws the silhouette in native AppKit coordinates. This avoids SwiftUI's
/// automatic camera-safe-area padding changing the visible height.
final class NowPlayingNotchAppView: NotchAppView {
    private let presentation: NotchPresentationModel
    private let nowPlaying: NowPlayingModel
    private let artworkView = NSImageView()
    private let waveformView = AppKitWaveformView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pauseButton = PlayerControlButton()
    private let fullTitleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let qualityBadgeLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")
    private let progressSlider = ResponsiveSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let shuffleButton = PlayerControlButton()
    private let previousButton = PlayerControlButton()
    private let fullPlayPauseButton = PlayerControlButton()
    private let nextButton = PlayerControlButton()
    private let outputButton = PlayerControlButton()
    private let systemHUDView = SystemHUDView()
    private let clipMask = CAShapeLayer()
    private var cancellables = Set<AnyCancellable>()

    override var hasContent: Bool { nowPlaying.hasTrack }

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
        addSubview(systemHUDView)

        Publishers.CombineLatest(nowPlaying.$hasTrack, nowPlaying.$artwork)
            .receive(on: RunLoop.main)
            .sink { [weak self] hasTrack, artwork in
                self?.artworkView.image = artwork ?? Self.emptyArtworkImage
                self?.artworkView.setAccessibilityLabel(hasTrack ? "Album artwork" : "Nothing playing")
                self?.artworkView.contentTintColor = nil
                self?.artworkView.layer?.backgroundColor = NSColor.clear.cgColor
            }
            .store(in: &cancellables)

        nowPlaying.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                let symbol = isPlaying ? "pause.fill" : "play.fill"
                let description = isPlaying ? "Pause" : "Play"
                self?.pauseButton.image = self?.configuredSymbol(symbol, description: description, pointSize: 13)
                self?.fullPlayPauseButton.image = self?.configuredSymbol(symbol, description: description, pointSize: 24)
                self?.waveformView.isAnimating = isPlaying
            }
            .store(in: &cancellables)

        nowPlaying.$isShuffleEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.shuffleButton.setSelectionHighlighted(isEnabled)
                self?.shuffleButton.toolTip = isEnabled ? "Turn Shuffle Off" : "Turn Shuffle On"
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(nowPlaying.$hasTrack, nowPlaying.$title, nowPlaying.$artist)
            .receive(on: RunLoop.main)
            .sink { [weak self] hasTrack, title, artist in
                guard let self else { return }
                self.titleLabel.stringValue = artist.isEmpty ? title : "\(title) · \(artist)"
                self.fullTitleLabel.stringValue = hasTrack ? title : "Nothing Playing"
                self.artistLabel.stringValue = hasTrack
                    ? artist
                    : "Start playback in Music or Spotify"
            }
            .store(in: &cancellables)

        nowPlaying.$playbackQuality
            .receive(on: RunLoop.main)
            .sink { [weak self] quality in
                self?.qualityBadgeLabel.stringValue = quality?.badgeText ?? ""
                self?.qualityBadgeLabel.toolTip = quality?.badgeText
                self?.needsLayout = true
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(nowPlaying.$hasTrack, presentation.$showsPrimaryDetails, presentation.$isAppOpen)
            .receive(on: RunLoop.main)
            .sink { [weak self] hasTrack, details, playerOpen in
                self?.updateMediaVisibility(hasTrack: hasTrack, details: details, playerOpen: playerOpen)
            }
            .store(in: &cancellables)

        presentation.$primaryDetailsProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateMediaVisibility(
                    hasTrack: self.nowPlaying.hasTrack,
                    details: self.presentation.showsPrimaryDetails,
                    playerOpen: self.presentation.isAppOpen
                )
                self.needsLayout = true
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

        presentation.$appOpenProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateMediaVisibility(
                    hasTrack: self.nowPlaying.hasTrack,
                    details: self.presentation.showsPrimaryDetails,
                    playerOpen: self.presentation.isAppOpen
                )
                self.needsLayout = true
            }
            .store(in: &cancellables)

        presentation.$sectionExpansionProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsLayout = true }
            .store(in: &cancellables)

        Publishers.CombineLatest(presentation.$systemHUDProgress, presentation.$systemHUDLevel)
            .receive(on: RunLoop.main)
            .sink { [weak self] progress, level in
                guard let self else { return }
                self.systemHUDView.update(
                    kind: self.presentation.systemHUDKind,
                    level: level,
                    isMuted: self.presentation.systemHUDIsMuted,
                    progress: progress
                )
                self.needsLayout = true
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(presentation.$systemHUDKind, presentation.$systemHUDIsMuted)
            .receive(on: RunLoop.main)
            .sink { [weak self] kind, isMuted in
                guard let self else { return }
                self.systemHUDView.update(
                    kind: kind,
                    level: self.presentation.systemHUDLevel,
                    isMuted: isMuted,
                    progress: self.presentation.systemHUDProgress
                )
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateClipMask()
        layoutMediaViews()
    }

    override func mouseDown(with event: NSEvent) {
        guard !presentation.isSystemHUDVisible else { return }
        guard !presentation.isAppOpen else { return }
        presentation.setAppOpen(true)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isAppActive else { return nil }
        let interactiveButtons = [pauseButton, progressSlider, shuffleButton, previousButton, fullPlayPauseButton, nextButton, outputButton]
        for view in interactiveButtons where !view.isHidden && view.alphaValue > 0.05 && view.frame.contains(point) {
            return view
        }
        return silhouettePath().contains(point) ? self : nil
    }

    override func isPointerOverPrimaryContent(_ screenPoint: NSPoint) -> Bool {
        guard isAppActive else { return false }
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        return artworkView.frame.insetBy(dx: -8, dy: -8).contains(localPoint)
            || waveformView.frame.insetBy(dx: -8, dy: -8).contains(localPoint)
            || pauseButton.frame.insetBy(dx: -8, dy: -8).contains(localPoint)
    }

    @objc private func togglePlayback() {
        guard isAppActive else { return }
        nowPlaying.togglePlayback()
    }

    @objc private func previousTrack() {
        guard isAppActive else { return }
        nowPlaying.previousTrack()
    }

    @objc private func nextTrack() {
        guard isAppActive else { return }
        nowPlaying.nextTrack()
    }

    @objc private func toggleShuffle() {
        guard isAppActive else { return }
        nowPlaying.toggleShuffle()
    }
    @objc private func showAudioOutputs(_ sender: NSButton) {
        guard isAppActive else { return }
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
        guard isAppActive else { return }
        guard let identifier = sender.representedObject as? NSNumber else { return }
        _ = AudioOutputManager.select(AudioDeviceID(identifier.uint32Value))
    }

    @objc private func openSoundSettings() {
        guard isAppActive else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func previewSeek(_ sender: NSSlider) {
        guard isAppActive else { return }
        elapsedLabel.stringValue = formatTime(sender.doubleValue)
        remainingLabel.stringValue = "-" + formatTime(max(0, sender.maxValue - sender.doubleValue))
    }

    private func updateMediaVisibility(hasTrack: Bool, details: Bool, playerOpen: Bool) {
        let detailsProgress = details || presentation.primaryDetailsProgress > 0
            ? presentation.primaryDetailsProgress
            : 0
        let compactDetailsProgress = hasTrack && !playerOpen ? detailsProgress : 0
        let appIsVisible = playerOpen || presentation.appOpenProgress > 0.001
        artworkView.isHidden = !hasTrack && !appIsVisible
        waveformView.isHidden = !hasTrack
        pauseButton.isHidden = !hasTrack
        titleLabel.isHidden = !hasTrack
        fullPlayerViews.forEach { $0.isHidden = false }
        progressSlider.isEnabled = hasTrack
        shuffleButton.isEnabled = hasTrack
        previousButton.isEnabled = hasTrack
        // Play remains available in the empty state and starts Apple Music.
        fullPlayPauseButton.isEnabled = true
        nextButton.isEnabled = hasTrack
        outputButton.isEnabled = true
        waveformView.alphaValue = hasTrack ? (playerOpen ? 1 : 1 - compactDetailsProgress) : 0
        pauseButton.alphaValue = compactDetailsProgress
        titleLabel.alphaValue = compactDetailsProgress
        needsLayout = true
    }

    private func layoutMediaViews() {
        let progress = presentation.expansionProgress
        let width = presentation.hoverWidth
        let height = presentation.hoverHeight
        let compactArtwork = max(16, presentation.compactHeight - 22)
        let artworkSize = interpolate(compactArtwork, compactArtwork + 1, progress)
        let artworkPadding = interpolate(18, 26, progress)
        let waveformPadding = interpolate(18, 22, progress)
        let waveWidth = interpolate(18, 20, progress)
        let compactWaveHeight = max(5, presentation.compactHeight - 34)
        let waveHeight = interpolate(compactWaveHeight, compactWaveHeight + 1, progress)
        // Detail expansion grows downward for the title. Keep the side media
        // centered in the original notch band instead of letting it drift.
        let mediaBandHeight = interpolate(
            presentation.compactHeight,
            presentation.expandedHeight,
            progress
        )
        let centerY = bounds.maxY - mediaBandHeight / 2
        let left = bounds.midX - width / 2
        let right = bounds.midX + width / 2

        let compactArtworkFrame = NSRect(
            x: left + artworkPadding,
            y: centerY - artworkSize / 2,
            width: artworkSize,
            height: artworkSize
        )
        let compactWaveformFrame = NSRect(
            x: right - waveformPadding - waveWidth,
            y: centerY - waveHeight / 2,
            width: waveWidth,
            height: waveHeight
        )
        artworkView.frame = compactArtworkFrame
        artworkView.layer?.cornerRadius = interpolate(6, 8, progress)
        waveformView.frame = compactWaveformFrame
        let playbackButtonSize: CGFloat = 22
        pauseButton.frame = NSRect(
            x: right - waveformPadding - playbackButtonSize,
            y: centerY - playbackButtonSize / 2,
            width: playbackButtonSize,
            height: playbackButtonSize
        )
        titleLabel.frame = NSRect(
            x: bounds.midX - min(260, width - 140) / 2,
            y: bounds.maxY - height + 4,
            width: min(260, width - 140),
            height: 18
        )

        // Always run the zero-progress layout too. It clears every full-player
        // control after an interruption such as the brightness HUD.
        layoutFullPlayer(fromArtwork: compactArtworkFrame, fromWaveform: compactWaveformFrame)
        layoutSystemHUD()
    }

    private var fullPlayerViews: [NSView] {
        [fullTitleLabel, artistLabel, qualityBadgeLabel, elapsedLabel, remainingLabel, progressSlider,
         shuffleButton, previousButton, fullPlayPauseButton, nextButton, outputButton]
    }

    private func configureFullPlayerControls() {
        fullTitleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        fullTitleLabel.textColor = .white
        fullTitleLabel.lineBreakMode = .byTruncatingTail
        artistLabel.font = .systemFont(ofSize: 12, weight: .medium)
        artistLabel.textColor = .secondaryLabelColor
        qualityBadgeLabel.font = .systemFont(ofSize: 7, weight: .bold)
        qualityBadgeLabel.textColor = .secondaryLabelColor
        qualityBadgeLabel.alignment = .left
        qualityBadgeLabel.lineBreakMode = .byClipping
        [elapsedLabel, remainingLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            $0.textColor = .secondaryLabelColor
        }

        progressSlider.target = self
        progressSlider.action = #selector(previewSeek(_:))
        progressSlider.isContinuous = true
        progressSlider.controlSize = .small
        progressSlider.cell = PlayerSliderCell()
        progressSlider.onEditingEnded = { [weak self] value in
            guard let self, self.isAppActive else { return }
            self.nowPlaying.seek(to: value)
        }

        configureButton(shuffleButton, symbol: "shuffle", pointSize: 17, action: #selector(toggleShuffle))
        shuffleButton.toolTip = "Turn Shuffle On"
        configureButton(previousButton, symbol: "backward.fill", pointSize: 19, action: #selector(previousTrack))
        configureButton(fullPlayPauseButton, symbol: "pause.fill", pointSize: 24, action: #selector(togglePlayback))
        configureButton(nextButton, symbol: "forward.fill", pointSize: 19, action: #selector(nextTrack))
        configureButton(outputButton, symbol: "airplayaudio", pointSize: 19, action: #selector(showAudioOutputs(_:)))
        outputButton.toolTip = "Choose audio output"

        fullPlayerViews.forEach { view in
            view.alphaValue = 0
            view.isHidden = true
            addSubview(view)
        }
    }

    private func layoutSystemHUD() {
        systemHUDView.layoutHUD(
            in: bounds,
            visibleWidth: presentation.currentWidth,
            visibleHeight: presentation.currentHeight,
            hardwareNotchWidth: presentation.hardwareNotchWidth,
            animationProgress: presentation.systemHUDProgress
        )
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
        let progress = presentation.appOpenProgress
        let metadataProgress = revealProgress(progress, start: 0.22)
        let timelineProgress = revealProgress(progress, start: 0.34)
        let controlsProgress = revealProgress(progress, start: 0.44)
        let width = presentation.openAppWidth
        let height = presentation.openAppHeight
        let playerCenterX = bounds.midX
        let left = playerCenterX - width / 2
        let right = playerCenterX + width / 2
        let top = bounds.maxY
        let bottom = top - height

        // Keep side content clear of the silhouette's 26-point shoulders.
        let fullArtwork = NSRect(x: left + 48, y: top - 116, width: 64, height: 64)
        let fullWaveform = NSRect(x: right - 72, y: top - 76, width: 28, height: 12)
        let titleY = top - 85
        let artistY = titleY - 20
        artworkView.frame = interpolate(compactArtwork, fullArtwork, progress)
        artworkView.layer?.cornerRadius = interpolate(8, 12, progress)
        waveformView.frame = interpolate(compactWaveform, fullWaveform, progress)
        fullTitleLabel.frame = enteringFrame(
            NSRect(x: left + 126, y: titleY, width: 190, height: 23),
            progress: metadataProgress,
            offset: 12
        )
        artistLabel.frame = enteringFrame(
            NSRect(x: left + 126, y: artistY, width: 190, height: 18),
            progress: metadataProgress,
            offset: 12
        )
        qualityBadgeLabel.frame = enteringFrame(
            NSRect(x: left + 126, y: artistY - 14, width: 90, height: 11),
            progress: metadataProgress,
            offset: 12
        )

        let timelineY = bottom + 64
        elapsedLabel.frame = enteringFrame(
            NSRect(x: left + 40, y: timelineY, width: 54, height: 19),
            progress: timelineProgress,
            offset: 10
        )
        let finalSliderFrame = NSRect(x: left + 88, y: timelineY, width: width - 176, height: 19)
        let compressedSliderFrame = finalSliderFrame.insetBy(dx: 34, dy: 0).offsetBy(dx: 0, dy: 10)
        progressSlider.frame = interpolate(compressedSliderFrame, finalSliderFrame, timelineProgress)
        remainingLabel.frame = enteringFrame(
            NSRect(x: right - 94, y: timelineY, width: 54, height: 19),
            progress: timelineProgress,
            offset: 10
        )
        remainingLabel.alignment = .right

        let controlY = bottom + 14
        shuffleButton.frame = enteringFrame(NSRect(x: playerCenterX - 138, y: controlY, width: 36, height: 36), progress: controlsProgress, offset: 9)
        previousButton.frame = enteringFrame(NSRect(x: playerCenterX - 77, y: controlY, width: 38, height: 36), progress: controlsProgress, offset: 9)
        fullPlayPauseButton.frame = enteringFrame(NSRect(x: playerCenterX - 20, y: controlY - 2, width: 40, height: 40), progress: controlsProgress, offset: 9)
        nextButton.frame = enteringFrame(NSRect(x: playerCenterX + 39, y: controlY, width: 38, height: 36), progress: controlsProgress, offset: 9)
        outputButton.frame = enteringFrame(NSRect(x: playerCenterX + 102, y: controlY, width: 36, height: 36), progress: controlsProgress, offset: 9)

        fullTitleLabel.alphaValue = metadataProgress
        artistLabel.alphaValue = metadataProgress
        qualityBadgeLabel.alphaValue = nowPlaying.playbackQuality == nil ? 0 : metadataProgress
        elapsedLabel.alphaValue = timelineProgress
        progressSlider.alphaValue = timelineProgress
        remainingLabel.alphaValue = timelineProgress
        [shuffleButton, previousButton, fullPlayPauseButton, nextButton, outputButton]
            .forEach { $0.alphaValue = controlsProgress }
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
        NotchSilhouette.path(in: bounds, presentation: presentation)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private static let emptyArtworkImage = NSImage(
        size: NSSize(width: 256, height: 256),
        flipped: false
    ) { rect in
        let background = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.22, alpha: 1),
            NSColor(calibratedRed: 0.24, green: 0.18, blue: 0.55, alpha: 1),
            NSColor(calibratedRed: 0.18, green: 0.47, blue: 0.76, alpha: 1)
        ])?.draw(in: background, angle: -38)

        NSColor(calibratedWhite: 1, alpha: 0.09).setFill()
        NSBezierPath(ovalIn: NSRect(x: 108, y: 94, width: 176, height: 176)).fill()
        NSColor(calibratedWhite: 1, alpha: 0.055).setFill()
        NSBezierPath(ovalIn: NSRect(x: -42, y: -34, width: 190, height: 190)).fill()

        let barHeights: [CGFloat] = [30, 58, 90, 62, 36]
        let barWidth: CGFloat = 16
        let spacing: CGFloat = 12
        let totalWidth = CGFloat(barHeights.count) * barWidth
            + CGFloat(barHeights.count - 1) * spacing
        var x = rect.midX - totalWidth / 2

        NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
        for height in barHeights {
            let bar = NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + spacing
        }
        return true
    }
}
