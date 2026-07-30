import React from "react";
import {
  AbsoluteFill,
  Img,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import appIcon from "../../../SetPlayerMac/Assets.xcassets/AppIcon.appiconset/icon_256.png";
import sunsetPhoto from "../../../docs/set-player-sunset.jpg";

const pink = "#ff2e78";
const orange = "#ff962f";
const cyan = "#32d6e7";
const clamp = {extrapolateLeft: "clamp", extrapolateRight: "clamp"};

const Wave = ({frame, opacity = 1}) => {
  const points = Array.from({length: 70}, (_, index) => {
    const x = index * 14 - 4;
    const envelope = 0.25 + 0.75 * Math.sin((index / 69) * Math.PI);
    const y =
      270 +
      Math.sin(index * 1.8 + frame * 0.23) * 20 * envelope +
      Math.sin(index * 0.48 - frame * 0.14) * 34 * envelope;
    return `${x},${y}`;
  }).join(" ");
  const sweep = interpolate(frame % 120, [0, 120], [-100, 1060]);

  return (
    <svg
      width="960"
      height="540"
      style={{position: "absolute", inset: 0, opacity, filter: "drop-shadow(0 0 11px #ff2e7888)"}}
    >
      <defs>
        <linearGradient id="wave-gradient" x1="0" x2="1">
          <stop offset="0" stopColor={orange} />
          <stop offset=".5" stopColor={pink} />
          <stop offset="1" stopColor={cyan} />
        </linearGradient>
      </defs>
      <polyline points={points} fill="none" stroke="url(#wave-gradient)" strokeWidth="3" opacity=".72" />
      <rect x={sweep} y="205" width="4" height="130" rx="2" fill="#fff" opacity=".75" />
      <circle cx={sweep + 2} cy="270" r="8" fill={pink} opacity=".8" />
    </svg>
  );
};

const setRows = [
  ["Sunset Session", "42:18", pink],
  ["Warehouse Practice", "1:07:44", orange],
  ["Late Night House", "58:03", cyan],
  ["Afterhours", "36:51", pink],
];

const Sidebar = ({selected = 0}) => (
  <div
    style={{
      width: 177,
      height: "100%",
      padding: "17px 12px",
      boxSizing: "border-box",
      background: "rgba(21,23,20,.95)",
      borderRight: "1px solid #ffffff13",
      fontFamily: "Inter, ui-sans-serif, system-ui",
      color: "white",
    }}
  >
    <div
      style={{
        height: 31,
        borderRadius: 9,
        border: "1px solid #ffffff14",
        background: "#ffffff08",
        color: "#8e978d",
        fontSize: 9,
        display: "flex",
        alignItems: "center",
        padding: "0 10px",
        marginBottom: 17,
      }}
    >
      ⌕&nbsp;&nbsp; Search sets
    </div>
    <div style={{fontSize: 8, fontWeight: 800, letterSpacing: 1.4, color: "#727a72", margin: "0 5px 8px"}}>
      SETS
    </div>
    {setRows.map(([name, duration, color], index) => (
      <div
        key={name}
        style={{
          display: "grid",
          gridTemplateColumns: "30px 1fr",
          gap: 9,
          alignItems: "center",
          padding: "8px 7px",
          borderRadius: 9,
          marginBottom: 3,
          background: selected === index ? "#ff2e7830" : "transparent",
          border: selected === index ? "1px solid #ff2e7850" : "1px solid transparent",
        }}
      >
        <div
          style={{
            width: 30,
            height: 30,
            borderRadius: 7,
            background: `radial-gradient(circle at 70% 25%, #fff8, transparent 12%), linear-gradient(145deg, ${color}, #252824 66%)`,
            display: "grid",
            placeItems: "center",
            color: "#fff",
            fontSize: 12,
          }}
        >
          ♪
        </div>
        <div>
          <div style={{fontSize: 9.5, fontWeight: 750, whiteSpace: "nowrap"}}>{name}</div>
          <div style={{fontSize: 7.5, color: "#919990", marginTop: 2}}>{duration}</div>
        </div>
      </div>
    ))}
    <div style={{position: "absolute", bottom: 14, left: 18, fontSize: 7.5, color: "#8e978d", letterSpacing: 1}}>
      12 SETS
    </div>
  </div>
);

const ExtensionCard = ({icon, title, subtitle, color}) => (
  <div
    style={{
      width: 122,
      height: 78,
      borderRadius: 12,
      padding: "13px",
      boxSizing: "border-box",
      background: "linear-gradient(145deg, #30332d, #242722)",
      border: "1px solid #ffffff13",
      boxShadow: "inset 0 1px #ffffff0d",
      color: "white",
      fontFamily: "Inter, ui-sans-serif, system-ui",
    }}
  >
    <div style={{color, fontSize: 17, marginBottom: 8}}>{icon}</div>
    <div style={{fontSize: 9.5, fontWeight: 780}}>{title}</div>
    <div style={{fontSize: 7, color: "#969e95", marginTop: 2}}>{subtitle}</div>
  </div>
);

const HomeMock = () => (
  <div style={{display: "flex", width: "100%", height: "100%", background: "#22251f"}}>
    <Sidebar selected={-1} />
    <div
      style={{
        position: "relative",
        flex: 1,
        padding: "61px 48px",
        boxSizing: "border-box",
        fontFamily: "Inter, ui-sans-serif, system-ui",
        color: "white",
      }}
    >
      <div style={{textAlign: "center", marginBottom: 28}}>
        <div style={{color: pink, fontSize: 32, lineHeight: 1}}>〰</div>
        <div style={{fontSize: 27, fontWeight: 850, letterSpacing: -1.2, marginTop: 7}}>Set Player</div>
        <div style={{fontSize: 9.5, color: "#a5aca3", marginTop: 6}}>Choose a set to play it, or open an extension.</div>
      </div>
      <div style={{fontSize: 8, fontWeight: 800, letterSpacing: 1.5, color: "#9ba298", marginBottom: 9}}>
        EXTENSIONS
      </div>
      <div style={{display: "flex", gap: 9, flexWrap: "wrap"}}>
        <ExtensionCard icon="▣" title="Rave Lyrics" subtitle="Beat & phrase visuals" color={orange} />
        <ExtensionCard icon="❞" title="Live Lyrics" subtitle="Synced to Rekordbox" color={pink} />
        <ExtensionCard icon="↻" title="Rekordbox History" subtitle="Sets, tracks & stats" color={pink} />
        <ExtensionCard icon="●" title="Record Set" subtitle="Capture app audio" color={pink} />
        <ExtensionCard icon="≋" title="Volume Mixer" subtitle="Control app levels" color={orange} />
        <ExtensionCard icon="◫" title="Sync iPhone" subtitle="Library continuity" color={pink} />
        <ExtensionCard icon="＋" title="Import Audio" subtitle="Add files to Sets" color={pink} />
        <ExtensionCard icon="⚙" title="Settings" subtitle="Themes & preferences" color={pink} />
      </div>
    </div>
  </div>
);

const DetailMock = ({frame}) => {
  const playhead = interpolate(frame, [108, 184], [250, 665], clamp);

  return (
    <div style={{display: "flex", width: "100%", height: "100%", background: "#22251f"}}>
      <Sidebar selected={0} />
      <div style={{position: "relative", flex: 1, overflow: "hidden", fontFamily: "Inter, ui-sans-serif, system-ui", color: "white"}}>
        <div
          style={{
            height: 36,
            margin: "8px 11px 0",
            borderRadius: 9,
            background: "#101211ee",
            border: "1px solid #ffffff10",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            gap: 12,
            color: pink,
            fontSize: 11,
          }}
        >
          ⟲&nbsp;&nbsp; ◉&nbsp;&nbsp; ≋&nbsp;&nbsp; ❞
          <strong style={{color: "white", fontSize: 9, margin: "0 18px"}}>Sunset Session</strong>
          <span style={{color: "#aab0a8", fontSize: 8}}>0:00</span>
          <span style={{fontSize: 17}}>▶</span>
          <span style={{color: "#aab0a8", fontSize: 8}}>-42:18</span>
        </div>
        <div
          style={{
            position: "relative",
            height: 245,
            margin: "8px 11px",
            borderRadius: 13,
            overflow: "hidden",
            background: "#1b201c",
          }}
        >
          <Img
            src={sunsetPhoto}
            style={{
              position: "absolute",
              inset: 0,
              width: "100%",
              height: "100%",
              objectFit: "cover",
              filter: "brightness(.72) saturate(.92)",
              transform: `scale(${1.02 + (frame - 108) * 0.0007})`,
            }}
          />
          <div
            style={{
              position: "absolute",
              inset: 0,
              background: "linear-gradient(90deg,rgba(8,11,9,.82),rgba(8,11,9,.08) 70%), linear-gradient(0deg,rgba(8,11,9,.74),transparent 54%)",
            }}
          />
          <svg width="100%" height="100%" style={{position: "absolute", inset: 0}}>
            <polyline
              points={Array.from({length: 56}, (_, i) => `${200 + i * 8},${151 + Math.sin(i * 1.3 + frame * 0.17) * (7 + (i % 5) * 2)}`).join(" ")}
              fill="none"
              stroke={cyan}
              strokeWidth="2"
              opacity=".8"
            />
            <line x1={playhead - 177} y1="122" x2={playhead - 177} y2="183" stroke={pink} strokeWidth="2" />
          </svg>
          <div style={{position: "absolute", left: 22, top: 26, fontSize: 29, fontWeight: 900, letterSpacing: -1.3}}>
            Sunset Session
          </div>
          <div style={{position: "absolute", left: 24, top: 63, fontSize: 8, color: "#dbe2da"}}>
            ◉ Ocean overlook&nbsp;&nbsp;&nbsp; ⚑ 14 tracks&nbsp;&nbsp;&nbsp; ▢ July 2026
          </div>
          <div style={{position: "absolute", left: 24, bottom: 20, display: "flex", gap: 36}}>
            <div><b style={{color: pink, fontSize: 7}}>PLAYING</b><div style={{fontSize: 9, fontWeight: 750}}>Falling Back — Obskür</div></div>
            <div><b style={{color: "#cbd2ca", fontSize: 7}}>NEXT</b><div style={{fontSize: 9, fontWeight: 750}}>Breather — Chris Stussy</div></div>
          </div>
        </div>
        <div style={{display: "grid", gridTemplateColumns: "1fr 1.15fr", gap: 9, margin: "0 11px"}}>
          <div style={{height: 91, borderRadius: 11, background: "#292c27", border: "1px solid #ffffff12", padding: 12, boxSizing: "border-box"}}>
            <div style={{fontSize: 8, fontWeight: 800, letterSpacing: 1, color: "#b6bdb4"}}>⌖ LOCATION</div>
            <div style={{height: 48, marginTop: 8, borderRadius: 8, backgroundImage: "linear-gradient(45deg,#2e332e 25%,transparent 25%),linear-gradient(-45deg,#2e332e 25%,transparent 25%)", backgroundSize: "12px 12px", backgroundColor: "#242722"}} />
          </div>
          <div style={{height: 91, borderRadius: 11, background: "#292c27", border: "1px solid #ffffff12", padding: 12, boxSizing: "border-box"}}>
            <div style={{fontSize: 8, fontWeight: 800, letterSpacing: 1, color: "#b6bdb4"}}>♪&nbsp; 14 TRACKS <span style={{float: "right", color: pink}}>⊕ Mark Track</span></div>
            {["Falling Back", "Breather", "Call It What You Like"].map((track, index) => (
              <div key={track} style={{display: "grid", gridTemplateColumns: "20px 1fr 32px", gap: 6, marginTop: 7, fontSize: 7.5, color: index ? "#aeb5ac" : "white"}}>
                <span>0{index + 1}</span><strong>{track}</strong><span>{index * 3 + 2}:3{index}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
};

const PlayerWindow = ({children, frame, start, end, detail = false}) => {
  const {fps} = useVideoConfig();
  const show = spring({frame: frame - start, fps, config: {damping: 15, stiffness: 100}});
  const hide = interpolate(frame, [end - 16, end], [1, 0], clamp);
  const tilt = Math.sin((frame - start) / 35) * 1.2;
  const zoom = detail
    ? interpolate(frame, [start, end], [1.03, 1.1], clamp)
    : interpolate(frame, [start, end], [1, 1.05], clamp);

  return (
    <div
      style={{
        position: "absolute",
        left: 86,
        top: 65,
        width: 788,
        height: 410,
        borderRadius: 22,
        overflow: "hidden",
        background: "#181a16",
        border: "1px solid rgba(255,255,255,.16)",
        boxShadow: "0 52px 110px #000e, 0 0 60px #ff2e7828",
        opacity: show * hide,
        transform: `perspective(1200px) translateY(${(1 - show) * 90}px) rotateX(${(1 - show) * 13}deg) rotateY(${tilt}deg) scale(${0.68 + show * 0.32})`,
      }}
    >
      <div style={{width: "100%", height: "100%", transform: `scale(${zoom})`}}>{children}</div>
      <div
        style={{
          position: "absolute",
          inset: 0,
          background:
            "linear-gradient(112deg, rgba(255,255,255,.10), transparent 24%, transparent 74%, rgba(255,46,120,.07))",
          pointerEvents: "none",
        }}
      />
    </div>
  );
};

export const SetPlayerDemo = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const detailReveal = interpolate(frame, [104, 132], [0, 1], clamp);
  const featureScene = interpolate(frame, [166, 184], [0, 1], clamp);
  const close = interpolate(frame, [221, 239], [0, 1], clamp);
  const logoSpin = spring({frame: frame - 5, fps, config: {damping: 11, stiffness: 110}});

  return (
    <AbsoluteFill
      style={{
        overflow: "hidden",
        background: "#10120f",
      }}
    >
      <Wave frame={frame} opacity={featureScene * 0.55} />

      <PlayerWindow frame={frame} start={0} end={121}>
        <HomeMock />
      </PlayerWindow>
      <div
        style={{
          position: "absolute",
          left: 433,
          top: 15,
          width: 94,
          height: 94,
          borderRadius: 25,
          background: "#181a16",
          padding: 7,
          boxSizing: "border-box",
          boxShadow: "0 20px 50px #000c, 0 0 40px #ff2e7850",
          opacity: logoSpin * (1 - detailReveal),
          transform: `translateY(${(1 - logoSpin) * -50}px) rotate(${(1 - logoSpin) * -18}deg)`,
        }}
      >
        <Img src={appIcon} style={{width: "100%", height: "100%", borderRadius: 20}} />
      </div>

      <div
        style={{
          position: "absolute",
          inset: 0,
          clipPath: `circle(${detailReveal * 74}% at 50% 48%)`,
          opacity: 1 - featureScene,
        }}
      >
        <PlayerWindow frame={frame} start={108} end={184} detail>
          <DetailMock frame={frame} />
        </PlayerWindow>
        <div
          style={{
            position: "absolute",
            left: interpolate(frame, [122, 180], [265, 810], clamp),
            top: 266,
            width: 3,
            height: 87,
            background: pink,
            boxShadow: "0 0 18px #ff2e78",
            opacity: detailReveal,
          }}
        />
      </div>

      <div
        style={{
          position: "absolute",
          inset: 0,
          opacity: featureScene * (1 - close),
          transform: `scale(${0.9 + featureScene * 0.1})`,
          color: "#fff",
          fontFamily: "Inter, ui-sans-serif, system-ui",
        }}
      >
        <div style={{position: "absolute", left: 64, top: 64}}>
          <div style={{fontSize: 17, fontWeight: 850, color: pink, letterSpacing: 4.3}}>YOUR SET, ALIVE</div>
          <div style={{fontSize: 44, fontWeight: 900, letterSpacing: -2.2, marginTop: 8, lineHeight: 1.02}}>
            Play it. See it.
            <br />
            Remember every moment.
          </div>
        </div>
        <div
          style={{
            position: "absolute",
            right: 76,
            top: 67,
            width: 132,
            height: 132,
            borderRadius: 35,
            background: "#191b17",
            padding: 10,
            boxSizing: "border-box",
            boxShadow: "0 25px 60px #000d, 0 0 45px #ff2e7855",
            transform: `rotate(${Math.sin(frame / 14) * 5}deg)`,
          }}
        >
          <Img src={appIcon} style={{width: "100%", height: "100%", borderRadius: 27}} />
        </div>
      </div>

      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "grid",
          placeItems: "center",
          textAlign: "center",
          color: "#fff",
          fontFamily: "Inter, ui-sans-serif, system-ui",
          opacity: close,
          transform: `scale(${0.82 + close * 0.18})`,
          background: `rgba(7,8,7,${close * 0.82})`,
        }}
      >
        <div>
          <div style={{fontSize: 64, fontWeight: 930, letterSpacing: -3.4}}>Set Player</div>
          <div style={{fontSize: 17, fontWeight: 780, letterSpacing: 3, color: pink, marginTop: 6}}>
            THE MEMORY LAYER FOR EVERY SET
          </div>
        </div>
      </div>
    </AbsoluteFill>
  );
};
