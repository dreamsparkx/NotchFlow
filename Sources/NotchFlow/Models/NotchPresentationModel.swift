import AppKit
import Combine

enum SystemHUDKind {
    case brightness
    case volume
}

final class NotchPresentationModel: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var expansionProgress: CGFloat = 0
    @Published private(set) var showsPrimaryDetails = false
    @Published private(set) var isAppOpen = false
    @Published private(set) var appOpenProgress: CGFloat = 0
    @Published private(set) var systemHUDProgress: CGFloat = 0
    @Published private(set) var systemHUDLevel: Double = 0.5
    @Published private(set) var systemHUDKind: SystemHUDKind = .brightness
    @Published private(set) var systemHUDIsMuted = false
    @Published var compactWidth: CGFloat = 310
    @Published var compactHeight: CGFloat = 32
    @Published var hardwareNotchWidth: CGFloat = 186

    private var animationTimer: Timer?
    private var appOpenAnimationTimer: Timer?
    private var systemHUDAnimationTimer: Timer?
    private var systemHUDHideWorkItem: DispatchWorkItem?

    var expandedWidth: CGFloat { compactWidth + 72 }
    var expandedHeight: CGFloat { compactHeight + 18 }
    let openAppWidth: CGFloat = 520
    let openAppHeight: CGFloat = 165
    var systemHUDWidth: CGFloat { min(600, max(560, hardwareNotchWidth + 380)) }
    var systemHUDHeight: CGFloat { compactHeight }
    var hoverWidth: CGFloat { interpolate(compactWidth, expandedWidth) }
    var hoverHeight: CGFloat { interpolate(compactHeight, expandedHeight) }
    private var appWidth: CGFloat { hoverWidth + (openAppWidth - hoverWidth) * appOpenProgress }
    private var appHeight: CGFloat { hoverHeight + (openAppHeight - hoverHeight) * appOpenProgress }
    var currentWidth: CGFloat { appWidth + (systemHUDWidth - appWidth) * systemHUDProgress }
    var currentHeight: CGFloat { appHeight + (systemHUDHeight - appHeight) * systemHUDProgress }
    var isSystemHUDVisible: Bool { systemHUDProgress > 0.001 || systemHUDHideWorkItem != nil }

    deinit {
        animationTimer?.invalidate()
        appOpenAnimationTimer?.invalidate()
        systemHUDAnimationTimer?.invalidate()
        systemHUDHideWorkItem?.cancel()
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

    func setPrimaryDetailsVisible(_ visible: Bool) {
        guard visible != showsPrimaryDetails else { return }
        showsPrimaryDetails = visible
    }

    func setAppOpen(_ open: Bool) {
        guard !isSystemHUDVisible else { return }
        guard open != isAppOpen else { return }
        animationTimer?.invalidate()
        appOpenAnimationTimer?.invalidate()
        expansionProgress = open ? 1 : 0
        isExpanded = open
        showsPrimaryDetails = false
        isAppOpen = open

        let start = appOpenProgress
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
            self.appOpenProgress = start + (target - start) * CGFloat(eased)
            if linear >= 1 {
                self.appOpenProgress = target
                timer.invalidate()
                self.appOpenAnimationTimer = nil
            }
        }
        appOpenAnimationTimer = timer
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
        systemHUDLevel = min(1, max(0, level))
        systemHUDHideWorkItem?.cancel()

        animationTimer?.invalidate()
        appOpenAnimationTimer?.invalidate()
        expansionProgress = 0
        isExpanded = false
        showsPrimaryDetails = false
        isAppOpen = false
        appOpenProgress = 0

        if systemHUDProgress < 1 {
            animateSystemHUD(to: 1, duration: 0.15)
        }

        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.systemHUDHideWorkItem = nil
            self.animateSystemHUD(to: 0, duration: 0.18)
        }
        systemHUDHideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: hide)
    }

    private func animateSystemHUD(to target: CGFloat, duration: TimeInterval) {
        systemHUDAnimationTimer?.invalidate()
        let start = systemHUDProgress
        let distance = abs(target - start)
        guard distance > 0.001 else {
            systemHUDProgress = target
            return
        }
        let actualDuration = max(0.06, duration * Double(distance))
        let startedAt = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let linear = min(1, (Date.timeIntervalSinceReferenceDate - startedAt) / actualDuration)
            let eased = linear * linear * (3 - 2 * linear)
            self.systemHUDProgress = start + (target - start) * CGFloat(eased)
            if linear >= 1 {
                self.systemHUDProgress = target
                timer.invalidate()
                self.systemHUDAnimationTimer = nil
            }
        }
        systemHUDAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
        start + (end - start) * expansionProgress
    }
}
