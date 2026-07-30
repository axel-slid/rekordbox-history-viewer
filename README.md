<div align="center">
  <img src="SetPlayerMac/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="132" alt="Set Player icon">

  # Set Player

  **The memory layer for every DJ set.**

  Recordings + waveforms · Rekordbox history · Live lyrics · Photos + places

  [![Version](https://img.shields.io/badge/version-1.0.0-ff2e78?style=for-the-badge)](https://github.com/axel-slid/set-player/releases/tag/v1.0.0)
  [![macOS](https://img.shields.io/badge/macOS-14%2B-111827?style=for-the-badge&logo=apple)](https://github.com/axel-slid/set-player/releases/latest)
  [![iOS](https://img.shields.io/badge/iOS-17%2B-111827?style=for-the-badge&logo=apple)](SetPlayer)
  [![SwiftUI](https://img.shields.io/badge/SwiftUI-native-f05138?style=for-the-badge&logo=swift)](https://developer.apple.com/xcode/swiftui/)
  [![Build](https://img.shields.io/github/actions/workflow/status/axel-slid/set-player/build-release.yml?style=for-the-badge&label=build)](https://github.com/axel-slid/set-player/actions/workflows/build-release.yml)

  [Download](https://github.com/axel-slid/set-player/releases/latest) ·
  [Feature reference](docs/features.md) ·
  [Release notes](docs/release-v1.0.0.md)
</div>

---

![Set Player animated product tour](docs/set-player-demo.gif)

Set Player turns a folder of recorded mixes into a visual, searchable memory
library. Play a set against its full waveform, match its timeline to Rekordbox
history, attach the place and media around it, follow live lyrics, or open
performance tools without leaving the native macOS app.

## What makes Set Player different

| Surface | What it does |
| --- | --- |
| **Set library** | Finds recordings, groups them into named sets and genres, searches the library, and preserves artwork, duration, notes, and location |
| **Player** | Full waveform, scrubbing, playhead, jump controls, volume, track markers, now/next context, and immersive media |
| **Rekordbox timeline** | Reads played-track history, matches tracks to a recording, and builds a timed set history instead of a plain playlist |
| **Set memories** | Adds photos, video, descriptions, dates, and an explorable map location to the recording |
| **Performance extensions** | Rave visuals, beat and phrase layers, live Rekordbox lyrics, app-audio recording, and a per-app volume mixer |
| **Apple continuity** | Native macOS and iPhone surfaces with library synchronization |

## Highlights

- Native SwiftUI library built around complete sets rather than loose tracks.
- Detailed set hero with artwork or video, location, date, duration, and notes.
- Cached full-length waveform with animated playhead and track boundaries.
- Rekordbox history browser for sets, tracks, stats, and timeline matching.
- Live lyrics synchronized to the currently playing Rekordbox track.
- Rave Lyrics mode with beat, phrase, and Butterchurn-style visuals.
- App-audio set recording and per-app volume control on macOS.
- Photos, video, and map context attached directly to the set.
- Mark Track for live manual timeline correction.
- iPhone sync for taking the library with you.
- Multiple dark themes with high-energy pink, orange, and cyan accents.

## Install

### macOS

1. Download `Set-Player-macOS-arm64.zip` from the
   [latest release](https://github.com/axel-slid/set-player/releases/latest).
2. Unzip it and drag `Set Player.app` to Applications.
3. Open the app and choose **Import Audio** to add your existing recordings.

The public build is ad-hoc signed. If macOS quarantines it after download,
right-click the app and choose **Open**.

### Build macOS or iOS from source

Requirements: Xcode 17+, XcodeGen, and macOS 14 or later.

```bash
git clone https://github.com/axel-slid/set-player.git
cd set-player
brew install xcodegen
xcodegen generate
open SetPlayer.xcodeproj
```

Choose the `SetPlayerMac` scheme for macOS or `SetPlayer` for iPhone.

Command-line verification:

```bash
xcodegen generate
xcodebuild -project SetPlayer.xcodeproj \
  -scheme SetPlayerMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
```

## Architecture

```text
SwiftUI library + player
   ├── set metadata, artwork, photos, video, and location
   ├── AVFoundation playback + waveform cache
   ├── Rekordbox history and track matching
   ├── live lyrics + visualizer web view
   ├── ScreenCaptureKit recording + app volume control
   └── iPhone synchronization
```

## Privacy note

Set Player works with local audio, Rekordbox history, photos, and location
metadata. The macOS app requests audio-capture access only when you use Record
Set or Volume Mixer. Review the selected files before sharing a library or
release artifact.

## Documentation

- [Complete feature breakdown](docs/features.md)
- [v1.0.0 release notes](docs/release-v1.0.0.md)
- [Remotion source for the README animation](marketing/remotion)

<div align="center">
  Built for the part of a set that should not disappear when the music stops.
</div>
