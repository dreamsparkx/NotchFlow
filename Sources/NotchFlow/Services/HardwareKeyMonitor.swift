import AppKit
import CoreGraphics

final class HardwareKeyMonitor {
    private enum HardwareKey {
        case brightness(Int)
        case volume(Int)
        case mute
    }

    private let onBrightnessChanged: (Double) -> Void
    private let onVolumeChanged: (Double, Bool) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var permissionRetryTimer: Timer?

    init(
        onBrightnessChanged: @escaping (Double) -> Void,
        onVolumeChanged: @escaping (Double, Bool) -> Void
    ) {
        self.onBrightnessChanged = onBrightnessChanged
        self.onVolumeChanged = onVolumeChanged
    }

    deinit { stop() }

    func start() {
        guard !installEventTap() else { return }
        installFallbackMonitor()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.installEventTap() else { return }
            self.removeFallbackMonitor()
            timer.invalidate()
            self.permissionRetryTimer = nil
        }
        permissionRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installFallbackMonitor() {
        guard fallbackMonitor == nil else { return }
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, let key = self.hardwareKey(from: event) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                switch key {
                case .brightness:
                    guard let level = DisplayBrightness.get() else { return }
                    self.onBrightnessChanged(level)
                case .volume, .mute:
                    guard let state = SystemVolume.get() else { return }
                    self.onVolumeChanged(state.level, state.isMuted)
                }
            }
        }
    }

    private func removeFallbackMonitor() {
        if let fallbackMonitor { NSEvent.removeMonitor(fallbackMonitor) }
        fallbackMonitor = nil
    }

    private func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        removeFallbackMonitor()
        permissionRetryTimer?.invalidate()
    }

    private func installEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HardwareKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let nsEvent = NSEvent(cgEvent: event), let key = monitor.hardwareKey(from: nsEvent) else {
                return Unmanaged.passUnretained(event)
            }

            let fine = nsEvent.modifierFlags.contains(.option) && nsEvent.modifierFlags.contains(.shift)
            let step = fine ? 1.0 / 64.0 : 1.0 / 16.0

            switch key {
            case .brightness(let direction):
                let current = DisplayBrightness.get() ?? 0.5
                let next = min(1, max(0, current + Double(direction) * step))
                guard DisplayBrightness.set(next) else { return Unmanaged.passUnretained(event) }
                DispatchQueue.main.async { monitor.onBrightnessChanged(next) }
            case .volume(let direction):
                guard let state = SystemVolume.adjust(by: Double(direction) * step) else {
                    return Unmanaged.passUnretained(event)
                }
                DispatchQueue.main.async { monitor.onVolumeChanged(state.level, state.isMuted) }
            case .mute:
                guard let state = SystemVolume.toggleMute() else {
                    return Unmanaged.passUnretained(event)
                }
                DispatchQueue.main.async { monitor.onVolumeChanged(state.level, state.isMuted) }
            }
            return nil
        }

        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let locations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]
        guard let tap = locations.lazy.compactMap({ location in
            CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: pointer
            )
        }).first else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func hardwareKey(from event: NSEvent) -> HardwareKey? {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return nil }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        let keyState = ((event.data1 & 0x0000FFFF) & 0xFF00) >> 8
        guard keyState == 0xA else { return nil }
        switch keyCode {
        case 0: return .volume(1)
        case 1: return .volume(-1)
        case 2: return .brightness(1)
        case 3: return .brightness(-1)
        case 7: return .mute
        default: return nil
        }
    }
}
