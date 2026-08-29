# NotchFlow

A native macOS notch app built with AppKit and Combine.

## Current behavior

- Matches the idle height to the Mac's physical notch using the display safe area.
- Shows compact current album artwork on the left while Spotify or Apple Music is playing.
- Shows a compact animated waveform on the right while music is playing.
- Derives the waveform color from each album cover and transitions smoothly between tracks.
- Gently expands on hover with a synchronized 60 fps eased animation and collapses after the pointer leaves.
- Hovering the artwork or waveform reveals the centered track and artist name and replaces the waveform with a working pause button.
- Paused tracks remain visible; the waveform freezes and the control changes to play.
- Clicking the music surface opens a full player with large artwork, metadata, progress, seeking, and playback controls.
- The full player includes a shuffle control that stays highlighted while shuffle is enabled in Music.app or Spotify.
- The AirPlay button opens a native menu of available audio outputs and switches the system output device.
- Brightness keys temporarily morph the notch into a compact Display HUD with a live yellow level bar and percentage.
- Volume and mute keys use the same compact HUD with a speaker icon and macOS green level bar.
- Does not include clipboard or other productivity features yet.

## Project structure

```text
Sources/NotchFlow/
├── App/                 App lifecycle and launch setup
├── Controllers/         Generic notch window ownership and event routing
├── Models/              Shared notch presentation state
├── NotchApps/
│   ├── NotchApp.swift   Contract implemented by every notch feature
│   └── Music/           Music model, view, controls, waveform, and audio output
├── Services/            Hardware keys, display brightness, and system audio
└── Views/               Shared views such as the system HUD
```

Brightness and volume intentionally share `SystemHUDView` because they have the same layout and animation. Their behavior is separate: `DisplayBrightnessService.swift` handles display brightness, while `SystemAudioService.swift` handles volume and mute.

## Notch app architecture

`NotchWindowController` is only the host: it owns the panel, screen sizing, hover routing, outside-click handling, and hardware HUD events. It does not own music state or music controls.

Each feature conforms to `NotchApp`, owns its model, and returns a `NotchAppView`. Music is the first implementation in `NotchApps/Music`. Future clipboard, timer, or notification features can live in their own folders and implement the same boundary without adding feature code to the window controller.

## Playback architecture

The music notch app observes and controls Music.app or Spotify through their macOS scripting interfaces. Current metadata, transport controls, seeking, shuffle state, and audio-output selection are contained inside the music module. The Playing Next feature has been removed because neither application exposes its live queue through a reliable public macOS API.

## Run in Xcode

1. Open `NotchFlow.xcodeproj` in Xcode 15 or newer.
2. Select the **NotchFlow** scheme and **My Mac**.
3. Press **⌘R**.
4. Allow Automation access if macOS asks permission to control Music or Spotify.
5. Allow Accessibility/Input Monitoring when prompted so NotchFlow can replace the standard brightness HUD.

```sh
open /Users/dreamsparkx/Projects/NotchFlow/NotchFlow.xcodeproj
```

The App Sandbox is intentionally disabled because the app reads now-playing data from other applications and handles the brightness hardware keys. Accessibility permission is required to intercept those keys and suppress the standard macOS brightness HUD; Input Monitoring provides the observation-only fallback.
