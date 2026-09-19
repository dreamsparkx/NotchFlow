import AppKit
import CoreAudio
import Darwin

struct ActiveAudioSource {
    let processID: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
}

extension Notification.Name {
    static let notchFlowAudioSourceSelectionDidChange = Notification.Name(
        "NotchFlowAudioSourceSelectionDidChange"
    )
}

final class AudioSourceSelection {
    static let shared = AudioSourceSelection()

    private let lock = NSLock()
    private var selectedSource: ActiveAudioSource?
    private var terminationObserver: NSObjectProtocol?

    var isAutomatic: Bool {
        lock.withLock { selectedSource == nil }
    }

    var selectedBundleIdentifier: String? {
        lock.withLock { selectedSource?.bundleIdentifier }
    }

    var source: ActiveAudioSource? {
        lock.withLock { selectedSource }
    }

    var selectedIdentifier: String? {
        lock.withLock {
            selectedSource.map { $0.bundleIdentifier ?? "pid:\($0.processID)" }
        }
    }

    private init() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let shouldFallBack = self.lock.withLock {
                guard let selectedSource = self.selectedSource else { return false }
                return selectedSource.processID == application.processIdentifier
                    || selectedSource.bundleIdentifier == application.bundleIdentifier
            }
            if shouldFallBack { self.selectAutomatic() }
        }
    }

    deinit {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
    }

    func selectAutomatic() {
        let changed = lock.withLock {
            guard selectedSource != nil else { return false }
            selectedSource = nil
            return true
        }
        if changed { notifySelectionChanged() }
    }

    func select(_ source: ActiveAudioSource) {
        lock.withLock { selectedSource = source }
        notifySelectionChanged()
    }

    private func notifySelectionChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .notchFlowAudioSourceSelectionDidChange, object: self)
        }
    }
}

enum AudioSourceService {
    static func activeSources(completion: @escaping ([ActiveAudioSource]) -> Void) {
        let coreAudioSources = coreAudioSources()
        MediaRemoteAudioSourceProvider.shared.activeSources { mediaSources in
            var merged: [String: ActiveAudioSource] = [:]
            for source in coreAudioSources + mediaSources {
                let identifier = source.bundleIdentifier ?? "pid:\(source.processID)"
                merged[identifier] = source
            }
            completion(merged.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })
        }
    }

    static func automaticSource(completion: @escaping (ActiveAudioSource?) -> Void) {
        let audibleSources = coreAudioSources()
        let mostRecentlyActivatedSource = AudioActivityTracker.shared.update(with: audibleSources)
        MediaRemoteAudioSourceProvider.shared.currentSource { mediaRemoteSource in
            guard let mediaRemoteSource else {
                completion(mostRecentlyActivatedSource ?? audibleSources.first)
                return
            }

            let mediaIdentifier = identifier(for: mediaRemoteSource)
            let mediaSourceIsAudible = audibleSources.contains {
                identifier(for: $0) == mediaIdentifier
            }

            // MediaRemote can leave a stopped browser marked as its current
            // client. If exactly one different app is actually producing
            // output, that app owns the live playback context and the global
            // media keys. Scriptable players are allowed to remain selected
            // while paused so Play still resumes the same track.
            let isScriptablePlayer = mediaRemoteSource.bundleIdentifier == "com.apple.Music"
                || mediaRemoteSource.bundleIdentifier == "com.spotify.client"
            if !isScriptablePlayer,
               let activeSource = mostRecentlyActivatedSource,
               (!mediaSourceIsAudible || identifier(for: activeSource) != mediaIdentifier) {
                completion(activeSource)
            } else {
                completion(mediaRemoteSource)
            }
        }
    }

    static func currentlyAudibleSource() -> ActiveAudioSource? {
        coreAudioSources().first
    }

    private static func identifier(for source: ActiveAudioSource) -> String {
        source.bundleIdentifier ?? "pid:\(source.processID)"
    }

    private static func coreAudioSources() -> [ActiveAudioSource] {
        let runningApplications = NSWorkspace.shared.runningApplications
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        var sourcesByIdentifier: [String: ActiveAudioSource] = [:]

        for processObject in audioProcessObjects() where isProducingOutput(processObject) {
            guard let processID = processID(for: processObject) else { continue }

            let processApplication = NSRunningApplication(processIdentifier: processID)
            let processBundleIdentifier = bundleIdentifier(for: processObject)
                ?? processApplication?.bundleIdentifier
            let owningApplication = regularApplication(
                for: processID,
                bundleIdentifier: processBundleIdentifier,
                among: runningApplications
            )
            let resolvedBundleIdentifier = owningApplication?.bundleIdentifier ?? processBundleIdentifier
            guard resolvedBundleIdentifier != currentBundleIdentifier else { continue }

            let name = owningApplication?.localizedName
                ?? processApplication?.localizedName
                ?? resolvedBundleIdentifier
                ?? "Process \(processID)"
            let identifier = resolvedBundleIdentifier ?? "pid:\(processID)"

            sourcesByIdentifier[identifier] = ActiveAudioSource(
                processID: owningApplication?.processIdentifier ?? processID,
                name: name,
                bundleIdentifier: resolvedBundleIdentifier,
                icon: owningApplication?.icon ?? processApplication?.icon
            )
        }

        return sourcesByIdentifier.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioObjectID>.size else { return [] }

        var objects = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &objects) == noErr else {
            return []
        }
        return objects
    }

    private static func isProducingOutput(_ processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &isRunning
        ) == noErr && isRunning != 0
    }

    private static func processID(for processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &processID
        ) == noErr, processID > 0 else { return nil }
        return processID
    }

    private static func bundleIdentifier(for processObject: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleIdentifier: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &bundleIdentifier
        ) == noErr else { return nil }
        return bundleIdentifier?.takeRetainedValue() as String?
    }

    private static func regularApplication(
        for processID: pid_t,
        bundleIdentifier: String?,
        among runningApplications: [NSRunningApplication]
    ) -> NSRunningApplication? {
        var candidateProcessID = processID
        var visited = Set<pid_t>()

        // Browser audio normally originates in a renderer or audio helper.
        // Walk its parent chain until we reach the visible browser process.
        while candidateProcessID > 1, visited.insert(candidateProcessID).inserted {
            if let application = NSRunningApplication(processIdentifier: candidateProcessID),
               application.activationPolicy == .regular {
                return application
            }
            guard let parent = parentProcessID(of: candidateProcessID), parent != candidateProcessID else {
                break
            }
            candidateProcessID = parent
        }

        guard let bundleIdentifier else {
            return NSRunningApplication(processIdentifier: processID)
        }

        return runningApplications
            .filter { candidate in
                guard candidate.activationPolicy == .regular,
                      let candidateIdentifier = candidate.bundleIdentifier else { return false }
                return bundleIdentifier == candidateIdentifier
                    || bundleIdentifier.hasPrefix(candidateIdentifier + ".")
            }
            .max { lhs, rhs in
                (lhs.bundleIdentifier?.count ?? 0) < (rhs.bundleIdentifier?.count ?? 0)
            }
            ?? NSRunningApplication(processIdentifier: processID)
    }

    private static func parentProcessID(of processID: pid_t) -> pid_t? {
        var processInfo = proc_bsdinfo()
        let result = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard result == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return pid_t(processInfo.pbi_ppid)
    }
}

private final class AudioActivityTracker {
    static let shared = AudioActivityTracker()

    private let lock = NSLock()
    private var audibleIdentifiers = Set<String>()
    private var mostRecentIdentifier: String?

    func update(with sources: [ActiveAudioSource]) -> ActiveAudioSource? {
        lock.withLock {
            let sourcesByIdentifier = Dictionary(
                uniqueKeysWithValues: sources.map { source in
                    (source.bundleIdentifier ?? "pid:\(source.processID)", source)
                }
            )
            let currentIdentifiers = Set(sourcesByIdentifier.keys)
            let newlyAudible = currentIdentifiers.subtracting(audibleIdentifiers)

            if let newlyActivatedIdentifier = sources
                .map({ $0.bundleIdentifier ?? "pid:\($0.processID)" })
                .first(where: newlyAudible.contains) {
                mostRecentIdentifier = newlyActivatedIdentifier
            } else if let mostRecentIdentifier,
                      !currentIdentifiers.contains(mostRecentIdentifier) {
                self.mostRecentIdentifier = nil
            }

            audibleIdentifiers = currentIdentifiers
            if let mostRecentIdentifier,
               let source = sourcesByIdentifier[mostRecentIdentifier] {
                return source
            }
            return sources.count == 1 ? sources.first : nil
        }
    }
}

private final class MediaRemoteAudioSourceProvider {
    static let shared = MediaRemoteAudioSourceProvider()

    private typealias ClientsHandler = @convention(block) (NSArray?, NSError?) -> Void
    private typealias GetClientsFunction = @convention(c) (DispatchQueue, @escaping ClientsHandler) -> Void
    private typealias ClientHandler = @convention(block) (AnyObject?, NSError?) -> Void
    private typealias GetClientFunction = @convention(c) (DispatchQueue, @escaping ClientHandler) -> Void
    private typealias RegisterFunction = @convention(c) (DispatchQueue) -> Void
    private typealias ClientStringFunction = @convention(c) (AnyObject) -> Unmanaged<CFString>?
    private typealias ClientPIDFunction = @convention(c) (AnyObject) -> pid_t

    private let handle: UnsafeMutableRawPointer?
    private let getClients: GetClientsFunction?
    private let getCurrentClient: GetClientFunction?
    private let getBundleIdentifier: ClientStringFunction?
    private let getParentBundleIdentifier: ClientStringFunction?
    private let getDisplayName: ClientStringFunction?
    private let getProcessIdentifier: ClientPIDFunction?

    private init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL)
        guard let handle else {
            getClients = nil
            getCurrentClient = nil
            getBundleIdentifier = nil
            getParentBundleIdentifier = nil
            getDisplayName = nil
            getProcessIdentifier = nil
            return
        }

        getClients = Self.function(named: "MRMediaRemoteGetNowPlayingClients", in: handle)
        getCurrentClient = Self.function(named: "MRMediaRemoteGetNowPlayingClient", in: handle)
        getBundleIdentifier = Self.function(named: "MRNowPlayingClientGetBundleIdentifier", in: handle)
        getParentBundleIdentifier = Self.function(named: "MRNowPlayingClientGetParentAppBundleIdentifier", in: handle)
        getDisplayName = Self.function(named: "MRNowPlayingClientGetDisplayName", in: handle)
        getProcessIdentifier = Self.function(named: "MRNowPlayingClientGetProcessIdentifier", in: handle)

        if let register: RegisterFunction = Self.function(
            named: "MRMediaRemoteRegisterForNowPlayingNotifications",
            in: handle
        ) {
            register(DispatchQueue.main)
        }
    }

    func activeSources(completion: @escaping ([ActiveAudioSource]) -> Void) {
        guard let getClients else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        getClients(DispatchQueue.global(qos: .userInitiated)) { [weak self] clients, error in
            guard let self, error == nil, let clients else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let runningApplications = NSWorkspace.shared.runningApplications
            var sourcesByIdentifier: [String: ActiveAudioSource] = [:]
            for case let client as AnyObject in clients {
                guard let source = self.source(from: client, runningApplications: runningApplications) else {
                    continue
                }
                let identifier = source.bundleIdentifier ?? "pid:\(source.processID)"
                sourcesByIdentifier[identifier] = source
            }
            DispatchQueue.main.async { completion(Array(sourcesByIdentifier.values)) }
        }
    }

    func currentSource(completion: @escaping (ActiveAudioSource?) -> Void) {
        guard let getCurrentClient else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        getCurrentClient(DispatchQueue.global(qos: .userInitiated)) { [weak self] client, error in
            guard let self, error == nil, let client else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let source = self.source(
                from: client,
                runningApplications: NSWorkspace.shared.runningApplications
            )
            DispatchQueue.main.async { completion(source) }
        }
    }

    private func source(
        from client: AnyObject,
        runningApplications: [NSRunningApplication]
    ) -> ActiveAudioSource? {
        let parentBundleIdentifier = string(from: getParentBundleIdentifier, client: client)
        let bundleIdentifier = parentBundleIdentifier
            ?? string(from: getBundleIdentifier, client: client)
        let processID = getProcessIdentifier?(client) ?? 0
        let application = runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
            ?? NSRunningApplication(processIdentifier: processID)
        let name = application?.localizedName
            ?? string(from: getDisplayName, client: client)
            ?? bundleIdentifier
        guard let name, bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

        var icon = application?.icon
        if icon == nil,
           let bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        return ActiveAudioSource(
            processID: application?.processIdentifier ?? processID,
            name: name,
            bundleIdentifier: bundleIdentifier,
            icon: icon
        )
    }

    private func string(from function: ClientStringFunction?, client: AnyObject) -> String? {
        function?(client)?.takeUnretainedValue() as String?
    }

    private static func function<T>(named name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
