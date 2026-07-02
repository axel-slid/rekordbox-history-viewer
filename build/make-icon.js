// Generates the iOS app icon (full-bleed 1024px, iOS rounds the corners itself):
// dark rekordbox-style tile with an RGB waveform. Raw RGBA -> PNG via zlib.
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

const W = 1024, H = 1024;
const px = Buffer.alloc(W * H * 4);

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const lerp = (a, b, t) => a + (b - a) * t;

function sdRoundRect(x, y, cx, cy, hw, hh, r) {
  const dx = Math.abs(x - cx) - (hw - r);
  const dy = Math.abs(y - cy) - (hh - r);
  const ax = Math.max(dx, 0), ay = Math.max(dy, 0);
  return Math.sqrt(ax * ax + ay * ay) + Math.min(Math.max(dx, dy), 0) - r;
}

// waveform bars: rekordbox RGB — mostly blue, ambers for mids, white for highs
const BLUE = [30, 122, 255], AMBER = [255, 158, 34], WHITE = [255, 255, 255];
const bars = [
  { h: 0.14, c: BLUE }, { h: 0.30, c: BLUE }, { h: 0.52, c: AMBER },
  { h: 0.74, c: BLUE }, { h: 0.60, c: WHITE }, { h: 0.88, c: BLUE },
  { h: 0.66, c: AMBER }, { h: 0.78, c: BLUE }, { h: 0.42, c: WHITE },
  { h: 0.26, c: BLUE }, { h: 0.13, c: AMBER }
];
const barW = 46, gap = 26;
const totalW = bars.length * barW + (bars.length - 1) * gap;
const startX = 512 - totalW / 2;

for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;

    // dark vertical gradient
    const t = y / H;
    let r = lerp(30, 12, t);
    let g = lerp(33, 14, t);
    let b = lerp(42, 20, t);

    // subtle blue glow behind the bars
    const hx = (x - 512) / 620, hy = (y - 512) / 620;
    const glow = Math.max(0, 1 - (hx * hx + hy * hy));
    r += glow * 4; g += glow * 14; b += glow * 30;

    let barA = 0, barC = BLUE;
    for (let k = 0; k < bars.length; k++) {
      const bx = startX + k * (barW + gap) + barW / 2;
      const bh = bars[k].h * 410;
      const sd = sdRoundRect(x + 0.5, y + 0.5, bx, 512, barW / 2, bh, barW / 2);
      const a = clamp(0.5 - sd, 0, 1);
      if (a > barA) { barA = a; barC = bars[k].c; }
    }
    if (barA > 0) {
      r = lerp(r, barC[0], barA);
      g = lerp(g, barC[1], barA);
      b = lerp(b, barC[2], barA);
    }

    px[i] = clamp(Math.round(r), 0, 255);
    px[i + 1] = clamp(Math.round(g), 0, 255);
    px[i + 2] = clamp(Math.round(b), 0, 255);
    px[i + 3] = 255;
  }
}

// ---- PNG encoding ----
const crcTable = [];
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  crcTable[n] = c >>> 0;
}
function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0);
ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8;
ihdr[9] = 6;
const raw = Buffer.alloc((W * 4 + 1) * H);
for (let y = 0; y < H; y++) {
  raw[y * (W * 4 + 1)] = 0;
  px.copy(raw, y * (W * 4 + 1) + 1, y * W * 4, (y + 1) * W * 4);
}
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0))
]);

const out = path.join(__dirname, '..', 'SetPlayer', 'Assets.xcassets', 'AppIcon.appiconset', 'icon.png');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, png);
console.log('wrote', out, png.length, 'bytes');
