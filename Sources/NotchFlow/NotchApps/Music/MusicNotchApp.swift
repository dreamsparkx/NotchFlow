final class NowPlayingNotchApp: NotchApp {
    let identifier = "now-playing"
    let displayName = "Now Playing"
    private let nowPlaying = NowPlayingModel()

    func makeView(presentation: NotchPresentationModel) -> NotchAppView {
        NowPlayingNotchAppView(nowPlaying: nowPlaying, presentation: presentation)
    }
}
