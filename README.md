# Rekordbox History Viewer

Turn your Rekordbox play history into a clean desktop dashboard for sets, stats, and tracks.

[Download the latest app here](https://github.com/axel-slid/rekordbox-history-viewer/releases/latest)

## Download

Open the latest release, then download the file for your computer:

- **Mac with Apple Silicon:** `Rekordbox-History-Viewer-0.1.7-mac-apple-silicon.zip`
- **Windows:** `Rekordbox-History-Viewer-0.1.7-windows.zip`
- **Linux:** `Rekordbox-History-Viewer-0.1.7-linux.AppImage`

On Mac, unzip the file, then open **Rekordbox History Viewer**. If macOS says the app is damaged because it was downloaded from the internet, run this once in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Rekordbox History Viewer.app"
```

If the app is still in Downloads instead of Applications, use this instead:

```sh
xattr -dr com.apple.quarantine "$HOME/Downloads/Rekordbox History Viewer.app"
```

![Stats view](docs/screenshots/stats.png)

## What It Shows

- **Sets:** dated sessions like `June 7th, 2026 Set`, with the tracks played in order.
- **Stats:** a GitHub-style activity heatmap, genre donut, total play time, average time per day, busiest day, top source, average BPM, and repeated tracks.
- **Tracks:** a searchable track library with unique tracks, play counts, last played time, Camelot-style key badges, BPM, length, source, and sorting.
- **Paths:** start from a song, expand a rightward branching tree of historical next-track choices, see color-coded Camelot keys, and copy any path from the root song.
- **Exports:** copy a timed setlist or download a setlist.

## Latest Fixes

- `0.1.7` fixes a Windows Unicode export issue that could show `charmap codec can't encode character` while loading Rekordbox history.
- The database path is editable directly in the app: double-click the displayed path, paste `master.db` or a folder containing it, and press Enter.
- **MIDI Logger:** capture future DDJ-FLX10 MIDI actions, export the event log, and replay the action timeline visually inside the app.
- **Setup:** choose a custom Rekordbox `master.db` location if Rekordbox data is not in the default folder.

## Screenshots

### Stats

![Stats view](docs/screenshots/stats.png)

### Sets

![Sets view](docs/screenshots/sets.png)

### Tracks

![Tracks view](docs/screenshots/tracks.png)

### Paths

![Paths view](docs/screenshots/paths.png)

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

The Electron main process runs `scripts/extract_rekordbox_history.py`, which reads the local Rekordbox database. By default it looks at:

```text
~/Library/Pioneer/rekordbox/master.db
```

On macOS, `~/Library` is hidden by Finder. If the app does not find Rekordbox automatically, click **Use Default** to point the app at the normal hidden Library path. You can also click **Locate Rekordbox**, press `Command+Shift+G` in the file picker, paste `~/Library/Pioneer/rekordbox`, and choose `master.db`.

If Rekordbox is somewhere else, click **Locate Rekordbox** in the app and choose either `master.db` directly or the folder that contains it. This is especially useful on Windows machines where the Rekordbox database is not on the default drive.

The renderer groups the raw played rows into:

- dated sets
- unique tracks
- activity stats
- genre summaries
- repeated-track rankings

Spotify metadata is cached locally in the app's user-data folder so personal lookup data does not get committed or uploaded.

## What It Cannot Do Yet

I originally tried to make the app recreate historical mixes automatically. Rekordbox history does not appear to save enough transition, effects, EQ, loop, or fader data to rebuild exact mixes, so the app can show the order of songs and export setlists, but it cannot recreate the actual transitions.

The extractor is designed around local Rekordbox 6 database data. Non-default database locations can be selected from the app with **Locate Rekordbox**.
