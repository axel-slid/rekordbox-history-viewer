#!/usr/bin/env python3
"""Extract Rekordbox played-track history as JSON for the Electron app."""

from __future__ import annotations

import contextlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from html import unescape
from pathlib import Path
from typing import Any


HOME = Path(os.environ.get("REKORDBOX_HISTORY_HOME") or Path.home()).expanduser()
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = HOME / "Library" / "Pioneer" / "rekordbox" / "master.db"
CACHE_PATH = PROJECT_ROOT / "data" / "spotify-track-cache.json"
SPOTIFY_ART_PATH = (
    HOME
    / "Library"
    / "Application Support"
    / "Pioneer"
    / "rekordbox6"
    / ".cache"
    / ".spotify"
    / "art"
)
SPOTIFY_CACHE_ROOTS = [
    HOME / "Library" / "Application Support" / "Spotify" / "PersistentCache" / "Users",
    HOME / "Library" / "Caches" / "com.spotify.client" / "Browser" / "IndexedDB",
]
SPOTIFY_RE = re.compile(r"^spotify:track:([A-Za-z0-9]+)$")
SPOTIFY_CACHE_TRACK_RE = re.compile(rb"spotify:track:([A-Za-z0-9]{22})")
SPOTIFY_ID_RE = re.compile(r"^[A-Za-z0-9]{22}$")
SPOTIFY_CACHE_PRINTABLE_RE = re.compile(rb"[ -~]{3,}")
SPOTIFY_LOOKUP_DISABLED = os.environ.get("REKORDBOX_HISTORY_SKIP_SPOTIFY_LOOKUP") == "1"
META_RE_TEMPLATE = r'<meta[^>]+{attr}="{key}"[^>]+content="([^"]*)"'
BAD_SPOTIFY_CACHE_TEXT = {
    "Song",
    "Track",
    "Album",
    "Single",
    "Explicit",
    "Clean",
    "VIDEO_DISABLED",
    "VIDEOS_DISABLED",
}
GENRE_BUCKETS = [
    ("drum", "Drum & Bass"),
    ("dnb", "Drum & Bass"),
    ("jungle", "Drum & Bass"),
    ("garage", "UK Garage"),
    ("house", "House"),
    ("techno", "Techno"),
    ("trance", "Trance"),
    ("edm", "EDM"),
    ("electro", "Electronic"),
    ("electronic", "Electronic"),
    ("dance", "Dance"),
    ("disco", "Disco / Funk"),
    ("funk", "Disco / Funk"),
    ("soul", "Soul"),
    ("hip hop", "Hip Hop"),
    ("rap", "Hip Hop"),
    ("r&b", "R&B"),
    ("rock", "Rock"),
    ("indie", "Indie"),
    ("pop", "Pop"),
    ("country", "Country"),
    ("reggae", "Reggae"),
    ("latin", "Latin"),
    ("afro", "Afro"),
]


def quiet_imports():
    with contextlib.redirect_stdout(sys.stderr):
        from pyrekordbox import Rekordbox6Database
        from pyrekordbox.db6 import tables

    return Rekordbox6Database, tables


def iso(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.isoformat()
    text = str(value).strip()
    if not text:
        return None
    try:
        return datetime.fromisoformat(text).isoformat()
    except ValueError:
        return text


def text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def int_or_none(value: Any) -> int | None:
    try:
        if value in (None, ""):
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


def bpm(value: Any) -> float | None:
    number = int_or_none(value)
    if not number:
        return None
    return round(number / 100, 2)


def display_title(content: Any, path_value: str, spotify_meta: dict[str, Any] | None = None) -> str:
    title = text(getattr(content, "Title", "")) or text(getattr(content, "SrcTitle", ""))
    if title:
        return title
    if spotify_meta and text(spotify_meta.get("title")):
        return text(spotify_meta.get("title"))
    match = SPOTIFY_RE.match(path_value)
    if match:
        return "Unresolved Spotify track"
    if path_value:
        return Path(path_value).stem or path_value
    return "Untitled track"


def source_for(path_value: str, content: Any) -> str:
    if SPOTIFY_RE.match(path_value):
        return "Spotify"
    if path_value.startswith("/"):
        return "Local file"
    if int_or_none(getattr(content, "FileType", None)) == 25:
        return "Streaming"
    return "Unknown"


def spotify_art() -> dict[str, str]:
    if not SPOTIFY_ART_PATH.exists():
        return {}
    art: dict[str, str] = {}
    for line in SPOTIFY_ART_PATH.read_text(errors="ignore").splitlines():
        if "=" not in line:
            continue
        track_id, url = line.split("=", 1)
        track_id = track_id.strip()
        url = url.strip()
        if track_id and url:
            art[track_id] = url
    return art


def load_spotify_cache() -> dict[str, dict[str, Any]]:
    if not CACHE_PATH.exists():
        return {}
    try:
        data = json.loads(CACHE_PATH.read_text())
        if isinstance(data, dict):
            return {str(k): v for k, v in data.items() if isinstance(v, dict)}
    except (OSError, json.JSONDecodeError):
        return {}
    return {}


def save_spotify_cache(cache: dict[str, dict[str, Any]]) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = CACHE_PATH.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(cache, indent=2, sort_keys=True), encoding="utf-8")
    tmp_path.replace(CACHE_PATH)


def parse_meta(html: str, attr: str, key: str) -> str:
    match = re.search(META_RE_TEMPLATE.format(attr=attr, key=re.escape(key)), html)
    return unescape(match.group(1)) if match else ""


def parse_spotify_description(description: str) -> tuple[str, str]:
    parts = [part.strip() for part in description.split("·")]
    artist = parts[0] if parts else ""
    album = parts[1] if len(parts) > 1 and parts[1] != "Song" else ""
    return artist, album


def fetch_url(url: str) -> str:
    curl = os.environ.get("CURL_BIN") or "curl"
    try:
        result = subprocess.run(
            [
                curl,
                "-L",
                "--fail",
                "--silent",
                "--show-error",
                "--max-time",
                "15",
                "-A",
                "Mozilla/5.0",
                url,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout
    except (OSError, subprocess.CalledProcessError):
        request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(request, timeout=12) as response:
            return response.read().decode("utf-8", errors="ignore")


def fetch_spotify_oembed(track_id: str) -> dict[str, Any]:
    track_url = f"https://open.spotify.com/track/{urllib.parse.quote(track_id)}"
    spotify_uri = f"spotify:track:{track_id}"
    urls = [
        f"https://embed.spotify.com/oembed/?url={urllib.parse.quote(spotify_uri, safe=':')}",
        f"https://open.spotify.com/oembed?url={urllib.parse.quote(track_url, safe='')}",
    ]
    errors = []
    payload: dict[str, Any] = {}
    for url in urls:
        try:
            payload = json.loads(fetch_url(url))
            if text(payload.get("title")):
                break
        except Exception as exc:
            errors.append(str(exc))
    if not text(payload.get("title")):
        raise RuntimeError("; ".join(errors) or "Spotify oEmbed did not return a title")
    return {
        "title": text(payload.get("title")),
        "artist": "",
        "album": "",
        "thumbnailUrl": text(payload.get("thumbnail_url")),
        "provider": "Spotify oEmbed",
        "resolvedAt": datetime.now().isoformat(),
    }


def fetch_spotify_page(track_id: str) -> dict[str, Any]:
    oembed_meta: dict[str, Any] = {}
    try:
        oembed_meta = fetch_spotify_oembed(track_id)
    except Exception:
        oembed_meta = {}
    if text(oembed_meta.get("title")):
        return oembed_meta

    url = f"https://open.spotify.com/track/{urllib.parse.quote(track_id)}"
    try:
        html = fetch_url(url)
    except Exception:
        if text(oembed_meta.get("title")):
            return oembed_meta
        raise
    title = text(parse_meta(html, "property", "og:title"))
    description = text(parse_meta(html, "property", "og:description"))
    artist, album = parse_spotify_description(description)
    thumbnail = text(parse_meta(html, "property", "og:image"))
    return {
        "title": title or text(oembed_meta.get("title")),
        "artist": artist,
        "album": album,
        "thumbnailUrl": thumbnail or text(oembed_meta.get("thumbnailUrl")),
        "provider": "Spotify",
        "resolvedAt": datetime.now().isoformat(),
    }


def clean_spotify_cache_text(value: str) -> str:
    cleaned = value.strip().replace("\\u0026", "&")
    cleaned = re.sub(r'^[^A-Za-z0-9#(\[]+(?=[A-Za-z0-9#(\[])', "", cleaned)
    cleaned = re.sub(r'["*][0-9A-Za-z]{0,2}$', "", cleaned)
    cleaned = cleaned.strip(" \"'`.:;,_|~>+")
    return cleaned.strip()


def plausible_spotify_title(value: str) -> str:
    cleaned = clean_spotify_cache_text(value)
    lowered = cleaned.lower()
    if len(cleaned) < 2 or len(cleaned) > 130:
        return ""
    if cleaned in BAD_SPOTIFY_CACHE_TEXT or cleaned.startswith("http"):
        return ""
    if any(
        marker in lowered
        for marker in (
            "type.googleapis.com",
            "spotify:",
            "xmeta#",
            "album:",
            "artist:",
            "contentagnostic.v2",
            "isrc",
            "scdn.co",
            "upload/",
        )
    ):
        return ""
    if SPOTIFY_ID_RE.match(cleaned) or re.fullmatch(r"[0-9a-fA-F-]{16,}", cleaned):
        return ""
    if not re.search(r"[A-Za-z0-9#]", cleaned):
        return ""
    return cleaned


def parse_spotify_identity_chunk(track_id: str, chunk: bytes) -> dict[str, Any] | None:
    strings = [item.decode("utf-8", errors="ignore") for item in SPOTIFY_CACHE_PRINTABLE_RE.findall(chunk)]
    for index, value in enumerate(strings):
        if "IdentityTrait" not in value or "VisualIdentityTrait" in value:
            continue

        candidates = strings[index + 1 : index + 26]
        start = 0
        for candidate_index, candidate in enumerate(candidates):
            if clean_spotify_cache_text(candidate) in ("Song", "Track"):
                start = candidate_index + 1
                break

        title = ""
        related: list[str] = []
        for candidate in candidates[start:]:
            plausible = plausible_spotify_title(candidate)
            if not plausible:
                continue
            if not title:
                title = plausible
            elif plausible != title:
                related.append(plausible)

        if title:
            return {
                "title": title,
                "album": related[0] if related else "",
                "artist": related[1] if len(related) > 1 else "",
                "provider": "Spotify local cache",
                "resolvedAt": datetime.now().isoformat(),
                "spotifyId": track_id,
            }
    return None


def spotify_identity_cache_files() -> list[Path]:
    files = []
    for root in SPOTIFY_CACHE_ROOTS:
        if not root.exists():
            continue
        try:
            for path in root.rglob("*"):
                if (
                    path.is_file()
                    and path.suffix in (".ldb", ".log")
                    and path.stat().st_size < 50_000_000
                ):
                    files.append(path)
        except OSError:
            continue
    return files


def load_local_spotify_metadata(track_ids: set[str]) -> dict[str, dict[str, Any]]:
    wanted = set(track_ids)
    if not wanted:
        return {}

    resolved: dict[str, dict[str, Any]] = {}
    identity_marker = b"contentagnostic.v2.IdentityTrait"
    for path in spotify_identity_cache_files():
        if not wanted:
            break
        try:
            blob = path.read_bytes()
        except OSError:
            continue
        if identity_marker not in blob:
            continue

        start = 0
        while wanted:
            position = blob.find(identity_marker, start)
            if position < 0:
                break
            chunk = blob[max(0, position - 500) : min(len(blob), position + 1500)]
            for raw_track_id in SPOTIFY_CACHE_TRACK_RE.findall(chunk)[-3:]:
                track_id = raw_track_id.decode("ascii", errors="ignore")
                if track_id not in wanted:
                    continue
                metadata = parse_spotify_identity_chunk(track_id, chunk)
                if metadata:
                    resolved[track_id] = metadata
                    wanted.remove(track_id)
            start = position + len(identity_marker)

    return resolved


def genre_bucket(value: str) -> str:
    lowered = value.lower()
    for token, bucket in GENRE_BUCKETS:
        if token in lowered:
            return bucket
    return ""


def parse_spotify_descriptor_chunk(track_id: str, chunk: bytes) -> str:
    strings = [item.decode("utf-8", errors="ignore") for item in SPOTIFY_CACHE_PRINTABLE_RE.findall(chunk)]
    try:
        marker_index = next(index for index, value in enumerate(strings) if "descriptorextension" in value)
    except StopIteration:
        return ""

    for value in strings[marker_index + 1 : marker_index + 24]:
        cleaned = clean_spotify_cache_text(value)
        if not cleaned or cleaned in BAD_SPOTIFY_CACHE_TEXT:
            continue
        if cleaned.startswith("concept:") or SPOTIFY_ID_RE.search(cleaned):
            continue
        bucket = genre_bucket(cleaned)
        if bucket:
            return bucket
    return ""


def load_local_spotify_genres(track_ids: set[str]) -> dict[str, str]:
    wanted = set(track_ids)
    if not wanted:
        return {}

    genres: dict[str, str] = {}
    descriptor_marker = b"descriptorextension"
    for path in spotify_identity_cache_files():
        if not wanted:
            break
        try:
            blob = path.read_bytes()
        except OSError:
            continue
        if descriptor_marker not in blob:
            continue

        start = 0
        while wanted:
            position = blob.find(descriptor_marker, start)
            if position < 0:
                break
            chunk = blob[max(0, position - 700) : min(len(blob), position + 1800)]
            for raw_track_id in SPOTIFY_CACHE_TRACK_RE.findall(chunk)[-3:]:
                track_id = raw_track_id.decode("ascii", errors="ignore")
                if track_id not in wanted:
                    continue
                genre = parse_spotify_descriptor_chunk(track_id, chunk)
                if genre:
                    genres[track_id] = genre
                    wanted.remove(track_id)
            start = position + len(descriptor_marker)

    return genres


def resolve_spotify_metadata(track_ids: set[str]) -> dict[str, dict[str, Any]]:
    cache = load_spotify_cache()
    genre_missing = {track_id for track_id in track_ids if not text(cache.get(track_id, {}).get("genre"))}
    local_genres = load_local_spotify_genres(genre_missing)
    if local_genres:
        for track_id, genre in local_genres.items():
            cache[track_id] = {**cache.get(track_id, {}), "genre": genre}
        save_spotify_cache(cache)

    missing = sorted(track_id for track_id in track_ids if not text(cache.get(track_id, {}).get("title")))
    local_metadata = load_local_spotify_metadata(set(missing))
    if local_metadata:
        cache.update(local_metadata)
        save_spotify_cache(cache)
        missing = sorted(
            track_id for track_id in track_ids if not text(cache.get(track_id, {}).get("title"))
        )

    if SPOTIFY_LOOKUP_DISABLED or not missing:
        return cache

    updated = False
    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = {executor.submit(fetch_spotify_page, track_id): track_id for track_id in missing}
        for future in as_completed(futures):
            track_id = futures[future]
            try:
                cache[track_id] = future.result()
                updated = True
            except Exception as exc:  # Keep extraction usable if Spotify blocks or times out.
                cache[track_id] = {
                    **cache.get(track_id, {}),
                    "error": str(exc),
                    "lastAttemptAt": datetime.now().isoformat(),
                }
                updated = True
            time.sleep(0.08)

    if updated:
        save_spotify_cache(cache)
    return cache


def search_text(*parts: Any) -> str:
    return " ".join(text(part).lower() for part in parts if text(part))


def extract() -> dict[str, Any]:
    if not DB_PATH.exists():
        raise FileNotFoundError(f"Rekordbox database not found at {DB_PATH}")

    Rekordbox6Database, tables = quiet_imports()
    art_by_id = spotify_art()

    with contextlib.redirect_stdout(sys.stderr):
        db = Rekordbox6Database(path=DB_PATH)

    try:
        histories = (
            db.session.query(tables.DjmdHistory)
            .order_by(tables.DjmdHistory.created_at.desc(), tables.DjmdHistory.Seq.desc())
            .all()
        )
        spotify_ids = set()
        for history in histories:
            for song in history.Songs:
                path_value = text(getattr(song.Content, "FolderPath", "")) if song.Content else ""
                match = SPOTIFY_RE.match(path_value)
                if match:
                    spotify_ids.add(match.group(1))

        spotify_meta_by_id = resolve_spotify_metadata(spotify_ids)

        sessions = []
        tracks = []
        unique_content_ids = set()

        for history in histories:
            songs = sorted(history.Songs, key=lambda song: song.TrackNo or 0)
            if not songs:
                continue

            session_tracks = []
            for song in songs:
                content = song.Content
                path_value = text(getattr(content, "FolderPath", "")) if content else ""
                match = SPOTIFY_RE.match(path_value)
                spotify_id = match.group(1) if match else ""
                spotify_meta = spotify_meta_by_id.get(spotify_id, {})
                title = display_title(content, path_value, spotify_meta) if content else "Missing content"
                artist = (
                    text(getattr(content, "ArtistName", ""))
                    or text(getattr(content, "SrcArtistName", ""))
                    or text(spotify_meta.get("artist"))
                    if content
                    else ""
                )
                track = {
                    "id": text(getattr(song, "ID", "")),
                    "historyId": text(getattr(history, "ID", "")),
                    "contentId": text(getattr(song, "ContentID", "")),
                    "trackNo": int_or_none(getattr(song, "TrackNo", None)),
                    "playedAt": iso(getattr(song, "created_at", None)),
                    "displayTitle": title,
                    "displayArtist": artist,
                    "album": (
                        text(getattr(content, "AlbumName", ""))
                        or text(spotify_meta.get("album"))
                        if content
                        else ""
                    ),
                    "genre": (
                        text(getattr(content, "GenreName", ""))
                        or text(spotify_meta.get("genre"))
                        if content
                        else ""
                    ),
                    "bpm": bpm(getattr(content, "BPM", None)) if content else None,
                    "lengthSeconds": int_or_none(getattr(content, "Length", None)) if content else None,
                    "djPlayCount": int_or_none(getattr(content, "DJPlayCount", None)) if content else None,
                    "source": source_for(path_value, content) if content else "Unknown",
                    "path": path_value,
                    "spotifyId": spotify_id,
                    "artUrl": text(spotify_meta.get("thumbnailUrl")) or art_by_id.get(spotify_id, ""),
                }
                track["searchText"] = search_text(
                    track["displayTitle"],
                    track["displayArtist"],
                    track["album"],
                    track["path"],
                    track["source"],
                )
                session_tracks.append(track)
                tracks.append(track)
                if track["contentId"]:
                    unique_content_ids.add(track["contentId"])

            started_at = iso(getattr(history, "created_at", None)) or iso(
                getattr(history, "DateCreated", None)
            )
            session = {
                "id": text(getattr(history, "ID", "")),
                "name": text(getattr(history, "Name", "")) or "Unnamed history",
                "seq": int_or_none(getattr(history, "Seq", None)),
                "startedAt": started_at,
                "dateCreated": text(getattr(history, "DateCreated", "")),
                "trackCount": len(session_tracks),
                "tracks": session_tracks,
            }
            session["searchText"] = search_text(
                session["name"],
                session["dateCreated"],
                *(track["searchText"] for track in session_tracks),
            )
            sessions.append(session)

        played_values = sorted(track["playedAt"] for track in tracks if track["playedAt"])
        return {
            "databasePath": str(DB_PATH),
            "generatedAt": datetime.now().isoformat(),
            "summary": {
                "sessionCount": len(sessions),
                "trackCount": len(tracks),
                "uniqueTrackCount": len(unique_content_ids),
                "spotifyResolvedCount": sum(
                    1 for track_id in spotify_ids if text(spotify_meta_by_id.get(track_id, {}).get("title"))
                ),
                "oldestPlayedAt": played_values[0] if played_values else None,
                "newestPlayedAt": played_values[-1] if played_values else None,
            },
            "sessions": sessions,
            "tracks": tracks,
        }
    finally:
        db.close()


def main() -> int:
    try:
        with contextlib.redirect_stdout(sys.stderr):
            payload = extract()
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
