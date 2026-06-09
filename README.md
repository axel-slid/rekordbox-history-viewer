# Rekordbox History Viewer

A clean Electron app for browsing Rekordbox played-track history. It reads your local Rekordbox database, groups tracks into dated sets, resolves Spotify track names when possible, and shows stats like play activity, genre mix, total play time, average time per day, repeated tracks, and a full track library.

## Download And Run

**Download the app here:** <https://github.com/axel-slid/rekordbox-history-viewer/releases/tag/v0.1.0>

### Mac

1. Click the download link above.
2. Download `Rekordbox.History.Viewer-0.1.0-arm64-mac.zip`.
3. Double-click the zip file to unzip it.
4. Open `Rekordbox History Viewer`.
5. If macOS blocks it, right-click `Rekordbox History Viewer`, choose **Open**, then choose **Open** again.

### Windows

1. Click the download link above.
2. Download `Rekordbox.History.Viewer-0.1.0-win.zip`.
3. Right-click the zip file and choose **Extract All**.
4. Open the extracted folder.
5. Double-click `Rekordbox History Viewer.exe`.

### Linux

1. Click the download link above.
2. Download `Rekordbox.History.Viewer-0.1.0.AppImage`.
3. Right-click the file, open **Properties**, and allow it to run as a program.
4. Double-click the AppImage.

The app reads Rekordbox history from your own computer. It does not include anyone else's music library.

### If The App Download Does Not Work

Use the source-code fallback on macOS:

1. Click the green **Code** button on GitHub.
2. Click **Download ZIP**.
3. Unzip the folder.
4. Double-click `open_rekordbox_history.command`.
5. If macOS blocks it, right-click the file, choose **Open**, then choose **Open** again.

That script installs the app dependencies, prepares the Python Rekordbox reader, builds the app, and opens it.

You only need:

- Rekordbox installed with existing play history.
- Node.js LTS from <https://nodejs.org>.
- Python 3 from <https://www.python.org/downloads/>.

![Stats view](docs/screenshots/stats.png)

## What You Get

- **Sets:** every dated play session, named like `June 7th, 2026 Set`.
- **Stats:** GitHub-style play heatmap, genre donut, total play time, average time per day, busiest day, top source, average BPM, and most repeated tracks.
- **Tracks:** searchable unique track library with play counts, last played time, BPM, length, source, and sorting.
- **Export helpers:** download a setlist or generate a text prompt that explains how to recreate a mix manually.

## Screenshots

### Stats

![Stats view](docs/screenshots/stats.png)

### Sets

![Sets view](docs/screenshots/sets.png)

### Tracks

![Tracks view](docs/screenshots/tracks.png)

## For Developers

```sh
npm install
npm run setup:python
npm run dev
```

Build the static renderer:

```sh
npm run build
```

Run the built Electron app:

```sh
npm start
```

Create packaged builds:

```sh
npm run dist
```

## How It Works

The Electron main process runs `scripts/extract_rekordbox_history.py`, which reads the local Rekordbox database at:

```text
~/Library/Pioneer/rekordbox/master.db
```

The renderer then groups the raw played rows into:

- dated sets
- unique tracks
- activity stats
- genre summaries
- repeated-track rankings

Spotify metadata is cached locally in `data/spotify-track-cache.json`, which is ignored by git so personal lookup data does not get committed.

## Notes

- Rekordbox does not appear to save enough effect/transition automation data to recreate an exact DJ mix. The app can export a setlist and a recreation prompt, but it cannot perfectly rebuild effects, EQ moves, fader moves, loops, or transitions from Rekordbox history alone.
- The app is designed around local Rekordbox 6 database data on macOS. Windows/Linux builds are provided for the Electron shell, but the extractor path may need updates for non-macOS Rekordbox libraries.
