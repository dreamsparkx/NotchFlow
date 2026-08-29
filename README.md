# NotchFlow

Minimal first version of a native macOS notch app.

## Current behavior

- Matches the idle height to the Mac's physical notch using the display safe area.
- Shows compact current album artwork on the left while Spotify or Apple Music is playing.
- Shows a compact animated waveform on the right while music is playing.
- Derives the waveform color from each album cover and transitions smoothly between tracks.
- Gently expands on hover with a synchronized 60 fps eased animation and collapses after the pointer leaves.
- Hovering the artwork or waveform reveals the centered track and artist name and replaces the waveform with a working pause button.
- Paused tracks remain visible; the waveform freezes and the control changes to play.
- Clicking the music surface opens a full player with large artwork, metadata, progress, seeking, and playback controls.
- Clicking the playlist button widens the player and reveals an animated Playing Next panel (Apple Music exposes upcoming playlist tracks; Spotify does not expose its queue through its macOS scripting API).
- The AirPlay button opens a native menu of available audio outputs and switches the system output device.
- Brightness keys temporarily morph the notch into a compact Display HUD with a live yellow level bar and percentage.
- Volume and mute keys use the same compact HUD with a speaker icon and macOS green level bar.
- Does not include clipboard or other productivity features yet.

## Run in Xcode

1. Open `NotchFlow.xcodeproj` in Xcode 15 or newer.
2. Select the **NotchFlow** scheme and **My Mac**.
3. Press **⌘R**.
4. Allow Automation access if macOS asks permission to control Music or Spotify.
5. Allow Accessibility/Input Monitoring when prompted so NotchFlow can replace the standard brightness HUD.

```sh
open /Users/dreamsparkx/Projects/NotchFlow/NotchFlow.xcodeproj
```

The current locally signed build can also be launched directly:

```sh
open /Users/dreamsparkx/Projects/NotchFlow/dist/NotchFlow.app
```

The App Sandbox is intentionally disabled because the app reads now-playing data from other applications and handles the brightness hardware keys. Accessibility permission is required to intercept those keys and suppress the standard macOS brightness HUD; Input Monitoring provides the observation-only fallback.
