import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let sourceMenu = NSMenu(title: "Source")
    private let showNowPlaying: () -> Void
    private let showSettings: () -> Void
    private var sourceRefreshID = UUID()
    private var nowPlayingItem: NSMenuItem!
    private var sourceItem: NSMenuItem!

    init(showNowPlaying: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.showNowPlaying = showNowPlaying
        self.showSettings = showSettings
        super.init()
        configureStatusItem()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            let image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "NotchFlow")?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
            button.toolTip = "NotchFlow"
        }

        let menu = NSMenu(title: "NotchFlow")
        menu.autoenablesItems = false
        menu.delegate = self

        nowPlayingItem = NSMenuItem(
            title: "Now Playing",
            action: #selector(openNowPlaying),
            keyEquivalent: ""
        )
        nowPlayingItem.target = self
        nowPlayingItem.state = .on
        nowPlayingItem.image = menuImage(named: "music.note")
        menu.addItem(nowPlayingItem)

        sourceMenu.delegate = self
        sourceMenu.autoenablesItems = false
        sourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        sourceItem.image = menuImage(named: "music.note.list")
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        settingsItem.image = menuImage(named: "gearshape")
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit NotchFlow",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        quitItem.image = menuImage(named: "power")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu !== sourceMenu else { return }
        updateSourceModeCheckmarks()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sourceMenu else { return }
        let refreshID = UUID()
        sourceRefreshID = refreshID
        sourceMenu.removeAllItems()

        let loadingItem = NSMenuItem(title: "Finding Audio Sources…", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        sourceMenu.addItem(loadingItem)

        AudioSourceService.activeSources { [weak self] sources in
            guard let self, self.sourceRefreshID == refreshID else { return }
            var displayedSources = sources
            if let selectedSource = AudioSourceSelection.shared.source {
                let selectedIdentifier = selectedSource.bundleIdentifier ?? "pid:\(selectedSource.processID)"
                if !displayedSources.contains(where: {
                    ($0.bundleIdentifier ?? "pid:\($0.processID)") == selectedIdentifier
                }) {
                    displayedSources.append(selectedSource)
                }
            }
            self.sourceMenu.removeAllItems()
            guard !displayedSources.isEmpty else {
                let emptyItem = NSMenuItem(title: "No Active Media Sources", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                self.sourceMenu.addItem(emptyItem)
                self.sourceMenu.update()
                return
            }

            for source in displayedSources {
                let item = NSMenuItem(
                    title: source.name,
                    action: #selector(selectAudioSource(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.isEnabled = true
                item.image = self.menuImage(named: "music.note")
                item.representedObject = AudioSourceMenuItemContext(source: source)
                let identifier = source.bundleIdentifier ?? "pid:\(source.processID)"
                item.state = identifier == AudioSourceSelection.shared.selectedIdentifier ? .on : .off
                self.sourceMenu.addItem(item)
            }
            self.sourceMenu.update()
        }
    }

    @objc private func openNowPlaying() {
        AudioSourceSelection.shared.selectAutomatic()
        updateSourceModeCheckmarks()
        showNowPlaying()
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func selectAudioSource(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? AudioSourceMenuItemContext else { return }
        AudioSourceSelection.shared.select(context.source)
        updateSourceModeCheckmarks()
        for item in sourceMenu.items {
            let itemContext = item.representedObject as? AudioSourceMenuItemContext
            item.state = itemContext?.identifier == context.identifier ? .on : .off
        }

        showNowPlaying()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func menuImage(named symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func updateSourceModeCheckmarks() {
        let automatic = AudioSourceSelection.shared.isAutomatic
        nowPlayingItem.state = automatic ? .on : .off
        sourceItem.state = automatic ? .off : .on
    }
}

private final class AudioSourceMenuItemContext: NSObject {
    let source: ActiveAudioSource
    let identifier: String

    init(source: ActiveAudioSource) {
        self.source = source
        identifier = source.bundleIdentifier ?? "pid:\(source.processID)"
    }
}
