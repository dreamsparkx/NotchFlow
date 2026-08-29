import AppKit
import Combine

struct QueuedTrack {
    let id: String
    let title: String
    let artist: String
    let artwork: NSImage?
}

final class NowPlayingModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var hasTrack = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accentColor = NSColor(calibratedRed: 0.38, green: 0.55, blue: 1, alpha: 1)
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queueTracks: [QueuedTrack] = []
    @Published private(set) var queueMessage = ""

    private let pollingQueue = DispatchQueue(label: "com.dreamsparkx.NotchFlow.now-playing", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var currentArtworkKey: String?
    private var pendingArtworkKey: String?
    private var activePlayer: Player?

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
        guard let activePlayer else { return }
        isPlaying.toggle()
        runCommand("tell application \"\(activePlayer.rawValue)\" to playpause")
    }

    func previousTrack() {
        guard let activePlayer else { return }
        runCommand("tell application \"\(activePlayer.rawValue)\" to previous track", refreshAfter: true)
    }

    func nextTrack() {
        guard let activePlayer else { return }
        runCommand("tell application \"\(activePlayer.rawValue)\" to next track", refreshAfter: true)
    }

    func seek(to seconds: Double) {
        guard let activePlayer, duration > 0 else { return }
        let clamped = min(duration, max(0, seconds))
        elapsed = clamped
        runCommand("tell application \"\(activePlayer.rawValue)\" to set player position to \(clamped)")
    }

    func refreshQueue() {
        let player = activePlayer
        queueMessage = "Loading…"
        pollingQueue.async { [weak self] in
            guard let self else { return }
            switch player {
            case .music:
                let tracks = self.musicQueue()
                DispatchQueue.main.async {
                    self.queueTracks = tracks
                    self.queueMessage = tracks.isEmpty ? "Nothing else is queued" : ""
                }
            case .spotify:
                DispatchQueue.main.async {
                    self.queueTracks = []
                    self.queueMessage = "Spotify does not expose Playing Next"
                }
            case nil:
                DispatchQueue.main.async {
                    self.queueTracks = []
                    self.queueMessage = "Nothing is playing"
                }
            }
        }
    }

    private func isRunning(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func spotifyState() -> (isPlaying: Bool, key: String, title: String, artist: String, artworkURL: String, elapsed: Double, duration: Double)? {
        let source = """
        tell application "Spotify"
            set currentSong to current track
            return (player state as text) & "|||" & (name of currentSong) & "|||" & (artist of currentSong) & "|||" & (album of currentSong) & "|||" & (artwork url of currentSong) & "|||" & (player position as text) & "|||" & ((duration of currentSong) / 1000 as text)
        end tell
        """
        guard let result = runScript(source)?.stringValue else { return nil }
        let parts = result.components(separatedBy: "|||")
        guard parts.count == 7 else { return nil }
        return (parts[0] == "playing", parts[1...3].joined(separator: "|"), parts[1], parts[2], parts[4], Double(parts[5]) ?? 0, Double(parts[6]) ?? 0)
    }

    private func applySpotify(_ state: (isPlaying: Bool, key: String, title: String, artist: String, artworkURL: String, elapsed: Double, duration: Double)) {
        isPlaying = state.isPlaying
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

    private func musicState() -> (isPlaying: Bool, key: String, title: String, artist: String, elapsed: Double, duration: Double)? {
        let source = """
        tell application "Music"
            set currentSong to current track
            return (player state as text) & "|||" & (name of currentSong) & "|||" & (artist of currentSong) & "|||" & (album of currentSong) & "|||" & (player position as text) & "|||" & (duration of currentSong as text)
        end tell
        """
        guard let result = runScript(source)?.stringValue else { return nil }
        let parts = result.components(separatedBy: "|||")
        guard parts.count == 6 else { return nil }
        return (parts[0] == "playing", parts[1...3].joined(separator: "|"), parts[1], parts[2], Double(parts[4]) ?? 0, Double(parts[5]) ?? 0)
    }

    private func musicQueue() -> [QueuedTrack] {
        let source = """
        tell application "Music"
            set fieldSeparator to ASCII character 31
            set rowSeparator to ASCII character 30
            set activePlaylist to current playlist
            set playlistTracks to every track of activePlaylist
            set currentName to name of current track
            set currentArtist to artist of current track
            set currentIndex to 0
            repeat with candidateIndex from 1 to (count of playlistTracks)
                set candidateTrack to item candidateIndex of playlistTracks
                try
                    if (name of candidateTrack is currentName) and (artist of candidateTrack is currentArtist) then
                        set currentIndex to candidateIndex
                        exit repeat
                    end if
                end try
            end repeat
            if currentIndex is 0 then return ""
            set finalIndex to currentIndex + 3
            set trackTotal to count of playlistTracks
            if finalIndex > trackTotal then set finalIndex to trackTotal
            if currentIndex is greater than or equal to finalIndex then return ""
            set outputText to ""
            repeat with trackIndex from (currentIndex + 1) to finalIndex
                set queuedTrack to item trackIndex of playlistTracks
                set outputText to outputText & (trackIndex as text) & fieldSeparator & (name of queuedTrack) & fieldSeparator & (artist of queuedTrack)
                if trackIndex < finalIndex then set outputText to outputText & rowSeparator
            end repeat
            return outputText
        end tell
        """
        guard let result = runScript(source)?.stringValue, !result.isEmpty else { return [] }
        return result.components(separatedBy: "\u{1E}").compactMap { row in
            let fields = row.components(separatedBy: "\u{1F}")
            guard fields.count == 3, let index = Int(fields[0]) else { return nil }
            let artworkSource = "tell application \"Music\" to get data of artwork 1 of track \(index) of current playlist"
            let artwork = runScript(artworkSource).flatMap { NSImage(data: $0.data) }
            return QueuedTrack(id: "music-\(index)-\(fields[1])", title: fields[1], artist: fields[2], artwork: artwork)
        }
    }

    private func applyMusic(_ state: (isPlaying: Bool, key: String, title: String, artist: String, elapsed: Double, duration: Double)) {
        isPlaying = state.isPlaying
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
