# Rekordbox History Viewer

Turn your Rekordbox play history into a clean desktop dashboard for sets, stats, and tracks.

![Stats view](docs/screenshots/stats.png)

## What It Shows

- **Sets:** dated sessions like `June 7th, 2026 Set`, with the tracks played in order.
- **Stats:** a GitHub-style activity heatmap, genre donut, total play time, average time per day, busiest day, top source, average BPM, and repeated tracks.
- **Tracks:** a searchable track library with unique tracks, play counts, last played time, Camelot-style key badges, BPM, length, source, and sorting.
- **Paths:** start from a song, expand a rightward branching tree of historical next-track choices, see color-coded Camelot keys, and copy any path from the root song.
- **Exports:** download a setlist or generate a text prompt for manually recreating a set.

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

The Electron main process runs `scripts/extract_rekordbox_history.py`, which reads the local Rekordbox database at:

```text
~/Library/Pioneer/rekordbox/master.db
```

The renderer groups the raw played rows into:

- dated sets
- unique tracks
- activity stats
- genre summaries
- repeated-track rankings

Spotify metadata is cached locally in the app's user-data folder so personal lookup data does not get committed or uploaded.

## What It Cannot Do Yet

I originally tried to make the app recreate historical mixes automatically. Rekordbox history does not appear to save enough transition, effects, EQ, loop, or fader data to rebuild exact mixes, so the app can show the order of songs and export setlists, but it cannot recreate the actual transitions.

The current extractor is designed around local Rekordbox 6 database data on macOS. Windows/Linux builds are provided for the Electron shell, but non-macOS Rekordbox library paths may need follow-up work.
