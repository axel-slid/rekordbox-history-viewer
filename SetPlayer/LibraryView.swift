import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var player = PlayerManager.shared
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if library.sets.isEmpty {
                    emptyState
                } else {
                    setList
                }
            }
            .navigationTitle("Sets")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.current != nil {
                    NowPlayingBar()
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.mp3, .wav, .aiff, .mpeg4Audio, .audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                library.importFiles(urls)
            }
        }
        .overlay {
            if library.importing {
                ProgressView("Importing…")
                    .padding(24)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .alert("Import failed", isPresented: .init(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importError ?? "")
        }
        .onAppear { library.rescan() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text("No sets yet")
                .font(.title3.weight(.semibold))
            Text("Tap + to load an MP3 or WAV from Files")
                .font(.subheadline)
                .foregroundStyle(Theme.textDim)
        }
    }

    private var setList: some View {
        List {
            ForEach(library.sets) { set in
                NavigationLink(value: set.id) {
                    SetRow(set: set)
                }
                .listRowBackground(Theme.panel)
            }
            .onDelete { offsets in
                for i in offsets { library.delete(library.sets[i]) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationDestination(for: UUID.self) { id in
            if let set = library.sets.first(where: { $0.id == id }) {
                PlayerView(setID: set.id)
            }
        }
    }
}

struct SetRow: View {
    let set: DJSet

    @ObservedObject private var waveStore = WaveformStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(set.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 4)
            if let wf = waveStore.waveforms[set.id], wf.bpm > 0 {
                Text(String(format: "%.0f BPM", wf.bpm))
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            } else if waveStore.generating.contains(set.id) {
                if let pct = waveStore.progress[set.id] {
                    Text("\(Int(pct * 100))%")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.07), in: Capsule())
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var meta: String {
        var parts = [formatTime(set.duration), formatSize(set.fileSize)]
        parts.append(set.addedAt.formatted(date: .abbreviated, time: .shortened))
        if !set.annotations.isEmpty { parts.append("\(set.annotations.count) cues") }
        return parts.joined(separator: " · ")
    }
}

struct NowPlayingBar: View {
    @ObservedObject private var player = PlayerManager.shared

    var body: some View {
        if let set = player.current {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    NavigationLink(value: set.id) {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.title)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                Text("\(formatTime(player.displayTime)) / \(formatTime(player.duration))")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textDim)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                }

                MiniPlayerScrubber()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 9)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }
}

struct MiniPlayerScrubber: View {
    @ObservedObject private var player = PlayerManager.shared
    @State private var dragTime: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let duration = max(1, player.duration)
            let current = max(0, min(dragTime ?? player.displayTime, duration))
            let fraction = CGFloat(current / duration)
            let filledWidth = width * fraction
            let knobSize: CGFloat = 11

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(4, filledWidth), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                    .offset(x: min(max(0, filledWidth - knobSize / 2), width - knobSize))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = time(for: value.location.x, width: width)
                        dragTime = time
                        player.seek(to: time)
                    }
                    .onEnded { value in
                        player.seek(to: time(for: value.location.x, width: width))
                        dragTime = nil
                    }
            )
        }
        .frame(height: 20)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(dragTime ?? player.displayTime)) of \(formatTime(player.duration))")
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        let fraction = max(0, min(1, x / max(1, width)))
        return TimeInterval(fraction) * player.duration
    }
}
