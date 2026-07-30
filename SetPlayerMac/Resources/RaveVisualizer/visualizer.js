/* global butterchurn, butterchurnPresets, butterchurnPresetsExtra, CURATED_HYPE, CURATED_FLOW */

(() => {
  'use strict';

  const unwrap = (module) => (module && module.default ? module.default : module);
  const engine = unwrap(window.butterchurn);
  const canvas = document.getElementById('canvas');
  const beatDot = document.getElementById('beat-dot');

  const presets = {};
  for (const pack of [window.butterchurnPresets, window.butterchurnPresetsExtra]) {
    const resolved = unwrap(pack);
    if (resolved?.getPresets) Object.assign(presets, resolved.getPresets());
  }
  const presetNames = Object.keys(presets);
  const curatedHype = new Set((window.CURATED_HYPE || []).filter((name) => presets[name]));
  const curatedFlow = new Set((window.CURATED_FLOW || []).filter((name) => presets[name]));

  function presetScore(preset, name) {
    const base = preset?.baseVals || {};
    let serialized = '';
    try { serialized = JSON.stringify(preset); } catch (_) { /* base values still work */ }
    let score = Math.min(
      (serialized.match(/bass/gi) || []).length
        + 0.5 * (serialized.match(/treb/gi) || []).length,
      40
    ) * 0.12;
    score += Math.abs((base.zoom ?? 1) - 1) * 25;
    score += Math.abs(base.rot ?? 0) * 30;
    score += (1 - Math.min(base.decay ?? 0.98, 1)) * 120;
    const lower = name.toLowerCase();
    for (const word of ['fractal', 'explos', 'laser', 'speed', 'fire', 'acid', 'storm', 'machine']) {
      if (lower.includes(word)) score += 3;
    }
    for (const word of ['spiral', 'ocean', 'space', 'dream', 'glass', 'nebula', 'drifting']) {
      if (lower.includes(word)) score -= 3;
    }
    if (curatedHype.has(name)) score += 6;
    if (curatedFlow.has(name)) score -= 5;
    return score;
  }

  const rankedPresets = presetNames
    .map((name) => [name, presetScore(presets[name], name)])
    .sort((left, right) => left[1] - right[1]);

  // Disjoint energy bands keep every Rekordbox phrase type visually distinct.
  // Adjacent phrases of the same type still choose a new preset within the bin.
  const scoreBand = (start, end) => {
    const first = Math.floor(rankedPresets.length * start);
    const last = Math.max(first + 1, Math.ceil(rankedPresets.length * end));
    return rankedPresets.slice(first, last).map(([name]) => name);
  };
  const scenePools = {
    intro1: scoreBand(0.00, 0.08),
    outro2: scoreBand(0.08, 0.16),
    intro2: scoreBand(0.16, 0.24),
    outro1: scoreBand(0.24, 0.32),
    down: scoreBand(0.32, 0.43),
    flow: scoreBand(0.43, 0.55),
    up1: scoreBand(0.55, 0.66),
    up2: scoreBand(0.66, 0.76),
    up3: scoreBand(0.76, 0.84),
    chorus2: scoreBand(0.84, 0.91),
    chorus1: scoreBand(0.91, 0.97),
    fill: scoreBand(0.97, 1.00),
    hype: scoreBand(0.78, 1.00),
  };

  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  const audioContext = AudioContextClass ? new AudioContextClass({ latencyHint: 'interactive' }) : null;
  let visualizer = null;
  let currentPreset = '';

  const synth = {
    mix: null,
    bass: null,
    mid: null,
    high: null,
  };

  function setupSynth() {
    if (!audioContext) return;
    synth.mix = audioContext.createGain();
    synth.mix.gain.value = 0.8;

    const makeVoice = (frequency, type) => {
      const oscillator = audioContext.createOscillator();
      const gain = audioContext.createGain();
      oscillator.type = type;
      oscillator.frequency.value = frequency;
      gain.gain.value = 0;
      oscillator.connect(gain);
      gain.connect(synth.mix);
      oscillator.start();
      return gain;
    };

    synth.bass = makeVoice(54, 'sine');
    synth.mid = makeVoice(226, 'sawtooth');
    synth.high = makeVoice(3400, 'triangle');

    const silentOutput = audioContext.createGain();
    silentOutput.gain.value = 0;
    synth.mix.connect(silentOutput);
    silentOutput.connect(audioContext.destination);
  }

  function createVisualizer() {
    if (!engine || !presetNames.length) return;
    const ratio = Math.min(window.devicePixelRatio || 1, 1.65);
    canvas.width = Math.max(1, Math.floor(window.innerWidth * ratio));
    canvas.height = Math.max(1, Math.floor(window.innerHeight * ratio));
    visualizer = engine.createVisualizer(audioContext, canvas, {
      width: canvas.width,
      height: canvas.height,
      pixelRatio: 1,
      textureRatio: 1,
      meshWidth: 48,
      meshHeight: 36,
    });
    if (synth.mix) visualizer.connectAudio(synth.mix);
  }

  function randomPreset(family) {
    const pool = scenePools[family] || scenePools.flow;
    const available = pool.filter((name) => name !== currentPreset);
    const source = available.length ? available : pool;
    return source[Math.floor(Math.random() * source.length)] || presetNames[0];
  }

  function loadScene(family, immediate = false) {
    if (!visualizer) return;
    const name = randomPreset(family);
    if (!name) return;
    currentPreset = name;
    visualizer.loadPreset(presets[name], immediate ? 0 : 0.95);
  }

  const deck = {
    identity: '',
    position: 0,
    playbackRate: 1,
    bpm: 120,
    playing: false,
    bass: 1,
    filter: 0,
    receivedAt: performance.now(),
    beatTimes: [],
    beatNumbers: [],
    phrases: [],
    waveform: null,
  };

  let lastPhraseKey = '';
  let smoothedFilter = 0;
  let filterKick = 0;
  let filterKickDirection = 0;
  let beatCrossingKick = 0;
  let crossedBarBeat = 1;
  let scrubbingUntil = 0;

  function categoryForPhrase(phrase) {
    if (!phrase) return 'flow';
    if (phrase.category === 'hype' || phrase.category === 'flow') return phrase.category;
    const kind = String(phrase.kind || '').toLowerCase();
    if (/chorus|up|drop|fill/.test(kind)) return 'hype';
    return 'flow';
  }

  function sceneFamilyForPhrase(phrase) {
    if (!phrase) return 'flow';
    const kind = String(phrase.kind || '').toLowerCase();
    const compact = kind.replace(/\s+/g, '');
    if (kind.includes('fill')) return 'fill';
    if (compact.includes('chorus2')) return 'chorus2';
    if (kind.includes('chorus')) return 'chorus1';
    if (compact.includes('up3')) return 'up3';
    if (compact.includes('up2')) return 'up2';
    if (kind.includes('up')) return 'up1';
    if (kind.includes('down') || kind.includes('bridge')) return 'down';
    if (compact.includes('intro2')) return 'intro2';
    if (kind.includes('intro')) return 'intro1';
    if (compact.includes('outro2')) return 'outro2';
    if (kind.includes('outro')) return 'outro1';
    return categoryForPhrase(phrase);
  }

  function currentPosition(now) {
    if (now < scrubbingUntil) return Math.max(0, deck.position);
    const elapsed = deck.playing ? Math.max(0, now - deck.receivedAt) / 1000 : 0;
    return Math.max(0, deck.position + elapsed * Math.max(0.1, deck.playbackRate));
  }

  function upperBound(values, needle) {
    let low = 0;
    let high = values.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (values[middle] <= needle) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  function beatState(position) {
    if (deck.beatTimes.length >= 2) {
      const nextIndex = Math.min(deck.beatTimes.length - 1, upperBound(deck.beatTimes, position));
      const index = Math.max(0, nextIndex - 1);
      const start = deck.beatTimes[index];
      const end = deck.beatTimes[Math.min(index + 1, deck.beatTimes.length - 1)];
      const phase = end > start ? Math.min(1, Math.max(0, (position - start) / (end - start))) : 0;
      const nextDistance = Math.abs(end - position);
      const previousDistance = Math.abs(position - start);
      const nearestIsNext = nextDistance < previousDistance;
      const nearestIndex = nearestIsNext ? Math.min(index + 1, deck.beatTimes.length - 1) : index;
      const beatInterval = Math.max(0.12, end - start);
      const crossingWindow = Math.min(0.11, beatInterval * 0.2);
      const distance = Math.min(previousDistance, nextDistance);
      return {
        number: nearestIndex + 1,
        barBeat: deck.beatNumbers[nearestIndex] || (nearestIndex % 4) + 1,
        phase,
        proximity: Math.exp(-Math.pow(distance / crossingWindow, 2) * 2.6),
      };
    }
    return {
      number: 1,
      barBeat: 1,
      phase: 0,
      proximity: 0,
    };
  }

  function phraseAt(beatNumber) {
    if (!deck.phrases.length) {
      const index = Math.floor(Math.max(0, beatNumber - 1) / 32);
      return {
        key: `fallback-${index}-flow`,
        category: 'flow',
        family: 'flow',
      };
    }
    let low = 0;
    let high = deck.phrases.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (deck.phrases[middle].beat <= beatNumber) low = middle + 1;
      else high = middle;
    }
    const index = Math.max(0, low - 1);
    const phrase = deck.phrases[index];
    return {
      ...phrase,
      key: `${index}-${phrase.beat}-${phrase.kind}`,
      category: categoryForPhrase(phrase),
      family: sceneFamilyForPhrase(phrase),
    };
  }

  function decodeWaveform(source) {
    if (!source || typeof source.entriesBase64 !== 'string') return null;
    try {
      const binary = window.atob(source.entriesBase64);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index += 1) {
        bytes[index] = binary.charCodeAt(index);
      }
      const format = String(source.format || '').toLowerCase();
      const entrySize = format === 'pwv5' ? 2 : format === 'pwv3' ? 1 : 0;
      const entryCount = Math.min(
        Math.max(0, Number(source.entryCount) || 0),
        entrySize ? Math.floor(bytes.length / entrySize) : 0
      );
      if (!entrySize || !entryCount) return null;
      return {
        format,
        bytes,
        entryCount,
        samplesPerSecond: Math.max(1, Number(source.samplesPerSecond) || 150),
      };
    } catch (_) {
      return null;
    }
  }

  function waveformEntry(waveform, index) {
    const safeIndex = Math.min(waveform.entryCount - 1, Math.max(0, index));
    if (waveform.format === 'pwv5') {
      const offset = safeIndex * 2;
      const packed = (waveform.bytes[offset] << 8) | waveform.bytes[offset + 1];
      const height = ((packed & 0x007c) >> 2) / 31;
      const red = ((packed & 0xe000) >> 13) / 7;
      const green = ((packed & 0x1c00) >> 10) / 7;
      const blue = ((packed & 0x0380) >> 7) / 7;
      return {
        energy: height,
        bass: height * (0.12 + red * 0.88),
        mid: height * (0.12 + green * 0.88),
        high: height * (0.12 + blue * 0.88),
      };
    }

    const packed = waveform.bytes[safeIndex];
    const height = (packed & 0x1f) / 31;
    const brightness = (packed >> 5) / 7;
    return {
      energy: height,
      bass: height * (0.82 - brightness * 0.26),
      mid: height * (0.58 + brightness * 0.24),
      high: height * (0.32 + brightness * 0.58),
    };
  }

  function waveformState(position) {
    const waveform = deck.waveform;
    if (!waveform) {
      return { available: false, energy: 0, bass: 0, mid: 0, high: 0 };
    }
    const exactIndex = Math.max(0, position * waveform.samplesPerSecond);
    const lowerIndex = Math.min(waveform.entryCount - 1, Math.floor(exactIndex));
    const upperIndex = Math.min(waveform.entryCount - 1, lowerIndex + 1);
    const fraction = exactIndex - lowerIndex;
    const lower = waveformEntry(waveform, lowerIndex);
    const upper = waveformEntry(waveform, upperIndex);
    const interpolate = (key) => lower[key] + (upper[key] - lower[key]) * fraction;
    return {
      available: true,
      energy: interpolate('energy'),
      bass: interpolate('bass'),
      mid: interpolate('mid'),
      high: interpolate('high'),
    };
  }

  window.setRekordboxState = (next) => {
    if (!next || typeof next !== 'object') return;
    const changedTrack = next.identity !== deck.identity;
    const receivedNow = performance.now();
    const nextPosition = Number(next.position) || 0;
    const predictedPosition = currentPosition(receivedNow);
    const analysisChanged =
      Array.isArray(next.phrases)
      && `${next.phrases.length}:${next.phrases[0]?.beat || 0}:${next.phrases.at(-1)?.beat || 0}`
        !== `${deck.phrases.length}:${deck.phrases[0]?.beat || 0}:${deck.phrases.at(-1)?.beat || 0}`;

    const nextFilter = Math.min(1, Math.max(-1, Number(next.filter) || 0));
    const filterDelta = nextFilter - deck.filter;
    if (!changedTrack && Math.abs(filterDelta) > 0.004) {
      filterKick = Math.min(1, filterKick + Math.abs(filterDelta) * 3.8);
      filterKickDirection = Math.sign(filterDelta);
    }

    if (
      !changedTrack
      && deck.beatTimes.length
      && Math.abs(nextPosition - deck.position) > 0.015
    ) {
      const movingForward = nextPosition >= deck.position;
      const lower = Math.min(deck.position, nextPosition);
      const upper = Math.max(deck.position, nextPosition);
      const firstCrossed = upperBound(deck.beatTimes, lower + 0.002);
      const lastCrossed = upperBound(deck.beatTimes, upper + 0.002) - 1;
      if (firstCrossed <= lastCrossed && firstCrossed < deck.beatTimes.length) {
        const crossedIndex = movingForward ? lastCrossed : firstCrossed;
        beatCrossingKick = 1;
        crossedBarBeat = deck.beatNumbers[crossedIndex] || (crossedIndex % 4) + 1;
      }
    }
    if (!changedTrack && Math.abs(nextPosition - predictedPosition) > 0.12) {
      scrubbingUntil = receivedNow + 620;
    }

    deck.identity = String(next.identity || '');
    deck.position = nextPosition;
    deck.playbackRate = Number(next.playbackRate) || 1;
    deck.bpm = Number(next.bpm) || 120;
    deck.playing = Boolean(next.playing);
    deck.bass = Math.min(1, Math.max(0, Number(next.bass) || 0));
    deck.filter = nextFilter;
    deck.beatTimes = Array.isArray(next.beatTimes) ? next.beatTimes : [];
    deck.beatNumbers = Array.isArray(next.beatNumbers) ? next.beatNumbers : [];
    deck.phrases = Array.isArray(next.phrases) ? next.phrases : [];
    deck.receivedAt = receivedNow;
    if (changedTrack) deck.waveform = null;
    if (next.waveform) deck.waveform = decodeWaveform(next.waveform);

    if (audioContext?.state === 'suspended') audioContext.resume().catch(() => {});
    if (changedTrack || analysisChanged) {
      lastPhraseKey = '';
      const beat = beatState(deck.position);
      loadScene(phraseAt(beat.number + 1).family, true);
    }
  };

  function resize() {
    if (!visualizer) return;
    const ratio = Math.min(window.devicePixelRatio || 1, 1.65);
    canvas.width = Math.max(1, Math.floor(window.innerWidth * ratio));
    canvas.height = Math.max(1, Math.floor(window.innerHeight * ratio));
    visualizer.setRendererSize(canvas.width, canvas.height);
  }

  function render(now) {
    const position = currentPosition(now);
    const beat = beatState(position);
    const waveform = waveformState(position);
    // Lead Rekordbox's boundary by one beat so the scene lands with the
    // musical transition instead of visually reacting after it.
    const phrase = phraseAt(beat.number + 1);
    if (phrase.key !== lastPhraseKey) {
      const firstPhrase = !lastPhraseKey;
      lastPhraseKey = phrase.key;
      // Every Rekordbox phrase boundary gets a different preset. The phrase
      // name selects the family, so DOWN, UP, CHORUS, INTRO, OUTRO and FILL
      // produce intentionally different visual energy instead of two buckets.
      loadScene(phrase.family, firstPhrase);
    }

    const energy = waveform.available ? waveform.energy : 0;
    const bassEnergy = waveform.available ? waveform.bass : 0;
    const midEnergy = waveform.available ? waveform.mid : 0;
    const highEnergy = waveform.available ? waveform.high : 0;
    beatCrossingKick *= 0.94;
    const beatPulse = Math.max(
      deck.playing ? beat.proximity : 0,
      beatCrossingKick
    );
    const bassAmount = Math.min(
      1,
      Math.max(bassEnergy, energy * 0.28) * (0.3 + deck.bass * 0.9)
    );
    // Music-driven motion comes only from the exact Rekordbox beat phase.
    // Waveform/low-EQ bass determines how hard that beat lands, never when.
    const beatDrive = beatPulse * (0.1 + bassAmount * 1.18);
    const reactiveEnergy = beatDrive;
    const reactiveBass = beatDrive * (0.72 + bassAmount * 0.58);
    const reactiveMid = beatDrive * (0.22 + midEnergy * 0.24);
    const reactiveHigh = beatDrive * (0.12 + highEnergy * 0.2);
    smoothedFilter += (deck.filter - smoothedFilter) * 0.16;
    filterKick *= 0.91;
    const filterMagnitude = Math.abs(smoothedFilter);
    const filterValue = filterMagnitude <= 0.035
      ? 0
      : Math.sign(smoothedFilter) * (filterMagnitude - 0.035) / 0.965;
    const lowPass = Math.max(0, -filterValue);
    const highPass = Math.max(0, filterValue);

    // Butterchurn expects an AudioNode. These inaudible carrier tones carry
    // only exact beat-grid pulses, amplified by the waveform/low-EQ bass.
    if (synth.bass) {
      synth.bass.gain.value = reactiveBass * 0.68;
    }
    if (synth.mid) {
      synth.mid.gain.value = reactiveMid * 0.34;
    }
    if (synth.high) {
      synth.high.gain.value = reactiveHigh * 0.28;
    }

    const spectralTotal = Math.max(0.0001, bassEnergy + midEnergy + highEnergy);
    const spectralCenter = (
      bassEnergy * 0.08 + midEnergy * 0.5 + highEnergy * 0.92
    ) / spectralTotal;
    const scale =
      1.012
      + beatDrive * (0.034 + bassAmount * 0.036)
      + lowPass * 0.045
      + highPass * 0.018
      + filterKick * 0.012;
    const rotation =
      filterValue * (0.4 + beatPulse * 0.55)
      + filterKickDirection * filterKick * 0.65;
    canvas.style.transform = `scale(${scale.toFixed(4)}) rotate(${rotation.toFixed(3)}deg)`;
    canvas.style.filter =
      `blur(${(lowPass * 4.8).toFixed(2)}px) `
      + `brightness(${(
        0.88 + reactiveEnergy * 0.42 - lowPass * 0.2
        + highPass * 0.32 + filterKick * 0.14
      ).toFixed(3)}) `
      + `saturate(${(
        1.02 + spectralCenter * 0.44 - lowPass * 0.18
        + highPass * 0.8 + filterKick * 0.22
      ).toFixed(3)}) `
      + `contrast(${(
        1.04 + reactiveBass * 0.18 + highPass * 0.55
      ).toFixed(3)}) `
      + `hue-rotate(${(
        filterValue * 55 + filterKickDirection * filterKick * 38
      ).toFixed(1)}deg)`;

    const displayedBarBeat = beatCrossingKick > beat.proximity
      ? crossedBarBeat
      : beat.barBeat;
    const isDownbeat = displayedBarBeat === 1;
    const dotPulse = beatPulse;
    const isRedBeat = isDownbeat && dotPulse > 0.06;
    const dotColor = isRedBeat ? '255,24,42' : '255,255,255';
    beatDot.style.background = `rgb(${dotColor})`;
    beatDot.style.opacity = (
      0.72 + dotPulse * 0.28
    ).toFixed(3);
    beatDot.style.transform = `scale(${(
      0.84 + dotPulse * (isRedBeat ? 1.26 : 0.82)
    ).toFixed(3)})`;
    beatDot.style.boxShadow =
      '0 0 0 3px rgba(0,0,0,0.86), '
      + `0 0 ${(12 + dotPulse * (isRedBeat ? 36 : 20)).toFixed(1)}px `
      + `rgba(${dotColor},${(0.64 + dotPulse * 0.36).toFixed(3)})`;

    visualizer?.render();
    requestAnimationFrame(render);
  }

  setupSynth();
  createVisualizer();
  loadScene('flow', true);
  window.addEventListener('resize', resize);
  requestAnimationFrame(render);
})();
