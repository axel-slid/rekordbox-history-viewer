import "./styles.css";

const app = document.querySelector("#app");

const state = {
  data: null,
  selectedSessionId: null,
  activeView: "sets",
  query: "",
  source: "all",
  mixNoticeSessionId: null,
  topTracksLimit: 5,
  trackSort: "recent-desc",
  sessionListScrollTop: 0,
  transitionRootKey: "",
  transitionRootInput: "",
  transitionBranchLimit: 6,
  transitionCopiedPath: "",
  transitionExpandedPaths: new Set()
};

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

function setMixReadiness(session) {
  const localTracks = session.tracks.filter(
    (track) => track.source === "Local file" && track.path && !track.path.startsWith("spotify:")
  );
  const spotifyTracks = session.tracks.filter((track) => track.source === "Spotify");
  return {
    localTracks,
    spotifyTracks,
    canRenderApproximation: localTracks.length === session.tracks.length && localTracks.length > 1
  };
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
  document.querySelectorAll("[data-recreate-session-id]").forEach((button) => {
    button.addEventListener("click", () => {
      state.mixNoticeSessionId =
        state.mixNoticeSessionId === button.dataset.recreateSessionId
          ? null
          : button.dataset.recreateSessionId;
      renderDashboard();
    });
  });
  document.querySelectorAll("[data-download-setlist-id]").forEach((button) => {
    button.addEventListener("click", () => {
      const session = state.data.sessions.find((item) => item.id === button.dataset.downloadSetlistId);
      if (session) downloadSetlist(session);
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
    <button class="session-button${active}" data-session-id="${escapeHtml(session.id)}" type="button">
      <span class="session-name">${escapeHtml(displaySetName(session))}</span>
      <span class="session-meta">${escapeHtml(fmtDate(session.startedAt))} · ${session.trackCount} tracks</span>
      <span class="session-preview">${escapeHtml(first ? first.displayTitle : "Empty session")}</span>
    </button>
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
        <button data-download-setlist-id="${escapeHtml(session.id)}" type="button">Download setlist</button>
        <button data-recreate-session-id="${escapeHtml(session.id)}" type="button">Recreate mix</button>
      </div>
    </header>
    ${renderMixNotice(session)}
    <div class="table-wrap">
      ${renderTrackTable(tracks)}
    </div>
  `;
}

function renderMixNotice(session) {
  if (state.mixNoticeSessionId !== session.id) return "";
  const readiness = setMixReadiness(session);
  const spotifyCount = readiness.spotifyTracks.length;
  const localCount = readiness.localTracks.length;
  const status = readiness.canRenderApproximation
    ? "This set is made from local files, so an approximate crossfaded render is technically possible."
    : "This history can recreate the setlist and timing, but not the exact audio mix from the available data.";
  return `
    <section class="mix-notice">
      <div>
        <p class="eyebrow">Mix recreation</p>
        <strong>${escapeHtml(status)}</strong>
        <span>
          Exact transitions need a Rekordbox recording or mixer automation data. Spotify tracks cannot be downloaded or rendered into an audio file here; local audio files can be stitched into an approximate crossfade mix.
        </span>
      </div>
      <div class="mix-counts">
        <span>${localCount} local files</span>
        <span>${spotifyCount} Spotify tracks</span>
      </div>
    </section>
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
