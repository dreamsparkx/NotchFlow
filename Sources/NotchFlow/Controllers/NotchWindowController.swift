import AppKit
import Combine

final class NotchWindowController: NSWindowController {
    private let notchApp: any NotchApp
    private let presentation = NotchPresentationModel()
    private var hoverTimer: Timer?
    private var collapseWorkItem: DispatchWorkItem?
    private var pointerIsInside = false
    private var notchContentView: NotchAppView!
    private var cancellables = Set<AnyCancellable>()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var hardwareKeyMonitor: HardwareKeyMonitor?

    init(notchApp: any NotchApp = MusicNotchApp()) {
        self.notchApp = notchApp
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
        let contentView = notchApp.makeView(presentation: presentation)
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

        presentation.$isAppOpen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isOpen in
                if isOpen { self?.resizeWindow(forApp: true) }
            }
            .store(in: &cancellables)

        presentation.$appOpenProgress
            .removeDuplicates()
            .filter { [weak self] progress in progress <= 0 && self?.presentation.isAppOpen == false }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeWindow(forApp: false) }
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
            if self.presentation.isAppOpen || self.presentation.isSystemHUDVisible {
                self.presentation.setPrimaryDetailsVisible(false)
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
            self.presentation.setPrimaryDetailsVisible(
                self.notchContentView.isPointerOverPrimaryContent(NSEvent.mouseLocation)
                    && self.notchContentView.hasContent
            )
        }
    }

    private func resizeWindow(forApp isOpen: Bool) {
        guard let panel = window, let screen = panel.screen ?? NSScreen.main else { return }
        let size = isOpen ? NSSize(width: 620, height: 195) : NSSize(width: 620, height: 90)
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
            DispatchQueue.main.async { self?.presentation.setAppOpen(false) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if self?.presentation.isAppOpen == true, event.window !== self?.window {
                self?.presentation.setAppOpen(false)
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
