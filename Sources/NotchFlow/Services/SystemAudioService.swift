import AudioToolbox
import CoreAudio

enum SystemVolume {
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
