import AppKit
import Combine

final class NowPlayingModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isShuffleEnabled = false
    @Published private(set) var hasTrack = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accentColor = NSColor(calibratedRed: 0.38, green: 0.55, blue: 1, alpha: 1)
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0

    private let pollingQueue = DispatchQueue(label: "com.dreamsparkx.NotchFlow.now-playing", qos: .utility)
    private let commandQueue = DispatchQueue(label: "com.dreamsparkx.NotchFlow.commands", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var currentArtworkKey: String?
    private var pendingArtworkKey: String?
    private var activePlayer: Player?
    private var pendingShuffleState: Bool?
    private var isStartingDefaultPlayer = false

    private enum Player: String {
        case spotify = "Spotify"
        case music = "Music"
    }

    init() {
        refreshAsync()
        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refreshInBackground() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    private func refreshAsync() {
        pollingQueue.async { [weak self] in self?.refreshInBackground() }
    }

    private func refreshInBackground() {
        let spotify = isRunning("com.spotify.client") ? spotifyState() : nil
        if let spotify, spotify.isPlaying {
            DispatchQueue.main.async { [weak self] in self?.applySpotify(spotify) }
            return
        }

        let music = isRunning("com.apple.Music") ? musicState() : nil
        if let music, music.isPlaying {
            DispatchQueue.main.async { [weak self] in self?.applyMusic(music) }
            return
        }

        // Preserve the most recently selected player's metadata when paused.
        if let spotify {
            DispatchQueue.main.async { [weak self] in self?.applySpotify(spotify) }
            return
        }
        if let music {
            DispatchQueue.main.async { [weak self] in self?.applyMusic(music) }
            return
        }

        DispatchQueue.main.async { [weak self] in self?.clearPlayback() }
    }

    private func clearPlayback() {
        isPlaying = false
        isShuffleEnabled = false
        hasTrack = false
        artwork = nil
        accentColor = Self.fallbackAccent
        title = ""
        artist = ""
        elapsed = 0
        duration = 0
        activePlayer = nil
        currentArtworkKey = nil
        pendingArtworkKey = nil
    }

    func togglePlayback() {
        guard !isStartingDefaultPlayer else { return }
        guard let activePlayer else {
            startAppleMusicPlayback()
            return
        }
        isPlaying.toggle()
        runCommand("tell application \"\(activePlayer.rawValue)\" to playpause")
    }

    private func startAppleMusicPlayback() {
        isStartingDefaultPlayer = true
        activePlayer = .music
        isPlaying = true

        commandQueue.async { [weak self] in
            // Music accepts the launch event before its playback controller is
            // ready. Wait for that controller, then use the same `playpause`
            // command that succeeds on a user's second click. Checking state
            // first makes the retries idempotent.
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"Music\" to launch")?
                .executeAndReturnError(&error)

            Thread.sleep(forTimeInterval: 0.75)
            let playbackStarted = self?.resumeMusicIfNeeded() ?? false

            DispatchQueue.main.async {
                guard let self else { return }
                self.isStartingDefaultPlayer = false
                if error != nil || !playbackStarted {
                    self.isPlaying = false
                }
                self.refreshAsync()
            }
        }
    }

    private func resumeMusicIfNeeded() -> Bool {
        let stateSource = "tell application \"Music\" to get player state as text"
        if runScript(stateSource)?.stringValue == "playing" {
            return true
        }

        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"Music\" to playpause")?
            .executeAndReturnError(&error)
        return error == nil
    }

    func previousTrack() {
        guard let activePlayer else { return }
        runCommand("tell application \"\(activePlayer.rawValue)\" to previous track", refreshAfter: true)
    }

    func nextTrack() {
        guard let activePlayer else { return }
        runCommand("tell application \"\(activePlayer.rawValue)\" to next track", refreshAfter: true)
    }

    func toggleShuffle() {
        guard let activePlayer else { return }
        let nextValue = !isShuffleEnabled
        pendingShuffleState = nextValue
        isShuffleEnabled = nextValue
        let property = activePlayer == .music ? "shuffle enabled" : "shuffling"
        let source = "tell application \"\(activePlayer.rawValue)\" to set \(property) to \(nextValue)"
        commandQueue.async { [weak self] in
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                guard let self, self.pendingShuffleState == nextValue else { return }
                if error != nil {
                    self.pendingShuffleState = nil
                    self.isShuffleEnabled = !nextValue
                    return
                }
                // Keep the optimistic state locked until a fresh player poll
                // confirms it. An older in-flight poll must not flash the
                // previous state back onto the button.
                self.refreshAsync()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.pendingShuffleState == nextValue else { return }
                    self.pendingShuffleState = nil
                    self.refreshAsync()
                }
            }
        }
    }

    func seek(to seconds: Double) {
        guard let activePlayer, duration > 0 else { return }
        let clamped = min(duration, max(0, seconds))
        elapsed = clamped
        runCommand("tell application \"\(activePlayer.rawValue)\" to set player position to \(clamped)")
    }

    private func isRunning(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func spotifyState() -> (isPlaying: Bool, isShuffleEnabled: Bool, key: String, title: String, artist: String, artworkURL: String, elapsed: Double, duration: Double)? {
        let source = """
        tell application "Spotify"
            set currentSong to current track
            return (player state as text) & "|||" & (shuffling as text) & "|||" & (name of currentSong) & "|||" & (artist of currentSong) & "|||" & (album of currentSong) & "|||" & (artwork url of currentSong) & "|||" & (player position as text) & "|||" & ((duration of currentSong) / 1000 as text)
        end tell
        """
        guard let result = runScript(source)?.stringValue else { return nil }
        let parts = result.components(separatedBy: "|||")
        guard parts.count == 8 else { return nil }
        return (parts[0] == "playing", parts[1] == "true", parts[2...4].joined(separator: "|"), parts[2], parts[3], parts[5], Double(parts[6]) ?? 0, Double(parts[7]) ?? 0)
    }

    private func applySpotify(_ state: (isPlaying: Bool, isShuffleEnabled: Bool, key: String, title: String, artist: String, artworkURL: String, elapsed: Double, duration: Double)) {
        isPlaying = state.isPlaying
        applyShuffleState(state.isShuffleEnabled)
        hasTrack = true
        activePlayer = .spotify
        title = state.title
        artist = state.artist
        elapsed = state.elapsed
        duration = state.duration
        guard currentArtworkKey != state.key, pendingArtworkKey != state.key else { return }
        pendingArtworkKey = state.key
        artwork = nil
        accentColor = Self.fallbackAccent
        guard let url = URL(string: state.artworkURL), !state.artworkURL.isEmpty else {
            pendingArtworkKey = nil
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard self?.pendingArtworkKey == state.key else { return }
                self?.pendingArtworkKey = nil
                guard let data,
                      (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
                      let image = NSImage(data: data) else {
                    // Do not cache a failure. The regular player poll will retry.
                    return
                }
                self?.currentArtworkKey = state.key
                self?.artwork = image
                self?.accentColor = Self.dominantAccent(from: image)
            }
        }.resume()
    }

    private func musicState() -> (isPlaying: Bool, isShuffleEnabled: Bool, key: String, title: String, artist: String, elapsed: Double, duration: Double)? {
        let source = """
        tell application "Music"
            set currentSong to current track
            return (player state as text) & "|||" & (shuffle enabled as text) & "|||" & (name of currentSong) & "|||" & (artist of currentSong) & "|||" & (album of currentSong) & "|||" & (player position as text) & "|||" & (duration of currentSong as text)
        end tell
        """
        guard let result = runScript(source)?.stringValue else { return nil }
        let parts = result.components(separatedBy: "|||")
        guard parts.count == 7 else { return nil }
        return (parts[0] == "playing", parts[1] == "true", parts[2...4].joined(separator: "|"), parts[2], parts[3], Double(parts[5]) ?? 0, Double(parts[6]) ?? 0)
    }

    private func applyMusic(_ state: (isPlaying: Bool, isShuffleEnabled: Bool, key: String, title: String, artist: String, elapsed: Double, duration: Double)) {
        isPlaying = state.isPlaying
        applyShuffleState(state.isShuffleEnabled)
        hasTrack = true
        activePlayer = .music
        title = state.title
        artist = state.artist
        elapsed = state.elapsed
        duration = state.duration
        guard currentArtworkKey != state.key else { return }

        let source = "tell application \"Music\" to get data of artwork 1 of current track"
        guard let descriptor = runScript(source),
              let image = NSImage(data: descriptor.data) else {
            artwork = nil
            accentColor = Self.fallbackAccent
            // Leave the key uncached so artwork that Music downloads a moment
            // later is picked up by the next poll.
            return
        }
        currentArtworkKey = state.key
        artwork = image
        accentColor = Self.dominantAccent(from: image)
    }

    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("NotchFlow Music scripting error: %@", error)
        }
        return error == nil ? result : nil
    }

    private func applyShuffleState(_ reportedValue: Bool) {
        if let pendingShuffleState {
            isShuffleEnabled = pendingShuffleState
            if reportedValue == pendingShuffleState {
                self.pendingShuffleState = nil
            }
        } else {
            isShuffleEnabled = reportedValue
        }
    }

    private func runCommand(_ source: String, refreshAfter: Bool = false) {
        pollingQueue.async { [weak self] in
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard refreshAfter else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self?.refreshAsync() }
        }
    }

    private static let fallbackAccent = NSColor(calibratedRed: 0.38, green: 0.55, blue: 1, alpha: 1)

    private static func dominantAccent(from image: NSImage) -> NSColor {
        let sampleSize = 28
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return fallbackAccent
        }

        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return fallbackAccent }

        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        struct Bucket {
            var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        }
        var buckets: [Int: Bucket] = [:]

        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[index + 3] > 180 else { continue }
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let high = max(red, max(green, blue))
            let low = min(red, min(green, blue))
            let saturation = high == 0 ? 0 : (high - low) / high

            // Ignore near-black, near-white, and gray pixels; they make poor
            // waveform accents against a black surface.
            guard high > 0.16, high < 0.96, saturation > 0.18 else { continue }
            let key = (Int(red * 7) << 6) | (Int(green * 7) << 3) | Int(blue * 7)
            let weight = saturation * (0.55 + high)
            var bucket = buckets[key, default: Bucket()]
            bucket.red += red * weight
            bucket.green += green * weight
            bucket.blue += blue * weight
            bucket.weight += weight
            buckets[key] = bucket
        }

        guard let winner = buckets.values.max(by: { $0.weight < $1.weight }), winner.weight > 0 else {
            return fallbackAccent
        }
        let sampled = NSColor(
            calibratedRed: winner.red / winner.weight,
            green: winner.green / winner.weight,
            blue: winner.blue / winner.weight,
            alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        sampled.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            calibratedHue: hue,
            saturation: max(0.58, saturation),
            brightness: max(0.76, brightness),
            alpha: 1
        )
    }
}
