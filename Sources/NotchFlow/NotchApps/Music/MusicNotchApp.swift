final class MusicNotchApp: NotchApp {
    let identifier = "music"
    private let nowPlaying = NowPlayingModel()

    func makeView(presentation: NotchPresentationModel) -> NotchAppView {
        MusicNotchAppView(nowPlaying: nowPlaying, presentation: presentation)
    }
}
