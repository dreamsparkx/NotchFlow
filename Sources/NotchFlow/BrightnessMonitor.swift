import AppKit
import ApplicationServices
import CoreAudio
import AudioToolbox
import CoreGraphics
import Darwin

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
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        _ = CGRequestListenEventAccess()
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

private enum DisplayBrightness {
    typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    static func get() -> Double? {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesGetBrightness") else { return nil }
        let function = unsafeBitCast(symbol, to: GetFunction.self)
        var value: Float = 0
        return function(CGMainDisplayID(), &value) == 0 ? Double(value) : nil
    }

    static func set(_ value: Double) -> Bool {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesSetBrightness") else { return false }
        let function = unsafeBitCast(symbol, to: SetFunction.self)
        return function(CGMainDisplayID(), Float(value)) == 0
    }
}

private enum SystemVolume {
    struct State {
        let level: Double
        let isMuted: Bool
    }

    static func get() -> State? {
        guard let device = defaultOutputDevice(), var address = volumeAddress(for: device) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            _ = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted)
        }
        return State(level: Double(volume), isMuted: muted != 0)
    }

    static func adjust(by delta: Double) -> State? {
        guard let current = get() else { return nil }
        let next = min(1, max(0, current.level + delta))
        guard setVolume(next) else { return nil }
        if current.isMuted { _ = setMuted(false) }
        return State(level: next, isMuted: false)
    }

    static func toggleMute() -> State? {
        guard let current = get(), setMuted(!current.isMuted) else { return nil }
        return State(level: current.level, isMuted: !current.isMuted)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func volumeAddress(for device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        let candidates = [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
        ]
        return candidates.first { candidate in
            var candidate = candidate
            return AudioObjectHasProperty(device, &candidate)
        }
    }

    private static func setVolume(_ level: Double) -> Bool {
        guard let device = defaultOutputDevice(), var address = volumeAddress(for: device) else { return false }
        var value = Float32(level)
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        ) == noErr
    }

    private static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }
}

struct AudioOutputDevice {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
}

enum AudioOutputManager {
    static func availableDevices() -> [AudioOutputDevice] {
        guard let current = defaultOutputDevice() else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        var devices = Array(
            repeating: AudioDeviceID(0),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }

        return devices.compactMap { device in
            guard hasOutputStreams(device), let name = deviceName(device) else { return nil }
            return AudioOutputDevice(id: device, name: name, isDefault: device == current)
        }
        .sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    static func select(_ device: AudioDeviceID) -> Bool {
        var selectedDevice = device
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let outputResult = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, size, &selectedDevice
        )

        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &systemAddress, 0, nil, size, &selectedDevice
        )
        return outputResult == noErr
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeUnretainedValue() as String?
    }
}
