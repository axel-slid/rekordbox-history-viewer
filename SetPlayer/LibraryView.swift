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
                ProgressView()
                    .controlSize(.small)
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
                    Spacer()
                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            .buttonStyle(.plain)
        }
    }
}
