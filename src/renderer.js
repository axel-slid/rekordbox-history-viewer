import "./styles.css";

const app = document.querySelector("#app");
const MIDI_LOG_STORAGE_KEY = "rekordbox-midi-logger-events-v1";
const MIDI_LOG_LIMIT = 20000;

const state = {
  data: null,
  selectedSessionId: null,
  activeView: "sets",
  query: "",
  source: "all",
  copiedSetSessionId: null,
  topTracksLimit: 5,
  trackSort: "recent-desc",
  sessionListScrollTop: 0,
  transitionRootKey: "",
  transitionRootInput: "",
  transitionBranchLimit: 6,
  transitionCopiedPath: "",
  transitionExpandedPaths: new Set(),
  builderRootInput: "",
  builderPath: [],
  builderActiveIndex: 0,
  builderGenre: "all",
  builderSort: "popularity",
  builderBpmTolerance: 8,
  builderVisibleCounts: new Map(),
  builderCopiedSetPath: "",
  midiStatus: "idle",
  midiError: "",
  midiInputs: [],
  midiSelectedInputId: "all",
  midiRecording: false,
  midiRecordStartedAt: 0,
  midiSessionStartedAt: "",
  midiEvents: loadStoredMidiEvents(),
  midiMonitorCount: 0,
  midiLastSeenEvent: null,
  hidStatus: "idle",
  hidError: "",
  hidDevices: [],
  hidSelectedDeviceId: "",
  hidMonitorCount: 0,
  hidLastSeenEvent: null,
  audioStatus: "idle",
  audioError: "",
  audioInputs: [],
  audioSelectedInputId: "",
  audioRecording: false,
  audioStartedAt: 0,
  audioDurationMs: 0,
  audioReady: false,
  audioMimeType: "",
  midiCopied: false,
  midiReplayRunning: false,
  midiReplayStartedAt: 0,
  midiReplayPositionMs: 0,
  midiReplayIndex: -1
};

let midiAccess = null;
let midiRenderTimer = null;
let midiSaveTimer = null;
let midiReplayTimer = null;
let activeHidDevice = null;
let audioStream = null;
let audioRecorder = null;
let audioChunks = [];
let recordedAudioBlob = null;
let audioDurationTimer = null;

function loadStoredMidiEvents() {
  try {
    const raw = window.localStorage?.getItem(MIDI_LOG_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.map((event, index) => ({ ...event, index })) : [];
  } catch {
    return [];
  }
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function fmtDate(value, options = {}) {
  if (!value) return "Unknown";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    ...options
  }).format(date);
}

function fmtDay(value) {
  return fmtDate(value, { hour: undefined, minute: undefined });
}

function ordinal(value) {
  const mod100 = value % 100;
  if (mod100 >= 11 && mod100 <= 13) return `${value}th`;
  if (value % 10 === 1) return `${value}st`;
  if (value % 10 === 2) return `${value}nd`;
  if (value % 10 === 3) return `${value}rd`;
  return `${value}th`;
}

function fmtSetDate(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Untitled Set";
  const month = new Intl.DateTimeFormat(undefined, { month: "long" }).format(date);
  return `${month} ${ordinal(date.getDate())}, ${date.getFullYear()} Set`;
}

function displaySetName(session) {
  const base = fmtSetDate(session.startedAt);
  const duplicate = session.name.match(/\((\d+)\)$/);
  return duplicate ? `${base} ${Number(duplicate[1]) + 1}` : base;
}

function dayKey(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function inclusiveDayCount(startValue, endValue) {
  const startKey = dayKey(startValue);
  const endKey = dayKey(endValue);
  if (!startKey || !endKey) return 0;
  const start = new Date(`${startKey}T00:00:00`);
  const end = new Date(`${endKey}T00:00:00`);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return 0;
  return Math.max(1, Math.floor((end - start) / 86400000) + 1);
}

function fmtDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "";
  const minutes = Math.floor(seconds / 60);
  const secs = Math.round(seconds % 60).toString().padStart(2, "0");
  return `${minutes}:${secs}`;
}

function fmtLongDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "0h";
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);
  if (!hours) return `${minutes}m`;
  if (!minutes) return `${hours}h`;
  return `${hours}h ${minutes}m`;
}

function normalizeText(value) {
  return String(value || "").toLowerCase();
}

function cleanSecondaryText(value) {
  const cleaned = String(value || "").trim();
  if (!cleaned) return "";
  if (/^spotify:/i.test(cleaned) || /^artist:/i.test(cleaned) || /^rtist:/i.test(cleaned)) return "";
  if (cleaned.toLowerCase() === "spotify") return "";
  if (cleaned.startsWith("/") || /\.(aiff?|flac|m4a|mp3|wav)$/i.test(cleaned)) return "";
  if (/^[A-Za-z0-9]{16,}#?$/.test(cleaned)) return "";
  return cleaned;
}

function trackSecondary(track) {
  const artist = cleanSecondaryText(track.displayArtist);
  if (artist) return artist;
  const album = cleanSecondaryText(track.album);
  if (album) return album;
  if (track.source === "Spotify") return "";
  return cleanSecondaryText(track.path) || track.source || "";
}

function trackDisplayLabel(track) {
  const secondary = cleanSecondaryText(track.displayArtist) || cleanSecondaryText(track.album);
  return secondary ? `${track.displayTitle} - ${secondary}` : track.displayTitle;
}

function setlistTrackLabel(track) {
  const title = track.displayTitle || track.title || "Unknown track";
  const artist = cleanSecondaryText(track.displayArtist);
  return artist ? `${title} - ${artist}` : title;
}

const CAMELOT_BY_STANDARD_KEY = new Map(
  Object.entries({
    "Abm": "1A",
    "G#m": "1A",
    "B": "1B",
    "Ebm": "2A",
    "D#m": "2A",
    "F#": "2B",
    "Gb": "2B",
    "Bbm": "3A",
    "A#m": "3A",
    "Db": "3B",
    "C#": "3B",
    "Fm": "4A",
    "Ab": "4B",
    "G#": "4B",
    "Cm": "5A",
    "Eb": "5B",
    "D#": "5B",
    "Gm": "6A",
    "Bb": "6B",
    "A#": "6B",
    "Dm": "7A",
    "F": "7B",
    "Am": "8A",
    "C": "8B",
    "Em": "9A",
    "G": "9B",
    "Bm": "10A",
    "D": "10B",
    "F#m": "11A",
    "Gbm": "11A",
    "A": "11B",
    "Dbm": "12A",
    "C#m": "12A",
    "E": "12B"
  })
);

function camelotKey(rawKey) {
  const cleaned = String(rawKey || "").trim();
  if (!cleaned || cleaned === "0") return "";
  const camelot = cleaned.match(/^(\d{1,2})\s*([ab])$/i);
  if (camelot) {
    const number = Number(camelot[1]);
    if (number >= 1 && number <= 12) return `${number}${camelot[2].toUpperCase()}`;
  }
  const normalized = cleaned
    .replace(/minor/i, "m")
    .replace(/major/i, "")
    .replace(/\s+/g, "");
  return CAMELOT_BY_STANDARD_KEY.get(normalized) || cleaned;
}

function keyHue(camelot) {
  const match = String(camelot || "").match(/^(\d{1,2})([AB])$/);
  if (!match) return 220;
  return (Number(match[1]) - 1) * 30;
}

function camelotParts(track) {
  const match = camelotKey(track?.key).match(/^(\d{1,2})([AB])$/);
  if (!match) return null;
  return {
    number: Number(match[1]),
    mode: match[2]
  };
}

function circularDistance(a, b, size = 12) {
  const direct = Math.abs(a - b);
  return Math.min(direct, size - direct);
}

function harmonicDistance(fromTrack, toTrack) {
  const from = camelotParts(fromTrack);
  const to = camelotParts(toTrack);
  if (!from || !to) return 99;
  if (from.number === to.number && from.mode === to.mode) return 0;
  if (from.number === to.number) return 1;
  const wheelDistance = circularDistance(from.number, to.number);
  return wheelDistance + (from.mode === to.mode ? 0 : 0.65);
}

function renderKeyBadge(track) {
  const key = camelotKey(track?.key);
  if (!key) return "";
  const mode = key.endsWith("A") ? "minor" : key.endsWith("B") ? "major" : "";
  return `
    <span class="key-badge" style="--key-hue: ${keyHue(key)}" title="${escapeHtml(mode ? `${key} ${mode}` : key)}">
      ${escapeHtml(key)}
    </span>
  `;
}

function renderBuilderKeyCell(track) {
  return `<span class="builder-key-cell">${renderKeyBadge(track) || `<em class="meta-placeholder">--</em>`}</span>`;
}

function canonicalTrackKey(track) {
  const title = normalizeText(track.displayTitle || track.title || "");
  const artist = normalizeText(cleanSecondaryText(track.displayArtist));
  const album = normalizeText(cleanSecondaryText(track.album));
  return [title, artist, album].join("|||");
}

function uniqueTracks(tracks) {
  const groups = new Map();
  for (const track of tracks) {
    const key = canonicalTrackKey(track);
    const playedAt = new Date(track.playedAt).getTime() || 0;
    const existing = groups.get(key);
    if (!existing) {
      groups.set(key, {
        ...track,
        firstPlayedAt: track.playedAt,
        lastPlayedAt: track.playedAt,
        playedAt: track.playedAt,
        playCount: 1,
        sources: new Set([track.source || "Unknown"])
      });
      continue;
    }

    existing.playCount += 1;
    existing.sources.add(track.source || "Unknown");

    const firstTime = new Date(existing.firstPlayedAt).getTime() || Infinity;
    if (playedAt && playedAt < firstTime) existing.firstPlayedAt = track.playedAt;

    const lastTime = new Date(existing.lastPlayedAt).getTime() || 0;
    if (playedAt >= lastTime) {
      const { firstPlayedAt, playCount, sources } = existing;
      groups.set(key, {
        ...existing,
        ...track,
        firstPlayedAt,
        lastPlayedAt: track.playedAt,
        playedAt: track.playedAt,
        playCount,
        sources
      });
    } else if (!existing.artUrl && track.artUrl) {
      existing.artUrl = track.artUrl;
    }
  }

  return Array.from(groups.values()).map((track) => ({
    ...track,
    sourceLabel: Array.from(track.sources).sort().join(" / ")
  }));
}

function sortedTracks(tracks) {
  return [...tracks].sort((a, b) => {
    if (state.trackSort === "plays-desc") {
      return (b.playCount || 0) - (a.playCount || 0) || compareTrackTitle(a, b);
    }
    if (state.trackSort === "plays-asc") {
      return (a.playCount || 0) - (b.playCount || 0) || compareTrackTitle(a, b);
    }
    const aTime = new Date(a.lastPlayedAt || a.playedAt).getTime() || 0;
    const bTime = new Date(b.lastPlayedAt || b.playedAt).getTime() || 0;
    if (state.trackSort === "recent-asc") return aTime - bTime;
    return bTime - aTime;
  });
}

function compareTrackTitle(a, b) {
  return String(a.displayTitle || "").localeCompare(String(b.displayTitle || ""));
}

function filteredTracks(tracks) {
  const query = normalizeText(state.query);
  return tracks.filter((track) => {
    if (state.source !== "all" && track.source !== state.source) return false;
    if (!query) return true;
    return track.searchText.includes(query);
  });
}

function getSessions() {
  if (!state.data) return [];
  const query = normalizeText(state.query);
  return state.data.sessions.filter((session) => {
    if (state.source !== "all" && !session.tracks.some((track) => track.source === state.source)) {
      return false;
    }
    if (!query) return true;
    return session.searchText.includes(query);
  });
}

function getSelectedSession() {
  const sessions = getSessions();
  if (!sessions.length) return null;
  return sessions.find((session) => session.id === state.selectedSessionId) || sessions[0];
}

function sourceSummary(tracks) {
  const counts = new Map();
  for (const track of tracks) {
    counts.set(track.source || "Unknown", (counts.get(track.source || "Unknown") || 0) + 1);
  }
  return Array.from(counts.entries())
    .sort((a, b) => b[1] - a[1])
    .map(([source, count]) => `${source}: ${count}`)
    .join(" · ");
}

function buildTransitionModel(data) {
  const tracks = uniqueTracks(data.tracks);
  const trackMap = new Map();
  const graph = new Map();

  for (const track of tracks) {
    trackMap.set(canonicalTrackKey(track), track);
  }

  for (const session of data.sessions) {
    for (let index = 0; index < session.tracks.length - 1; index += 1) {
      const from = session.tracks[index];
      const to = session.tracks[index + 1];
      const fromKey = canonicalTrackKey(from);
      const toKey = canonicalTrackKey(to);
      if (!fromKey || !toKey || fromKey === "||||||" || toKey === "||||||") continue;

      if (!trackMap.has(fromKey)) trackMap.set(fromKey, from);
      if (!trackMap.has(toKey)) trackMap.set(toKey, to);

      const children = graph.get(fromKey) || new Map();
      const existing = children.get(toKey) || {
        key: toKey,
        count: 0,
        examples: []
      };
      existing.count += 1;
      if (existing.examples.length < 3) {
        existing.examples.push({
          setName: displaySetName(session),
          playedAt: to.playedAt
        });
      }
      children.set(toKey, existing);
      graph.set(fromKey, children);
    }
  }

  return { trackMap, graph };
}

function transitionChildrenFor(key, model) {
  return Array.from(model.graph.get(key)?.values() || [])
    .sort((a, b) => b.count - a.count || compareTrackTitle(model.trackMap.get(a.key), model.trackMap.get(b.key)))
    .slice(0, state.transitionBranchLimit);
}

function transitionRootOptions(model) {
  return Array.from(model.trackMap.entries())
    .filter(([key]) => model.graph.has(key))
    .map(([key, track]) => ({
      key,
      label: trackDisplayLabel(track),
      playCount: track.playCount || 0
    }))
    .sort((a, b) => b.playCount - a.playCount || a.label.localeCompare(b.label));
}

function resolveTransitionRoot(model) {
  if (state.transitionRootKey && model.trackMap.has(state.transitionRootKey)) {
    return state.transitionRootKey;
  }
  const options = transitionRootOptions(model);
  return options[0]?.key || "";
}

function transitionPathText(path, model) {
  return path
    .map((key, index) => {
      const label = trackDisplayLabel(model.trackMap.get(key) || { displayTitle: "Unknown track" });
      return `${index + 1}. ${label}`;
    })
    .join("\n");
}

function transitionPathId(path) {
  return path.map((key) => encodeURIComponent(key)).join("/");
}

function builderRootOptions(model) {
  return Array.from(model.trackMap.entries())
    .map(([key, track]) => ({
      key,
      label: trackDisplayLabel(track),
      playCount: track.playCount || 0
    }))
    .sort((a, b) => b.playCount - a.playCount || a.label.localeCompare(b.label));
}

function genreOptions(data) {
  const counts = new Map();
  for (const track of data.tracks) {
    const genre = cleanSecondaryText(track.genre);
    if (!genre || genre.toLowerCase() === "unknown") continue;
    counts.set(genre, (counts.get(genre) || 0) + 1);
  }
  return Array.from(counts.entries())
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([genre, count]) => ({ genre, count }));
}

function builderContextId(index = state.builderActiveIndex) {
  return transitionPathId(state.builderPath.slice(0, index + 1));
}

function builderVisibleCount(index = state.builderActiveIndex) {
  return state.builderVisibleCounts.get(builderContextId(index)) || 5;
}

function resetBuilderChoices() {
  state.builderVisibleCounts = new Map();
}

function bpmDelta(fromTrack, toTrack) {
  if (!Number.isFinite(fromTrack?.bpm) || !Number.isFinite(toTrack?.bpm)) return Infinity;
  return Math.abs(fromTrack.bpm - toTrack.bpm);
}

function passesBuilderFilters(fromTrack, toTrack) {
  if (state.builderGenre !== "all") {
    const genre = cleanSecondaryText(toTrack.genre);
    if (genre !== state.builderGenre) return false;
  }

  const tolerance = Number(state.builderBpmTolerance);
  if (Number.isFinite(tolerance) && tolerance >= 0 && Number.isFinite(fromTrack?.bpm) && Number.isFinite(toTrack?.bpm)) {
    if (Math.abs(fromTrack.bpm - toTrack.bpm) > tolerance) return false;
  }

  return true;
}

function builderCandidatesFor(parentKey, model, pathIndex = state.builderActiveIndex) {
  const parentTrack = model.trackMap.get(parentKey);
  if (!parentTrack) return [];

  const lockedKeys = new Set(state.builderPath.slice(0, pathIndex + 1));
  const candidates = new Map();

  for (const child of model.graph.get(parentKey)?.values() || []) {
    const track = model.trackMap.get(child.key);
    if (!track || lockedKeys.has(child.key)) continue;
    candidates.set(child.key, {
      key: child.key,
      track,
      transitionCount: child.count || 0,
      historical: true
    });
  }

  for (const [key, track] of model.trackMap.entries()) {
    if (lockedKeys.has(key) || candidates.has(key)) continue;
    candidates.set(key, {
      key,
      track,
      transitionCount: 0,
      historical: false
    });
  }

  return Array.from(candidates.values())
    .filter((candidate) => passesBuilderFilters(parentTrack, candidate.track))
    .map((candidate) => ({
      ...candidate,
      harmonicDistance: harmonicDistance(parentTrack, candidate.track),
      bpmDelta: bpmDelta(parentTrack, candidate.track)
    }))
    .sort((a, b) => {
      if (state.builderSort === "harmonic") {
        return (
          a.harmonicDistance - b.harmonicDistance ||
          a.bpmDelta - b.bpmDelta ||
          b.transitionCount - a.transitionCount ||
          (b.track.playCount || 0) - (a.track.playCount || 0) ||
          compareTrackTitle(a.track, b.track)
        );
      }
      return (
        b.transitionCount - a.transitionCount ||
        (b.track.playCount || 0) - (a.track.playCount || 0) ||
        a.harmonicDistance - b.harmonicDistance ||
        a.bpmDelta - b.bpmDelta ||
        compareTrackTitle(a.track, b.track)
      );
    });
}

function buildStats(data) {
  const dayCounts = new Map();
  const hourCounts = new Map();
  const trackCounts = new Map();
  const sourceCounts = new Map();
  const genreCounts = new Map();
  let bpmTotal = 0;
  let bpmCount = 0;
  let totalSeconds = 0;

  for (const track of data.tracks) {
    const key = dayKey(track.playedAt);
    if (key) dayCounts.set(key, (dayCounts.get(key) || 0) + 1);

    const date = new Date(track.playedAt);
    if (!Number.isNaN(date.getTime())) {
      const hour = date.getHours();
      hourCounts.set(hour, (hourCounts.get(hour) || 0) + 1);
    }

    const title = track.displayTitle || "Untitled";
    const artist = track.displayArtist || "";
    const trackKey = `${title}|||${artist}`;
    const entry = trackCounts.get(trackKey) || { title, artist, count: 0, artUrl: track.artUrl };
    entry.count += 1;
    if (!entry.artUrl && track.artUrl) entry.artUrl = track.artUrl;
    trackCounts.set(trackKey, entry);

    sourceCounts.set(track.source, (sourceCounts.get(track.source) || 0) + 1);
    const genre = cleanSecondaryText(track.genre);
    if (genre && genre.toLowerCase() !== "unknown") {
      genreCounts.set(genre, (genreCounts.get(genre) || 0) + 1);
    }
    if (Number.isFinite(track.bpm)) {
      bpmTotal += track.bpm;
      bpmCount += 1;
    }
    if (Number.isFinite(track.lengthSeconds)) {
      totalSeconds += track.lengthSeconds;
    }
  }

  const topDay = Array.from(dayCounts.entries()).sort((a, b) => b[1] - a[1])[0];
  const topHour = Array.from(hourCounts.entries()).sort((a, b) => b[1] - a[1])[0];
  const topTracks = Array.from(trackCounts.values())
    .sort((a, b) => b.count - a.count);
  const sourceBreakdown = Array.from(sourceCounts.entries()).sort((a, b) => b[1] - a[1]);
  const genreBreakdown = Array.from(genreCounts.entries()).sort((a, b) => b[1] - a[1]);
  const rangeDays = inclusiveDayCount(data.summary.oldestPlayedAt, data.summary.newestPlayedAt);

  return {
    dayCounts,
    activeDays: dayCounts.size,
    rangeDays,
    avgPlaysPerDay: rangeDays ? data.tracks.length / rangeDays : 0,
    topDay,
    topHour,
    topTracks,
    sourceBreakdown,
    genreBreakdown,
    avgBpm: bpmCount ? bpmTotal / bpmCount : 0,
    totalSeconds,
    avgSecondsPerActiveDay: dayCounts.size ? totalSeconds / dayCounts.size : 0,
    avgSecondsPerDay: rangeDays ? totalSeconds / rangeDays : 0
  };
}

function stat(label, value, sub = "") {
  return `
    <div class="stat">
      <span>${escapeHtml(label)}</span>
      <strong>${escapeHtml(value)}</strong>
      ${sub ? `<em>${escapeHtml(sub)}</em>` : ""}
    </div>
  `;
}

function levelFor(count, max) {
  if (!count) return 0;
  if (max <= 1) return 1;
  const ratio = count / max;
  if (ratio > 0.75) return 4;
  if (ratio > 0.45) return 3;
  if (ratio > 0.2) return 2;
  return 1;
}

function renderActivityGrid(stats) {
  const dates = Array.from(stats.dayCounts.keys()).sort();
  if (!dates.length) return "";

  const start = new Date(`${dates[0]}T00:00:00`);
  const end = new Date(`${dates.at(-1)}T00:00:00`);
  start.setDate(start.getDate() - start.getDay());
  end.setDate(end.getDate() + (6 - end.getDay()));

  const cells = [];
  const monthLabels = [];
  let previousMonth = "";
  let lastMonthLabelWeek = -99;
  const max = Math.max(...stats.dayCounts.values());
  let index = 0;
  for (const cursor = new Date(start); cursor <= end; cursor.setDate(cursor.getDate() + 1)) {
    const key = dayKey(cursor);
    const count = stats.dayCounts.get(key) || 0;
    const weekIndex = Math.floor(index / 7) + 1;
    const monthKey = `${cursor.getFullYear()}-${cursor.getMonth()}`;
    if ((index === 0 || cursor.getDate() <= 7) && monthKey !== previousMonth) {
      monthLabels.push(`
        <span class="activity-month" style="grid-column: ${weekIndex}">
          ${weekIndex - lastMonthLabelWeek >= 4 ? escapeHtml(new Intl.DateTimeFormat(undefined, { month: "short" }).format(cursor)) : ""}
        </span>
      `);
      if (weekIndex - lastMonthLabelWeek >= 4) lastMonthLabelWeek = weekIndex;
      previousMonth = monthKey;
    }
    cells.push(`
      <span
        class="activity-cell level-${levelFor(count, max)}"
        style="--cell-delay: ${Math.min(cells.length, 120) * 7}ms"
        title="${escapeHtml(`${fmtDay(cursor)}: ${count} plays`)}"
      ></span>
    `);
    index += 1;
  }

  const weekCount = Math.ceil(cells.length / 7);
  const yearStart = new Date(`${dates[0]}T00:00:00`).getFullYear();
  const yearEnd = new Date(`${dates.at(-1)}T00:00:00`).getFullYear();
  const yearLabel = yearStart === yearEnd ? `${yearStart}` : `${yearStart}-${yearEnd}`;
  return `
    <section class="activity-card">
      <div class="section-heading">
        <div>
          <p class="eyebrow">Stats</p>
          <h2>Play Activity</h2>
        </div>
        <span>${yearLabel} · ${stats.activeDays} active days</span>
      </div>
      <div class="activity-board">
        <div class="activity-years">
          <span>${escapeHtml(yearLabel)}</span>
        </div>
        <div class="activity-weekdays" aria-hidden="true">
          <span></span>
          <span>Mon</span>
          <span></span>
          <span>Wed</span>
          <span></span>
          <span>Fri</span>
          <span></span>
        </div>
        <div class="activity-scroll">
          <div class="activity-months" style="grid-template-columns: repeat(${weekCount}, 12px)">
            ${monthLabels.join("")}
          </div>
          <div class="activity-grid" style="grid-template-columns: repeat(${weekCount}, 12px)">
            ${cells.join("")}
          </div>
        </div>
      </div>
      <div class="activity-legend">
        <span>Less</span><i class="level-0"></i><i class="level-1"></i><i class="level-2"></i><i class="level-3"></i><i class="level-4"></i><span>More</span>
      </div>
    </section>
  `;
}

function renderGenreDonut(stats) {
  const palette = ["#334ccf", "#0891b2", "#f59e0b", "#e11d48", "#7c3aed", "#475569", "#a855f7"];
  const visible = stats.genreBreakdown.slice(0, 6);
  const remainder = stats.genreBreakdown.slice(6).reduce((sum, [, count]) => sum + count, 0);
  const segments = remainder ? [...visible, ["Other", remainder]] : visible;
  const total = segments.reduce((sum, [, count]) => sum + count, 0);

  if (!total) {
    return `
      <section class="genre-card">
        <div class="section-heading">
          <div>
            <p class="eyebrow">Genres</p>
            <h2>Genre Mix</h2>
          </div>
        </div>
        <p class="empty compact">No genre metadata found yet.</p>
      </section>
    `;
  }

  let cursor = 0;
  const gradient = segments
    .map(([, count], index) => {
      const start = cursor;
      const end = cursor + (count / total) * 360;
      cursor = end;
      return `${palette[index % palette.length]} ${start.toFixed(2)}deg ${end.toFixed(2)}deg`;
    })
    .join(", ");

  return `
    <section class="genre-card">
      <div class="section-heading">
        <div>
          <p class="eyebrow">Genres</p>
          <h2>Genre Mix</h2>
        </div>
      </div>
      <div class="donut-wrap">
        <div class="donut" style="background: conic-gradient(${gradient})">
          <span>${escapeHtml(segments[0][0])}</span>
        </div>
        <div class="genre-list">
          ${segments
            .map(([genre, count], index) => {
              const percent = Math.round((count / total) * 100);
              return `
                <div class="genre-row">
                  <i style="background: ${palette[index % palette.length]}"></i>
                  <span>${escapeHtml(genre)}</span>
                  <em>${percent}%</em>
                </div>
              `;
            })
            .join("")}
        </div>
      </div>
    </section>
  `;
}

function renderStatsSection(data) {
  const stats = buildStats(data);
  const visibleTopTracks = stats.topTracks.slice(0, state.topTracksLimit);
  const peakHour = stats.topHour
    ? `${String(stats.topHour[0]).padStart(2, "0")}:00`
    : "Unknown";
  const topSource = stats.sourceBreakdown[0]
    ? `${stats.sourceBreakdown[0][0]} (${stats.sourceBreakdown[0][1].toLocaleString()})`
    : "Unknown";

  return `
    <section class="stats-panel">
      <section class="stats-top">
        ${renderActivityGrid(stats)}
        ${renderGenreDonut(stats)}
      </section>
      <section class="insights-card">
        <div class="section-heading">
          <div>
            <p class="eyebrow">Library</p>
            <h2>Listening Stats</h2>
          </div>
        </div>
        <div class="mini-stats">
          ${stat("Total play time", fmtLongDuration(stats.totalSeconds))}
          ${stat("Avg time / day", fmtLongDuration(stats.avgSecondsPerDay), `${stats.rangeDays.toLocaleString()} days`)}
          ${stat("Avg plays / day", stats.avgPlaysPerDay.toFixed(1), `${stats.rangeDays.toLocaleString()} days`)}
          ${stat("Busiest day", stats.topDay ? fmtDay(`${stats.topDay[0]}T00:00:00`) : "Unknown", stats.topDay ? `${stats.topDay[1]} plays` : "")}
          ${stat("Peak hour", peakHour)}
          ${stat("Top source", topSource)}
          ${stat("Avg BPM", stats.avgBpm ? stats.avgBpm.toFixed(1) : "Unknown")}
        </div>
        <div class="top-tracks">
          <div class="top-tracks-head">
            <h3>Most repeated</h3>
            ${
              state.topTracksLimit < stats.topTracks.length
                ? `<button class="text-button" data-load-more-top-tracks type="button">Load more</button>`
                : ""
            }
          </div>
          ${visibleTopTracks.map(renderTopTrack).join("")}
        </div>
      </section>
    </section>
  `;
}

function renderTopTrack(track, index = 0) {
  const cover = track.artUrl
    ? `<img src="${escapeHtml(track.artUrl)}" alt="" loading="lazy" />`
    : `<span>${escapeHtml(track.title.slice(0, 1).toUpperCase())}</span>`;
  return `
    <div class="top-track animated-row" style="--row-delay: ${index * 28}ms">
      <div class="small-cover">${cover}</div>
      <div>
        <strong>${escapeHtml(track.title)}</strong>
        ${track.artist ? `<span>${escapeHtml(track.artist)}</span>` : ""}
      </div>
      <em>${track.count}</em>
    </div>
  `;
}

function renderShell() {
  app.innerHTML = `
    <header class="topbar">
      <div class="brand-block">
        <div>
          <p class="eyebrow">Rekordbox</p>
          <h1>Played Track History</h1>
        </div>
        <nav class="view-tabs" aria-label="Primary views">
          <button data-view="sets" type="button">Sets</button>
          <button data-view="stats" type="button">Stats</button>
          <button data-view="tracks" type="button">Tracks</button>
          <button data-view="paths" type="button">Paths</button>
          <button data-view="builder" type="button">Set Builder</button>
          <button data-view="midi" type="button">MIDI Logger</button>
        </nav>
      </div>
      <div class="toolbar">
        <input id="search" type="search" placeholder="Search sessions, tracks, artists" value="${escapeHtml(state.query)}" />
        <select id="source-filter" aria-label="Source filter">
          <option value="all">All sources</option>
        </select>
        <button id="refresh" type="button">Refresh</button>
      </div>
    </header>
    <section id="status" class="status">Loading Rekordbox history...</section>
  `;

  document.querySelector("#search").addEventListener("input", (event) => {
    state.query = event.target.value;
    renderDashboard();
  });
  document.querySelector("#source-filter").addEventListener("change", (event) => {
    state.source = event.target.value;
    renderDashboard();
  });
  document.querySelector("#refresh").addEventListener("click", () => loadHistory(true));
  document.querySelectorAll("[data-view]").forEach((button) => {
    button.addEventListener("click", () => {
      if (state.activeView === button.dataset.view) return;
      state.activeView = button.dataset.view;
      renderDashboard();
      window.scrollTo({ top: 0, left: 0, behavior: "smooth" });
    });
  });
}

function renderError(error) {
  document.querySelector("#status").className = "status error";
  document.querySelector("#status").innerHTML = `
    <strong>Could not load Rekordbox history.</strong>
    <span>${escapeHtml(error?.message || "Unknown extractor error")}</span>
  `;
}

function renderDashboard() {
  if (!state.data) return;

  const existingSessionList = document.querySelector(".session-list");
  if (existingSessionList) {
    state.sessionListScrollTop = existingSessionList.scrollTop;
  }

  const sessions = getSessions();
  const selected = getSelectedSession();
  if (selected) state.selectedSessionId = selected.id;

  const sourceOptions = new Set(state.data.tracks.map((track) => track.source));
  const sourceFilter = document.querySelector("#source-filter");
  if (sourceFilter) {
    sourceFilter.innerHTML = [
      `<option value="all">All sources</option>`,
      ...Array.from(sourceOptions)
        .sort()
        .map((source) => `<option value="${escapeHtml(source)}">${escapeHtml(source)}</option>`)
    ].join("");
    sourceFilter.value = state.source;
  }

  const main = `
    <div id="dashboard">
      ${renderSummary()}
      ${renderActiveView(sessions, selected)}
    </div>
  `;

  const previous = document.querySelector("#dashboard");
  if (previous) {
    previous.outerHTML = main;
  } else {
    document.querySelector("#status").outerHTML = main;
  }

  document.querySelectorAll("[data-session-id]").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedSessionId = button.dataset.sessionId;
      renderDashboard();
    });
  });
  document.querySelectorAll("[data-view]").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.view === state.activeView);
  });
  const trackSort = document.querySelector("[data-track-sort]");
  if (trackSort) {
    trackSort.value = state.trackSort;
    trackSort.addEventListener("change", (event) => {
      state.trackSort = event.target.value;
      renderDashboard();
      window.scrollTo({ top: 0, left: 0, behavior: "smooth" });
    });
  }
  document.querySelectorAll("[data-download-setlist-id]").forEach((button) => {
    button.addEventListener("click", () => {
      const session = state.data.sessions.find((item) => item.id === button.dataset.downloadSetlistId);
      if (session) downloadSetlist(session);
    });
  });
  document.querySelectorAll("[data-copy-set-id]").forEach((button) => {
    button.addEventListener("click", async () => {
      const session = state.data.sessions.find((item) => item.id === button.dataset.copySetId);
      if (!session) return;
      await copyText(formatTimedSetlist(session));
      state.copiedSetSessionId = session.id;
      renderDashboard();
    });
  });
  document.querySelectorAll("[data-load-more-top-tracks]").forEach((button) => {
    button.addEventListener("click", () => {
      state.topTracksLimit *= 2;
      renderDashboard();
    });
  });
  const transitionRootInput = document.querySelector("[data-transition-root-input]");
  if (transitionRootInput) {
    transitionRootInput.addEventListener("input", (event) => {
      state.transitionRootInput = event.target.value;
    });
  }
  const transitionRootForm = document.querySelector("[data-transition-root-form]");
  if (transitionRootForm) {
    transitionRootForm.addEventListener("submit", (event) => {
      event.preventDefault();
      const model = buildTransitionModel(state.data);
      const options = transitionRootOptions(model);
      const typed = normalizeText(state.transitionRootInput);
      const selected =
        options.find((option) => normalizeText(option.label) === typed) ||
        options.find((option) => normalizeText(option.label).includes(typed));
      if (selected) {
        state.transitionRootKey = selected.key;
        state.transitionRootInput = selected.label;
        state.transitionCopiedPath = "";
        state.transitionExpandedPaths = new Set();
        renderDashboard();
      }
    });
  }
  document.querySelectorAll("[data-transition-root-key]").forEach((button) => {
    button.addEventListener("click", () => {
      state.transitionRootKey = button.dataset.transitionRootKey;
      const model = buildTransitionModel(state.data);
      const track = model.trackMap.get(state.transitionRootKey);
      state.transitionRootInput = track ? trackDisplayLabel(track) : "";
      state.transitionCopiedPath = "";
      state.transitionExpandedPaths = new Set();
      renderDashboard();
    });
  });
  document.querySelectorAll("[data-reset-transition-tree]").forEach((button) => {
    button.addEventListener("click", () => {
      state.transitionExpandedPaths = new Set();
      state.transitionCopiedPath = "";
      renderDashboard();
    });
  });
  document.querySelectorAll("[data-expand-transition-path]").forEach((button) => {
    button.addEventListener("click", () => {
      const pathId = button.dataset.expandTransitionPath;
      if (!pathId) return;
      if (state.transitionExpandedPaths.has(pathId)) {
        state.transitionExpandedPaths.delete(pathId);
      } else {
        state.transitionExpandedPaths.add(pathId);
      }
      state.transitionCopiedPath = "";
      renderDashboard();
    });
  });
  document.querySelectorAll("[data-copy-transition-path]").forEach((button) => {
    button.addEventListener("click", async () => {
      const path = button.dataset.copyTransitionPath || "";
      try {
        await copyText(path);
        state.transitionCopiedPath = path;
      } catch {
        state.transitionCopiedPath = "Copy failed";
      }
      renderDashboard();
    });
  });
  const builderRootInput = document.querySelector("[data-builder-root-input]");
  if (builderRootInput) {
    builderRootInput.addEventListener("input", (event) => {
      state.builderRootInput = event.target.value;
    });
  }
  const builderRootForm = document.querySelector("[data-builder-root-form]");
  if (builderRootForm) {
    builderRootForm.addEventListener("submit", (event) => {
      event.preventDefault();
      const model = buildTransitionModel(state.data);
      const typed = normalizeText(state.builderRootInput);
      const selected =
        builderRootOptions(model).find((option) => normalizeText(option.label) === typed) ||
        builderRootOptions(model).find((option) => normalizeText(option.label).includes(typed));
      if (selected) {
        state.builderPath = [selected.key];
        state.builderRootInput = selected.label;
        state.builderActiveIndex = 0;
        resetBuilderChoices();
        renderDashboard();
      }
    });
  }
  document.querySelectorAll("[data-builder-root-key]").forEach((button) => {
    button.addEventListener("click", () => {
      const model = buildTransitionModel(state.data);
      const track = model.trackMap.get(button.dataset.builderRootKey);
      state.builderPath = [button.dataset.builderRootKey];
      state.builderRootInput = track ? trackDisplayLabel(track) : "";
      state.builderActiveIndex = 0;
      resetBuilderChoices();
      renderDashboard();
    });
  });
  const builderGenre = document.querySelector("[data-builder-genre]");
  if (builderGenre) {
    builderGenre.value = state.builderGenre;
    builderGenre.addEventListener("change", (event) => {
      state.builderGenre = event.target.value;
      resetBuilderChoices();
      renderDashboard();
    });
  }
  const builderSort = document.querySelector("[data-builder-sort]");
  if (builderSort) {
    builderSort.value = state.builderSort;
    builderSort.addEventListener("change", (event) => {
      state.builderSort = event.target.value;
      resetBuilderChoices();
      renderDashboard();
    });
  }
  const builderBpmTolerance = document.querySelector("[data-builder-bpm-tolerance]");
  if (builderBpmTolerance) {
    builderBpmTolerance.value = String(state.builderBpmTolerance);
    builderBpmTolerance.addEventListener("change", (event) => {
      state.builderBpmTolerance = Math.max(0, Number(event.target.value) || 0);
      resetBuilderChoices();
      renderDashboard();
    });
  }
  const copyBuilderSet = document.querySelector("[data-copy-builder-set]");
  if (copyBuilderSet) {
    copyBuilderSet.addEventListener("click", async () => {
      const model = buildTransitionModel(state.data);
      await copyText(formatBuilderSetlist(model));
      state.builderCopiedSetPath = transitionPathId(state.builderPath);
      renderDashboard();
    });
  }
  document.querySelectorAll("[data-builder-open-index]").forEach((button) => {
    button.addEventListener("click", () => {
      state.builderActiveIndex = Number(button.dataset.builderOpenIndex) || 0;
      renderDashboard();
    });
  });
  document.querySelectorAll("[data-builder-select-key]").forEach((button) => {
    button.addEventListener("click", () => {
      const index = Number(button.dataset.builderSelectIndex) || 0;
      state.builderPath = [...state.builderPath.slice(0, index + 1), button.dataset.builderSelectKey];
      state.builderActiveIndex = index + 1;
      renderDashboard();
    });
  });
  document.querySelectorAll("[data-builder-load-more]").forEach((button) => {
    button.addEventListener("click", () => {
      const index = Number(button.dataset.builderLoadMore) || 0;
      const contextId = builderContextId(index);
      state.builderVisibleCounts.set(contextId, builderVisibleCount(index) + 5);
      state.builderActiveIndex = index;
      renderDashboard();
    });
  });
  const midiInputSelect = document.querySelector("[data-midi-input]");
  if (midiInputSelect) {
    midiInputSelect.value = state.midiSelectedInputId;
    midiInputSelect.addEventListener("change", (event) => {
      state.midiSelectedInputId = event.target.value;
      renderDashboard();
    });
  }
  const audioInputSelect = document.querySelector("[data-audio-input]");
  if (audioInputSelect) {
    audioInputSelect.value = state.audioSelectedInputId;
    audioInputSelect.addEventListener("change", (event) => {
      state.audioSelectedInputId = event.target.value;
      renderDashboard();
    });
  }
  document.querySelector("[data-midi-connect]")?.addEventListener("click", () => {
    connectMidi();
  });
  document.querySelector("[data-hid-connect]")?.addEventListener("click", () => {
    connectHid();
  });
  document.querySelector("[data-audio-connect]")?.addEventListener("click", () => {
    connectAudioDevices();
  });
  document.querySelector("[data-audio-record]")?.addEventListener("click", () => {
    toggleSetAudioRecording();
  });
  document.querySelector("[data-audio-download]")?.addEventListener("click", () => {
    downloadRecordedAudio();
  });
  document.querySelector("[data-midi-record]")?.addEventListener("click", () => {
    toggleMidiRecording();
  });
  document.querySelector("[data-midi-replay]")?.addEventListener("click", () => {
    toggleMidiReplay();
  });
  document.querySelector("[data-midi-clear]")?.addEventListener("click", () => {
    clearMidiLog();
  });
  document.querySelector("[data-midi-export-json]")?.addEventListener("click", () => {
    downloadMidiLog("json");
  });
  document.querySelector("[data-midi-export-csv]")?.addEventListener("click", () => {
    downloadMidiLog("csv");
  });
  document.querySelector("[data-midi-copy]")?.addEventListener("click", async () => {
    await copyText(formatMidiLogText());
    state.midiCopied = true;
    renderDashboard();
  });

  const newSessionList = document.querySelector(".session-list");
  if (newSessionList) {
    newSessionList.scrollTop = state.sessionListScrollTop;
    newSessionList.addEventListener("scroll", () => {
      state.sessionListScrollTop = newSessionList.scrollTop;
    });
  }
}

function renderSummary() {
  return `
    <section class="summary">
      ${stat("Sets", state.data.summary.sessionCount.toLocaleString())}
      ${stat("Played rows", state.data.summary.trackCount.toLocaleString())}
      ${stat("Unique tracks", state.data.summary.uniqueTrackCount.toLocaleString())}
      ${stat("Range", `${fmtDay(state.data.summary.oldestPlayedAt)} - ${fmtDay(state.data.summary.newestPlayedAt)}`)}
    </section>
  `;
}

function renderActiveView(sessions, selected) {
  if (state.activeView === "stats") return renderStatsView();
  if (state.activeView === "tracks") return renderTracksView();
  if (state.activeView === "paths") return renderPathsView();
  if (state.activeView === "builder") return renderSetBuilderView();
  if (state.activeView === "midi") return renderMidiLoggerView();
  return renderSetsView(sessions, selected);
}

function renderStatsView() {
  return `
    <main class="view-page stats-view">
      ${renderStatsSection(state.data)}
    </main>
  `;
}

function renderTracksView() {
  const tracks = sortedTracks(uniqueTracks(filteredTracks(state.data.tracks)));
  return `
    <main class="view-page tracks-view">
      <header class="view-header">
        <div>
          <p class="eyebrow">Tracks</p>
          <h2>Track Library</h2>
        </div>
        <div class="view-actions">
          <span>${tracks.length.toLocaleString()} visible</span>
          <select data-track-sort aria-label="Sort tracks">
            <option value="recent-desc">Newest first</option>
            <option value="recent-asc">Oldest first</option>
            <option value="plays-desc">Most plays</option>
            <option value="plays-asc">Least plays</option>
          </select>
        </div>
      </header>
      <section class="track-panel full-panel">
        <div class="table-wrap">
          ${renderTrackTable(tracks, { sequential: true, unique: true })}
        </div>
      </section>
    </main>
  `;
}

function renderMidiLoggerView() {
  const eventCount = state.midiEvents.length;
  const lastEvent = state.midiEvents.at(-1);
  const latestEvents = state.midiEvents.slice(-160).reverse();
  const selectedInput = state.midiInputs.find((input) => input.id === state.midiSelectedInputId);
  const flxInputs = state.midiInputs.filter((input) => isFlx10Input(input));
  const statusText =
    state.midiStatus === "connected"
      ? `${state.midiInputs.length} MIDI input${state.midiInputs.length === 1 ? "" : "s"} connected`
      : state.midiStatus === "error"
        ? "MIDI unavailable"
        : "MIDI not connected";
  const replayDuration = Math.max(lastEvent?.relativeMs || 0, 1);
  const replayPercent = Math.min(100, (state.midiReplayPositionMs / replayDuration) * 100);

  return `
    <main class="view-page midi-view">
      <header class="view-header">
        <div>
          <p class="eyebrow">MIDI Logger</p>
          <h2>FLX10 Action Capture</h2>
        </div>
        <div class="view-actions">
          <span>${eventCount.toLocaleString()} events</span>
          ${state.midiCopied ? `<span>Copied</span>` : ""}
          <button data-midi-connect type="button">${midiAccess ? "Refresh MIDI" : "Connect MIDI"}</button>
          <button data-hid-connect type="button">${activeHidDevice ? "Refresh HID" : "Connect HID"}</button>
          <button data-midi-record type="button">${state.midiRecording ? "Stop Logging" : "Start Logging"}</button>
        </div>
      </header>
      <section class="midi-panel">
        <div class="midi-controls">
          <div class="midi-status-line">
            <strong>${escapeHtml(statusText)}</strong>
            <span>${escapeHtml(midiStatusDetail(flxInputs, selectedInput))}</span>
          </div>
          <label>
            <span>Input</span>
            <select data-midi-input>
              <option value="all">All MIDI inputs</option>
              ${state.midiInputs
                .map(
                  (input) => `
                    <option value="${escapeHtml(input.id)}">
                      ${escapeHtml(input.name)}${isFlx10Input(input) ? " (FLX10)" : ""}
                    </option>
                  `
                )
                .join("")}
            </select>
          </label>
          <div class="midi-status-line">
            <strong>${escapeHtml(hidStatusText())}</strong>
            <span>${escapeHtml(hidStatusDetail())}</span>
          </div>
          <div class="midi-actions">
            <button data-midi-replay type="button" ${eventCount ? "" : "disabled"}>${state.midiReplayRunning ? "Stop Replay" : "Replay Log"}</button>
            <button data-midi-copy type="button" ${eventCount ? "" : "disabled"}>Copy Log</button>
            <button data-midi-export-json type="button" ${eventCount ? "" : "disabled"}>Export JSON</button>
            <button data-midi-export-csv type="button" ${eventCount ? "" : "disabled"}>Export CSV</button>
            <button data-midi-clear type="button" ${eventCount ? "" : "disabled"}>Clear</button>
          </div>
        </div>
        ${
          state.midiError
            ? `<p class="midi-error">${escapeHtml(state.midiError)}</p>`
            : state.hidError
              ? `<p class="midi-error">${escapeHtml(state.hidError)}</p>`
              : `<p class="midi-note">This records future controller actions only. Try MIDI first; if Rekordbox responds but MIDI stays at 0, click Connect HID because the FLX10 may be sending controller reports outside plain MIDI.</p>`
        }
        <div class="audio-recorder">
          <div class="audio-recorder-head">
            <div>
              <strong>${escapeHtml(audioStatusText())}</strong>
              <span>${escapeHtml(audioStatusDetail())}</span>
            </div>
            <div class="midi-actions">
              <button data-audio-connect type="button">${state.audioInputs.length ? "Refresh Audio Inputs" : "Connect Audio"}</button>
              <button data-audio-record type="button">${state.audioRecording ? "Stop Audio" : "Start Audio"}</button>
              <button data-audio-download type="button" ${state.audioReady ? "" : "disabled"}>Download Audio File</button>
            </div>
          </div>
          <label>
            <span>Audio input</span>
            <select data-audio-input>
              <option value="">Default audio input</option>
              ${state.audioInputs
                .map(
                  (input) => `
                    <option value="${escapeHtml(input.deviceId)}">
                      ${escapeHtml(input.label || "Unnamed audio input")}
                    </option>
                  `
                )
                .join("")}
            </select>
          </label>
        </div>
        <div class="midi-replay">
          <div class="midi-replay-head">
            <span>${state.midiReplayRunning ? "Replaying action log" : "Replay timeline"}</span>
            <span>${fmtRelativeTimestamp(state.midiReplayPositionMs)} / ${fmtRelativeTimestamp(replayDuration)}</span>
          </div>
          <div class="midi-replay-bar">
            <i style="width: ${replayPercent.toFixed(2)}%"></i>
          </div>
        </div>
        <div class="midi-live-grid">
          ${midiStat("Recording", state.midiRecording ? "On" : "Off", state.midiSessionStartedAt ? fmtDate(state.midiSessionStartedAt) : "No active session")}
          ${midiStat("Incoming MIDI", state.midiMonitorCount ? state.midiMonitorCount.toLocaleString() : "0", state.midiLastSeenEvent ? `${state.midiLastSeenEvent.action} · ${state.midiLastSeenEvent.inputName}` : "Move a control to test")}
          ${midiStat("HID reports", state.hidMonitorCount ? state.hidMonitorCount.toLocaleString() : "0", state.hidLastSeenEvent ? `${state.hidLastSeenEvent.action} · ${state.hidLastSeenEvent.inputName}` : "Try Connect HID")}
          ${midiStat("Set audio", state.audioRecording ? fmtRelativeTimestamp(state.audioDurationMs) : state.audioReady ? "Ready" : "Not recorded", state.audioMimeType || "Choose FLX10/master input")}
          ${midiStat("Last recorded", lastEvent ? lastEvent.action : "None", lastEvent ? fmtRelativeTimestamp(lastEvent.relativeMs) : "")}
          ${midiStat("FLX10 inputs", flxInputs.length ? flxInputs.length.toLocaleString() : "0", flxInputs[0]?.name || "Connect the controller, then refresh")}
          ${midiStat("Replay cursor", state.midiReplayIndex >= 0 ? `${state.midiReplayIndex + 1} / ${eventCount}` : "Idle", state.midiReplayRunning ? "Visual replay" : "")}
        </div>
        <section class="midi-log">
          <div class="midi-log-head">
            <h3>Captured MIDI Actions</h3>
            <span>${latestEvents.length ? "Newest first" : "No MIDI actions captured yet"}</span>
          </div>
          <div class="midi-table">
            ${latestEvents.length ? latestEvents.map(renderMidiEventRow).join("") : `<p class="empty compact">Connect the FLX10, choose the input, then start logging.</p>`}
          </div>
        </section>
      </section>
    </main>
  `;
}

function midiStat(label, value, sub = "") {
  return `
    <div class="midi-stat">
      <span>${escapeHtml(label)}</span>
      <strong>${escapeHtml(value)}</strong>
      ${sub ? `<em>${escapeHtml(sub)}</em>` : ""}
    </div>
  `;
}

function renderMidiEventRow(event) {
  const isReplayActive = state.midiReplayRunning && event.index === state.midiReplayIndex;
  return `
    <div class="midi-row${isReplayActive ? " is-replay-active" : ""}">
      <span>${escapeHtml(fmtRelativeTimestamp(event.relativeMs))}</span>
      <strong>${escapeHtml(event.action)}</strong>
      <em>${escapeHtml(event.detail)}</em>
      <em>${escapeHtml(event.inputName)}</em>
      <code>${escapeHtml(event.dataHex)}</code>
    </div>
  `;
}

function isFlx10Input(input) {
  return /flx\s*10|flx10|ddj-flx10|ddj flx10/i.test(`${input?.name || ""} ${input?.manufacturer || ""}`);
}

function midiStatusDetail(flxInputs, selectedInput) {
  if (state.midiError) return state.midiError;
  if (state.midiRecording) return `Logging ${selectedInput ? selectedInput.name : state.midiSelectedInputId === "all" ? "all inputs" : "selected input"}`;
  if (flxInputs.length) return `${flxInputs[0].name} detected`;
  if (state.midiInputs.length) return "No FLX10-named input found; choose the controller input manually";
  return "Connect the DDJ-FLX10, then click Connect MIDI";
}

function hidStatusText() {
  if (state.hidStatus === "connected") return `${state.hidDevices.length || 1} HID device${state.hidDevices.length === 1 ? "" : "s"} allowed`;
  if (state.hidStatus === "error") return "HID unavailable";
  return "HID not connected";
}

function hidStatusDetail() {
  if (state.hidError) return state.hidError;
  if (activeHidDevice) return `${activeHidDevice.productName || "Controller"} opened for raw reports`;
  if (state.hidDevices.length) return `${state.hidDevices[0].productName || "Controller"} permission found`;
  return "Use this if Rekordbox moves but MIDI stays at 0";
}

function audioStatusText() {
  if (state.audioRecording) return "Recording set audio";
  if (state.audioReady) return "Set audio ready";
  if (state.audioStatus === "connected") return `${state.audioInputs.length} audio input${state.audioInputs.length === 1 ? "" : "s"} found`;
  if (state.audioStatus === "error") return "Audio recorder unavailable";
  return "Set audio not connected";
}

function audioStatusDetail() {
  if (state.audioError) return state.audioError;
  if (state.audioRecording) return `Capturing ${selectedAudioInputLabel()} for ${fmtRelativeTimestamp(state.audioDurationMs)}`;
  if (state.audioReady) return "Download this recording as the audio file for the set";
  if (state.audioInputs.length) return "Select the FLX10, mixer, loopback, or master-output input before recording";
  return "Connect an audio input to record the real mix while you play";
}

function selectedAudioInputLabel() {
  const selected = state.audioInputs.find((input) => input.deviceId === state.audioSelectedInputId);
  return selected?.label || "default audio input";
}

async function connectMidi() {
  if (!navigator.requestMIDIAccess) {
    state.midiStatus = "error";
    state.midiError = "This Electron/Chromium build does not expose Web MIDI.";
    renderDashboard();
    return;
  }

  try {
    state.midiError = "";
    midiAccess = await navigator.requestMIDIAccess({ sysex: false });
    state.midiStatus = "connected";
    refreshMidiInputs();
    await bindMidiInputs();
    refreshMidiInputs();
    midiAccess.onstatechange = () => {
      refreshMidiInputs();
      bindMidiInputs();
      renderMidiIfVisible();
    };
  } catch (error) {
    state.midiStatus = "error";
    state.midiError = error?.message || "Could not access MIDI devices.";
  }
  renderDashboard();
}

async function connectAudioDevices() {
  if (!navigator.mediaDevices?.getUserMedia) {
    state.audioStatus = "error";
    state.audioError = "This Electron/Chromium build does not expose audio capture.";
    renderDashboard();
    return;
  }

  try {
    state.audioError = "";
    const permissionStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    permissionStream.getTracks().forEach((track) => track.stop());
    await refreshAudioInputs();
    state.audioStatus = "connected";
  } catch (error) {
    state.audioStatus = "error";
    state.audioError = error?.message || "Could not access audio input.";
  }
  renderDashboard();
}

async function refreshAudioInputs() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  state.audioInputs = devices
    .filter((device) => device.kind === "audioinput")
    .map((device) => ({
      deviceId: device.deviceId,
      label: device.label || "Unnamed audio input"
    }));
  if (state.audioSelectedInputId && !state.audioInputs.some((input) => input.deviceId === state.audioSelectedInputId)) {
    state.audioSelectedInputId = "";
  }
  if (!state.audioSelectedInputId) {
    const flxInput =
      state.audioInputs.find((input) => /flx\s*10|flx10|ddj-flx10|ddj flx10/i.test(input.label)) ||
      state.audioInputs.find((input) => /alphatheta|pioneer/i.test(input.label));
    if (flxInput) state.audioSelectedInputId = flxInput.deviceId;
  }
}

function audioMimeType() {
  const candidates = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"];
  return candidates.find((type) => window.MediaRecorder?.isTypeSupported(type)) || "";
}

async function toggleSetAudioRecording() {
  if (state.audioRecording) {
    stopSetAudioRecording();
    return;
  }
  await startSetAudioRecording();
}

async function startSetAudioRecording() {
  if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
    state.audioStatus = "error";
    state.audioError = "Audio recording is not available in this app runtime.";
    renderDashboard();
    return;
  }

  try {
    if (!state.audioInputs.length) await connectAudioDevices();
    if (state.audioStatus === "error") return;
    state.audioError = "";
    if (recordedAudioBlob) {
      recordedAudioBlob = null;
      state.audioReady = false;
    }
    const constraints = {
      audio: state.audioSelectedInputId
        ? { deviceId: { exact: state.audioSelectedInputId }, echoCancellation: false, noiseSuppression: false, autoGainControl: false }
        : { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
      video: false
    };
    audioStream = await navigator.mediaDevices.getUserMedia(constraints);
    const mimeType = audioMimeType();
    audioChunks = [];
    audioRecorder = new MediaRecorder(audioStream, mimeType ? { mimeType } : undefined);
    audioRecorder.addEventListener("dataavailable", (event) => {
      if (event.data?.size) audioChunks.push(event.data);
    });
    audioRecorder.addEventListener("stop", () => {
      recordedAudioBlob = new Blob(audioChunks, { type: state.audioMimeType || audioChunks[0]?.type || "audio/webm" });
      state.audioReady = recordedAudioBlob.size > 0;
      state.audioRecording = false;
      state.audioDurationMs = Math.max(0, Math.round(performance.now() - state.audioStartedAt));
      audioStream?.getTracks().forEach((track) => track.stop());
      audioStream = null;
      window.clearInterval(audioDurationTimer);
      renderDashboard();
    });
    state.audioMimeType = audioRecorder.mimeType || mimeType || "audio/webm";
    state.audioStartedAt = performance.now();
    state.audioDurationMs = 0;
    state.audioRecording = true;
    state.audioStatus = "connected";
    audioRecorder.start(1000);
    window.clearInterval(audioDurationTimer);
    audioDurationTimer = window.setInterval(() => {
      state.audioDurationMs = Math.max(0, Math.round(performance.now() - state.audioStartedAt));
      if (state.activeView === "midi") renderDashboard();
    }, 1000);
  } catch (error) {
    state.audioStatus = "error";
    state.audioError = error?.message || "Could not start set audio recording.";
    audioStream?.getTracks().forEach((track) => track.stop());
    audioStream = null;
  }
  renderDashboard();
}

function stopSetAudioRecording() {
  if (audioRecorder && audioRecorder.state !== "inactive") {
    audioRecorder.stop();
    return;
  }
  state.audioRecording = false;
  audioStream?.getTracks().forEach((track) => track.stop());
  audioStream = null;
  window.clearInterval(audioDurationTimer);
  renderDashboard();
}

function downloadRecordedAudio() {
  if (!recordedAudioBlob) return;
  const extension = state.audioMimeType.includes("mp4") ? "m4a" : "webm";
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const url = URL.createObjectURL(recordedAudioBlob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `rekordbox-set-audio-${stamp}.${extension}`;
  anchor.click();
  URL.revokeObjectURL(url);
}

async function connectHid() {
  if (!navigator.hid) {
    state.hidStatus = "error";
    state.hidError = "This Electron/Chromium build does not expose WebHID.";
    renderDashboard();
    return;
  }

  try {
    state.hidError = "";
    let devices = await navigator.hid.getDevices();
    if (!devices.length) {
      devices = await navigator.hid.requestDevice({ filters: [] });
    }
    state.hidDevices = devices.map(hidDeviceSummary);
    activeHidDevice = devices.find(isFlx10HidDevice) || devices.find(isAlphaThetaHidDevice) || devices[0] || null;
    if (!activeHidDevice) {
      state.hidStatus = "error";
      state.hidError = "No HID controller was selected.";
      renderDashboard();
      return;
    }
    if (!activeHidDevice.opened) await activeHidDevice.open();
    activeHidDevice.removeEventListener("inputreport", handleHidInputReport);
    activeHidDevice.addEventListener("inputreport", handleHidInputReport);
    state.hidSelectedDeviceId = hidDeviceId(activeHidDevice);
    state.hidStatus = "connected";
  } catch (error) {
    state.hidStatus = "error";
    state.hidError = error?.message || "Could not access HID controller reports.";
  }
  renderDashboard();
}

function hidDeviceSummary(device) {
  return {
    id: hidDeviceId(device),
    productName: device.productName || "Unknown HID device",
    vendorId: device.vendorId || 0,
    productId: device.productId || 0,
    opened: Boolean(device.opened)
  };
}

function hidDeviceId(device) {
  return `${device.vendorId || 0}:${device.productId || 0}:${device.productName || ""}`;
}

function isFlx10HidDevice(device) {
  return /flx\s*10|flx10|ddj-flx10|ddj flx10/i.test(device?.productName || "");
}

function isAlphaThetaHidDevice(device) {
  return /alphatheta|pioneer/i.test(device?.productName || "");
}

function refreshMidiInputs() {
  if (!midiAccess) {
    state.midiInputs = [];
    return;
  }
  state.midiInputs = Array.from(midiAccess.inputs.values()).map((input) => ({
    id: input.id,
    name: input.name || "Unnamed MIDI input",
    manufacturer: input.manufacturer || "",
    state: input.state || "",
    connection: input.connection || ""
  }));
  const selectedStillExists = state.midiSelectedInputId === "all" || state.midiInputs.some((input) => input.id === state.midiSelectedInputId);
  if (!selectedStillExists) state.midiSelectedInputId = "all";
  if (state.midiSelectedInputId === "all") {
    const flxInput = state.midiInputs.find(isFlx10Input);
    if (flxInput) state.midiSelectedInputId = flxInput.id;
  }
}

async function bindMidiInputs() {
  if (!midiAccess) return;
  for (const input of midiAccess.inputs.values()) {
    try {
      await input.open();
    } catch (error) {
      state.midiError = `Could not open ${input.name || "MIDI input"}: ${error?.message || error}`;
    }
    input.onmidimessage = handleMidiMessage;
  }
}

function toggleMidiRecording() {
  if (state.midiRecording) {
    state.midiRecording = false;
    saveMidiLogNow();
    renderDashboard();
    return;
  }

  if (!midiAccess) {
    connectMidi().then(() => {
      if (midiAccess) startMidiRecording();
    });
    return;
  }
  startMidiRecording();
}

function startMidiRecording() {
  state.midiRecording = true;
  state.midiCopied = false;
  state.midiMonitorCount = 0;
  state.midiLastSeenEvent = null;
  state.hidMonitorCount = 0;
  state.hidLastSeenEvent = null;
  state.midiRecordStartedAt = performance.now();
  state.midiSessionStartedAt = new Date().toISOString();
  bindMidiInputs();
  renderDashboard();
}

function handleMidiMessage(message) {
  const input = message.currentTarget || message.target;
  const inputId = input?.id || "";
  if (state.midiSelectedInputId !== "all" && inputId !== state.midiSelectedInputId) return;

  const data = Array.from(message.data || []);
  const decoded = decodeMidiMessage(data);
  const seenEvent = {
    relativeMs: state.midiRecording ? Math.max(0, Math.round(performance.now() - state.midiRecordStartedAt)) : 0,
    at: new Date().toISOString(),
    inputId,
    inputName: input?.name || "Unknown MIDI input",
    data,
    dataHex: data.map((byte) => byte.toString(16).padStart(2, "0").toUpperCase()).join(" "),
    ...decoded
  };
  state.midiMonitorCount += 1;
  state.midiLastSeenEvent = seenEvent;

  if (!state.midiRecording || decoded.recordable === false) {
    scheduleMidiRender();
    return;
  }

  const event = {
    id: `${Date.now()}-${state.midiEvents.length}`,
    index: state.midiEvents.length,
    ...seenEvent
  };

  state.midiEvents.push(event);
  if (state.midiEvents.length > MIDI_LOG_LIMIT) {
    state.midiEvents.splice(0, state.midiEvents.length - MIDI_LOG_LIMIT);
    state.midiEvents.forEach((item, index) => {
      item.index = index;
    });
  }
  scheduleMidiSave();
  scheduleMidiRender();
}

function handleHidInputReport(event) {
  const device = event.device || activeHidDevice;
  const bytes = Array.from(new Uint8Array(event.data.buffer, event.data.byteOffset, event.data.byteLength));
  const reportId = event.reportId ?? 0;
  const seenEvent = {
    relativeMs: state.midiRecording ? Math.max(0, Math.round(performance.now() - state.midiRecordStartedAt)) : 0,
    at: new Date().toISOString(),
    inputId: hidDeviceId(device || {}),
    inputName: device?.productName || "Unknown HID device",
    data: bytes,
    dataHex: bytes.map((byte) => byte.toString(16).padStart(2, "0").toUpperCase()).join(" "),
    action: "HID controller report",
    detail: `Report ${reportId} · ${bytes.length} bytes`,
    type: "hid-input-report",
    channel: null,
    control: reportId,
    value: bytes[0] ?? "",
    protocol: "hid"
  };

  state.hidMonitorCount += 1;
  state.hidLastSeenEvent = seenEvent;

  if (!state.midiRecording) {
    scheduleMidiRender();
    return;
  }

  state.midiEvents.push({
    id: `${Date.now()}-${state.midiEvents.length}`,
    index: state.midiEvents.length,
    ...seenEvent
  });
  if (state.midiEvents.length > MIDI_LOG_LIMIT) {
    state.midiEvents.splice(0, state.midiEvents.length - MIDI_LOG_LIMIT);
    state.midiEvents.forEach((item, index) => {
      item.index = index;
    });
  }
  scheduleMidiSave();
  scheduleMidiRender();
}

function decodeMidiMessage(data) {
  const status = data[0] || 0;
  const command = status & 0xf0;
  const channel = (status & 0x0f) + 1;
  const first = data[1] ?? 0;
  const second = data[2] ?? 0;

  if (status >= 0xf8) {
    return {
      action: "MIDI realtime",
      detail: `Status ${status}`,
      type: "realtime",
      channel: null,
      control: null,
      value: second,
      recordable: false
    };
  }

  if (status >= 0xf0) {
    return {
      action: "System message",
      detail: `Status ${status}`,
      type: "system",
      channel: null,
      control: null,
      value: second,
      recordable: false
    };
  }

  if (command === 0x80 || (command === 0x90 && second === 0)) {
    return {
      action: "Button release",
      detail: `Ch ${channel} · note ${first}`,
      type: "note-off",
      channel,
      control: first,
      value: second
    };
  }

  if (command === 0x90) {
    return {
      action: "Button / pad press",
      detail: `Ch ${channel} · note ${first} · velocity ${second}`,
      type: "note-on",
      channel,
      control: first,
      value: second
    };
  }

  if (command === 0xb0) {
    return {
      action: "Knob / fader / encoder",
      detail: `Ch ${channel} · CC ${first} · value ${second}`,
      type: "control-change",
      channel,
      control: first,
      value: second
    };
  }

  if (command === 0xe0) {
    const bend = ((second << 7) + first) - 8192;
    return {
      action: "Jog / pitch movement",
      detail: `Ch ${channel} · bend ${bend}`,
      type: "pitch-bend",
      channel,
      control: null,
      value: bend
    };
  }

  return {
    action: "MIDI message",
    detail: `Ch ${channel} · ${data.join(", ")}`,
    type: `0x${command.toString(16)}`,
    channel,
    control: first,
    value: second
  };
}

function scheduleMidiSave() {
  window.clearTimeout(midiSaveTimer);
  midiSaveTimer = window.setTimeout(saveMidiLogNow, 350);
}

function saveMidiLogNow() {
  try {
    window.localStorage?.setItem(MIDI_LOG_STORAGE_KEY, JSON.stringify(state.midiEvents));
  } catch {
    state.midiError = "Could not save MIDI log locally. Export the log before closing the app.";
  }
}

function scheduleMidiRender() {
  if (state.activeView !== "midi") return;
  if (midiRenderTimer) return;
  midiRenderTimer = window.setTimeout(() => {
    midiRenderTimer = null;
    renderDashboard();
  }, 180);
}

function renderMidiIfVisible() {
  if (state.activeView === "midi") renderDashboard();
}

function clearMidiLog() {
  stopMidiReplay(false);
  state.midiEvents = [];
  state.midiReplayPositionMs = 0;
  state.midiReplayIndex = -1;
  state.midiCopied = false;
  saveMidiLogNow();
  renderDashboard();
}

function formatMidiLogText() {
  return state.midiEvents
    .map((event) => `${fmtRelativeTimestamp(event.relativeMs)} - ${event.action} - ${event.detail} - ${event.inputName} - ${event.dataHex}`)
    .join("\n");
}

function midiLogCsv() {
  const rows = [["relative_ms", "time", "input", "action", "detail", "type", "channel", "control", "value", "data_hex"]];
  for (const event of state.midiEvents) {
    rows.push([
      event.relativeMs,
      event.at,
      event.inputName,
      event.action,
      event.detail,
      event.type,
      event.channel ?? "",
      event.control ?? "",
      event.value ?? "",
      event.dataHex
    ]);
  }
  return rows.map((row) => row.map(csvCell).join(",")).join("\n");
}

function csvCell(value) {
  const text = String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function downloadMidiLog(format) {
  const isJson = format === "json";
  const content = isJson ? JSON.stringify({ exportedAt: new Date().toISOString(), events: state.midiEvents }, null, 2) : midiLogCsv();
  const blob = new Blob([content], { type: isJson ? "application/json" : "text/csv" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  anchor.href = url;
  anchor.download = `rekordbox-midi-log-${stamp}.${isJson ? "json" : "csv"}`;
  anchor.click();
  URL.revokeObjectURL(url);
}

function toggleMidiReplay() {
  if (state.midiReplayRunning) {
    stopMidiReplay();
    return;
  }
  startMidiReplay();
}

function startMidiReplay() {
  if (!state.midiEvents.length) return;
  stopMidiReplay(false);
  state.midiReplayRunning = true;
  state.midiReplayStartedAt = performance.now();
  state.midiReplayPositionMs = 0;
  state.midiReplayIndex = -1;
  midiReplayTimer = window.setInterval(updateMidiReplay, 45);
  updateMidiReplay();
}

function stopMidiReplay(shouldRender = true) {
  window.clearInterval(midiReplayTimer);
  midiReplayTimer = null;
  state.midiReplayRunning = false;
  if (shouldRender) renderMidiIfVisible();
}

function updateMidiReplay() {
  const lastEvent = state.midiEvents.at(-1);
  const duration = lastEvent?.relativeMs || 0;
  const elapsed = Math.min(duration, Math.round(performance.now() - state.midiReplayStartedAt));
  state.midiReplayPositionMs = elapsed;
  let index = -1;
  for (let cursor = 0; cursor < state.midiEvents.length; cursor += 1) {
    if (state.midiEvents[cursor].relativeMs <= elapsed) index = cursor;
    else break;
  }
  state.midiReplayIndex = index;
  if (elapsed >= duration) stopMidiReplay(false);
  renderMidiIfVisible();
}

function renderSetBuilderView() {
  const model = buildTransitionModel(state.data);
  const roots = builderRootOptions(model);
  const genres = genreOptions(state.data);

  if (!state.builderPath.length && roots[0]) {
    state.builderPath = [roots[0].key];
    state.builderRootInput = roots[0].label;
    state.builderActiveIndex = 0;
  }

  const currentRoot = model.trackMap.get(state.builderPath[0]);
  const inputValue = state.builderRootInput || (currentRoot ? trackDisplayLabel(currentRoot) : "");
  const builderPathId = transitionPathId(state.builderPath);

  return `
    <main class="view-page builder-view">
      <header class="view-header">
        <div>
          <p class="eyebrow">Set Builder</p>
          <h2>Folder Builder</h2>
        </div>
        <div class="view-actions">
          ${state.builderCopiedSetPath === builderPathId ? `<span>Copied</span>` : ""}
          <span>${state.builderPath.length} ${state.builderPath.length === 1 ? "song" : "songs"}</span>
          <button data-copy-builder-set type="button">Copy Set</button>
        </div>
      </header>
      <section class="builder-controls">
        <form data-builder-root-form>
          <label for="builder-root">Start song</label>
          <input
            id="builder-root"
            data-builder-root-input
            list="builder-root-options"
            placeholder="Type a song title"
            value="${escapeHtml(inputValue)}"
          />
          <datalist id="builder-root-options">
            ${roots.slice(0, 300).map((option) => `<option value="${escapeHtml(option.label)}"></option>`).join("")}
          </datalist>
          <button type="submit">Start set</button>
        </form>
        <div class="builder-filter-row">
          <label>
            <span>Genre</span>
            <select data-builder-genre>
              <option value="all">All genres</option>
              ${genres
                .map(
                  ({ genre, count }) =>
                    `<option value="${escapeHtml(genre)}">${escapeHtml(genre)} (${count.toLocaleString()})</option>`
                )
                .join("")}
            </select>
          </label>
          <label>
            <span>Sort</span>
            <select data-builder-sort>
              <option value="popularity">Historical popularity</option>
              <option value="harmonic">Harmonic similarity</option>
            </select>
          </label>
          <label>
            <span>BPM +/-</span>
            <input data-builder-bpm-tolerance type="number" min="0" max="80" step="1" value="${escapeHtml(state.builderBpmTolerance)}" />
          </label>
        </div>
        <div class="path-suggestions">
          ${roots
            .slice(0, 6)
            .map(
              (option) => `
                <button data-builder-root-key="${escapeHtml(option.key)}" type="button">
                  ${escapeHtml(option.label)}
                </button>
              `
            )
            .join("")}
        </div>
      </section>
      <section class="builder-file-list">
        ${
          state.builderPath.length
            ? state.builderPath.map((key, index) => renderBuilderSong(key, model, index)).join("")
            : `<p class="empty">Choose a starting song to begin building a set.</p>`
        }
      </section>
    </main>
  `;
}

function renderBuilderSong(key, model, index) {
  const track = model.trackMap.get(key) || { displayTitle: "Unknown track" };
  const secondary = trackSecondary(track);
  const isActive = index === state.builderActiveIndex;
  const candidates = builderCandidatesFor(key, model, index);
  const visibleCount = builderVisibleCount(index);
  const visibleCandidates = candidates.slice(0, visibleCount);
  const cover = track.artUrl
    ? `<img src="${escapeHtml(track.artUrl)}" alt="" loading="lazy" />`
    : `<span>${escapeHtml((track.displayTitle || "?").slice(0, 1).toUpperCase())}</span>`;

  return `
    <div class="builder-folder">
      <div class="builder-row builder-song${isActive ? " is-active" : ""}">
        <button class="folder-toggle" data-builder-open-index="${index}" type="button">${isActive ? "v" : ">"}</button>
        <div class="small-cover">${cover}</div>
        <div class="builder-main">
          <strong>${escapeHtml(track.displayTitle || "Unknown track")}</strong>
          <span>${secondary ? escapeHtml(secondary) : "&nbsp;"}</span>
        </div>
        ${renderBuilderKeyCell(track)}
        <em>${Number.isFinite(track.bpm) ? `${track.bpm.toFixed(1)} BPM` : "--"}</em>
      </div>
      ${
        isActive
          ? `
            <div class="builder-candidates">
              ${
                visibleCandidates.length
                  ? visibleCandidates.map((candidate) => renderBuilderCandidate(candidate, index)).join("")
                  : `<p class="empty compact">No matches for the current genre and BPM range.</p>`
              }
              ${
                visibleCount < candidates.length
                  ? `<button class="builder-load-more" data-builder-load-more="${index}" type="button">Load more</button>`
                  : ""
              }
            </div>
          `
          : ""
      }
    </div>
  `;
}

function renderBuilderCandidate(candidate, index) {
  const track = candidate.track;
  const secondary = trackSecondary(track);
  const cover = track.artUrl
    ? `<img src="${escapeHtml(track.artUrl)}" alt="" loading="lazy" />`
    : `<span>${escapeHtml((track.displayTitle || "?").slice(0, 1).toUpperCase())}</span>`;
  const bpmText = Number.isFinite(candidate.bpmDelta) ? `+/- ${candidate.bpmDelta.toFixed(1)} BPM` : "No BPM";
  const harmonicText = candidate.harmonicDistance >= 99 ? "No key" : `Key ${candidate.harmonicDistance.toFixed(1)}`;

  return `
    <button class="builder-row builder-candidate" data-builder-select-key="${escapeHtml(candidate.key)}" data-builder-select-index="${index}" type="button">
      <span class="folder-branch" aria-hidden="true"></span>
      <div class="small-cover">${cover}</div>
      <div class="builder-main">
        <strong>${escapeHtml(track.displayTitle || "Unknown track")}</strong>
        <span>${secondary ? escapeHtml(secondary) : "&nbsp;"}</span>
      </div>
      ${renderBuilderKeyCell(track)}
      <em>${candidate.transitionCount ? `${candidate.transitionCount}x` : "Library"}</em>
      <em>${escapeHtml(bpmText)}</em>
      <em>${escapeHtml(harmonicText)}</em>
    </button>
  `;
}

function renderPathsView() {
  const model = buildTransitionModel(state.data);
  const options = transitionRootOptions(model);
  const rootKey = resolveTransitionRoot(model);
  const rootTrack = model.trackMap.get(rootKey);
  if (rootKey && !state.transitionRootKey) {
    state.transitionRootKey = rootKey;
    state.transitionRootInput = rootTrack ? trackDisplayLabel(rootTrack) : "";
  }
  const rootLabel = rootTrack ? trackDisplayLabel(rootTrack) : "";
  const inputValue = state.transitionRootInput || rootLabel;

  return `
    <main class="view-page paths-view">
      <header class="view-header">
        <div>
          <p class="eyebrow">Paths</p>
          <h2>Transition Tree</h2>
        </div>
        <div class="view-actions">
          <span>${state.transitionExpandedPaths.size} open ${state.transitionExpandedPaths.size === 1 ? "branch" : "branches"}</span>
          <button data-reset-transition-tree type="button">Reset tree</button>
        </div>
      </header>
      <section class="path-controls">
        <form data-transition-root-form>
          <label for="transition-root">Start song</label>
          <input
            id="transition-root"
            data-transition-root-input
            list="transition-root-options"
            placeholder="Type a song title"
            value="${escapeHtml(inputValue)}"
          />
          <datalist id="transition-root-options">
            ${options.slice(0, 250).map((option) => `<option value="${escapeHtml(option.label)}"></option>`).join("")}
          </datalist>
          <button type="submit">Start tree</button>
        </form>
        <div class="path-suggestions">
          ${options
            .slice(0, 6)
            .map(
              (option) => `
                <button data-transition-root-key="${escapeHtml(option.key)}" type="button">
                  ${escapeHtml(option.label)}
                </button>
              `
            )
            .join("")}
        </div>
      </section>
      <section class="path-workspace">
        <div class="transition-tree">
          ${
            rootKey
              ? renderTransitionNode(rootKey, model, [rootKey], 0)
              : `<p class="empty">No transition data found. This needs at least two tracks in a set.</p>`
          }
        </div>
      </section>
      ${
        state.transitionCopiedPath
          ? `<section class="path-copied"><strong>Copied path</strong><pre>${escapeHtml(state.transitionCopiedPath)}</pre></section>`
          : ""
      }
    </main>
  `;
}

function renderTransitionNode(key, model, path, index = 0, transitionCount = 0) {
  const track = model.trackMap.get(key) || { displayTitle: "Unknown track" };
  const children = transitionChildrenFor(key, model);
  const pathText = transitionPathText(path, model);
  const pathId = transitionPathId(path);
  const isExpanded = state.transitionExpandedPaths.has(pathId);
  const cover = track.artUrl
    ? `<img src="${escapeHtml(track.artUrl)}" alt="" loading="lazy" />`
    : `<span>${escapeHtml((track.displayTitle || "?").slice(0, 1).toUpperCase())}</span>`;
  return `
    <div class="tree-node${isExpanded ? " is-expanded" : ""} animated-row" style="--row-delay: ${Math.min(index, 24) * 24}ms">
      <div class="tree-card">
        <div class="small-cover">${cover}</div>
        <div class="tree-card-main">
          <strong>${escapeHtml(track.displayTitle || "Unknown track")}</strong>
          <span>${escapeHtml(trackSecondary(track))}</span>
          <div class="tree-meta">
            ${renderKeyBadge(track)}
            <em>${transitionCount ? `${transitionCount}x` : "Root"}</em>
          </div>
        </div>
        <div class="tree-actions">
          ${
            children.length
              ? `<button data-expand-transition-path="${escapeHtml(pathId)}" type="button">${isExpanded ? "Hide branch" : "Expand from here"}</button>`
              : `<span class="path-terminal">End</span>`
          }
          <button data-copy-transition-path="${escapeHtml(pathText)}" type="button">Copy path</button>
        </div>
      </div>
      ${
        isExpanded && children.length
          ? `
            <div class="tree-children">
              ${children
                .map((child, childIndex) =>
                  renderTransitionNode(
                    child.key,
                    model,
                    [...path, child.key],
                    childIndex,
                    child.count
                  )
                )
                .join("")}
            </div>
          `
          : ""
      }
    </div>
  `;
}

function renderSetsView(sessions, selected) {
  return `
    <main class="sets-layout">
      <aside class="set-sidebar" aria-label="History sets">
        <div class="sidebar-heading">
          <p class="eyebrow">Sets</p>
          <strong>${sessions.length.toLocaleString()} sessions</strong>
        </div>
        <div class="session-list">
          ${sessions.map(renderSessionButton).join("") || `<p class="empty">No matching sets</p>`}
        </div>
      </aside>
      <section class="track-panel">
        ${selected ? renderSession(selected) : `<p class="empty">No history rows matched the current filters.</p>`}
      </section>
    </main>
  `;
}

function renderSessionButton(session) {
  const active = session.id === state.selectedSessionId ? " is-active" : "";
  const first = session.tracks[0];
  return `
    <div class="session-row">
      <button class="session-button${active}" data-session-id="${escapeHtml(session.id)}" type="button">
        <span class="session-name">${escapeHtml(displaySetName(session))}</span>
        <span class="session-meta">${escapeHtml(fmtDate(session.startedAt))} · ${session.trackCount} tracks</span>
        <span class="session-preview">${escapeHtml(first ? first.displayTitle : "Empty session")}</span>
      </button>
      <button class="session-copy" data-copy-set-id="${escapeHtml(session.id)}" type="button">
        ${state.copiedSetSessionId === session.id ? "Copied" : "Copy Set"}
      </button>
    </div>
  `;
}

function renderSession(session) {
  const tracks = filteredTracks(session.tracks);

  return `
    <header class="panel-header">
      <div>
        <p class="eyebrow">${escapeHtml(fmtDate(session.startedAt))}</p>
        <h2>${escapeHtml(displaySetName(session))}</h2>
        <span>${escapeHtml(sourceSummary(session.tracks) || "No source data")}</span>
      </div>
      <div class="panel-actions">
        <span class="panel-count">${tracks.length} / ${session.trackCount} tracks</span>
        ${state.copiedSetSessionId === session.id ? `<span class="panel-count">Copied</span>` : ""}
        <button data-copy-set-id="${escapeHtml(session.id)}" type="button">Copy Set</button>
        <button data-download-setlist-id="${escapeHtml(session.id)}" type="button">Download setlist</button>
      </div>
    </header>
    <div class="table-wrap">
      ${renderTrackTable(tracks)}
    </div>
  `;
}

function renderTrackTable(tracks, options = {}) {
  return `
    <table>
      <thead>
        <tr>
          <th>#</th>
          <th>Track</th>
          <th>${options.unique ? "Last played" : "Time"}</th>
          <th>Key</th>
          <th>BPM</th>
          <th>Length</th>
          <th>Plays</th>
          <th>Source</th>
        </tr>
      </thead>
      <tbody>${tracks.map((track, index) => renderTrackRow(track, index, options)).join("")}</tbody>
    </table>
  `;
}

function renderTrackRow(track, index = 0, options = {}) {
  const cover = track.artUrl
    ? `<img src="${escapeHtml(track.artUrl)}" alt="" loading="lazy" />`
    : `<span class="cover-fallback">${escapeHtml(track.displayTitle.slice(0, 1).toUpperCase())}</span>`;
  const secondary = trackSecondary(track);
  const rowNumber = options.sequential ? index + 1 : track.trackNo || index + 1;
  const playCount = options.unique ? track.playCount : track.djPlayCount;
  const source = options.unique ? track.sourceLabel : track.source;
  const rowAnimation =
    index < 36 ? ` class="track-row animated-row" style="--row-delay: ${index * 18}ms"` : "";
  return `
    <tr${rowAnimation}>
      <td class="track-no">${rowNumber}</td>
      <td>
        <div class="track-cell">
          <div class="cover">${cover}</div>
          <div>
            <strong>${escapeHtml(track.displayTitle)}</strong>
            ${secondary ? `<span>${escapeHtml(secondary)}</span>` : ""}
          </div>
        </div>
      </td>
      <td>${escapeHtml(fmtDate(track.playedAt, { year: undefined }))}</td>
      <td>${renderKeyBadge(track)}</td>
      <td>${track.bpm ? track.bpm.toFixed(1) : ""}</td>
      <td>${escapeHtml(fmtDuration(track.lengthSeconds))}</td>
      <td>${playCount || ""}</td>
      <td><span class="source-pill">${escapeHtml(source || "Unknown")}</span></td>
    </tr>
  `;
}

function downloadSetlist(session) {
  const lines = [
    displaySetName(session),
    fmtDate(session.startedAt),
    "",
    ...session.tracks.map((track) => {
      const artist = cleanSecondaryText(track.displayArtist);
      const label = artist ? `${track.displayTitle} - ${artist}` : track.displayTitle;
      return `${track.trackNo || ""}. ${label}`;
    })
  ];
  const blob = new Blob([lines.join("\n")], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `${session.name.replace(/[^a-z0-9-]+/gi, "-").replace(/^-|-$/g, "") || "setlist"}.txt`;
  anchor.click();
  URL.revokeObjectURL(url);
}

function fmtRelativeTimestamp(milliseconds) {
  const totalSeconds = Math.max(0, Math.round(milliseconds / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  }
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

function formatTimedSetlist(session) {
  const tracks = [...session.tracks].sort((a, b) => (a.trackNo || 0) - (b.trackNo || 0));
  const firstTime = new Date(tracks[0]?.playedAt).getTime();
  const baseTime = Number.isFinite(firstTime) ? firstTime : 0;

  return tracks
    .map((track, index) => {
      const playedTime = new Date(track.playedAt).getTime();
      const relative = index === 0 || !Number.isFinite(playedTime) || !baseTime ? 0 : playedTime - baseTime;
      return `${fmtRelativeTimestamp(relative)} - ${setlistTrackLabel(track)}`;
    })
    .join("\n");
}

function formatBuilderSetlist(model) {
  let elapsedSeconds = 0;
  return state.builderPath
    .map((key) => {
      const track = model.trackMap.get(key) || { displayTitle: "Unknown track" };
      const line = `${fmtRelativeTimestamp(elapsedSeconds * 1000)} - ${setlistTrackLabel(track)}`;
      elapsedSeconds += Number.isFinite(track.lengthSeconds) ? track.lengthSeconds : 0;
      return line;
    })
    .join("\n");
}

async function copyText(text) {
  if (window.rekordboxHistory?.copyText) {
    await window.rekordboxHistory.copyText(text);
    return;
  }
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  document.execCommand("copy");
  textarea.remove();
}

async function loadHistory(force = false) {
  renderShell();
  try {
    const data = await window.rekordboxHistory.getHistory({ force });
    state.data = data;
    state.selectedSessionId = data.sessions[0]?.id || null;
    renderDashboard();
  } catch (error) {
    renderError(error);
  }
}

renderShell();
loadHistory();
