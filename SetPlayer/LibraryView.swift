import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var player = PlayerManager.shared
    @State private var showImporter = false
    @State private var renamingSet: DJSet?
    @State private var renameText = ""
    @State private var newFolderSet: DJSet?
    @State private var newFolderName = ""
    @State private var navigationPath: [UUID] = []
    @State private var handledLaunchRequest = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Theme.background.ignoresSafeArea()

                if library.sets.isEmpty {
                    emptyState
                } else {
                    activityFeed
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
        .alert("Rename set", isPresented: .init(
            get: { renamingSet != nil },
            set: { if !$0 { renamingSet = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let set = renamingSet { library.rename(set.id, to: renameText) }
                renamingSet = nil
            }
            Button("Cancel", role: .cancel) { renamingSet = nil }
        }
        .alert("New folder", isPresented: .init(
            get: { newFolderSet != nil },
            set: { if !$0 { newFolderSet = nil } }
        )) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                if let set = newFolderSet { library.setFolder(set.id, folder: newFolderName) }
                newFolderSet = nil
            }
            Button("Cancel", role: .cancel) { newFolderSet = nil }
        }
        .onAppear {
            library.rescan()
            openRequestedSet()
        }
    }

    private func openRequestedSet() {
        guard !handledLaunchRequest else { return }
        handledLaunchRequest = true

        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--open-set"),
              arguments.indices.contains(flagIndex + 1) else { return }
        let requestedFile = arguments[flagIndex + 1]
        guard let set = library.sets.first(where: { $0.fileName == requestedFile }) else { return }
        navigationPath = [set.id]
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

    private var activityFeed: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(library.sets.sorted { $0.addedAt > $1.addedAt }) { set in
                    activityCard(set)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.background)
        .navigationDestination(for: UUID.self) { id in
            if let set = library.sets.first(where: { $0.id == id }) {
                PlayerView(setID: set.id)
            }
        }
    }

    @ViewBuilder
    private func activityCard(_ set: DJSet) -> some View {
        NavigationLink(value: set.id) {
            SetActivityCard(set: set)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = set.title
                renamingSet = set
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Menu {
                ForEach(library.folderNames, id: \.self) { folder in
                    Button(folder) { library.setFolder(set.id, folder: folder) }
                }
                Button {
                    newFolderName = ""
                    newFolderSet = set
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
                if set.folder != nil {
                    Button("Remove from Folder") {
                        library.setFolder(set.id, folder: nil)
                    }
                }
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
            Button(role: .destructive) {
                library.delete(set)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct SetActivityCard: View {
    @EnvironmentObject private var library: Library
    let set: DJSet

    @ObservedObject private var waveStore = WaveformStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(set.addedAt.formatted(date: .abbreviated, time: .shortened))
                        if let folder = set.folder {
                            Text("·")
                            Label(folder, systemImage: "folder.fill")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    if let location = set.locationName {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(14)

            activityCover
                .frame(height: 210)
                .clipped()

            HStack(spacing: 0) {
                activityStat("DURATION", formatTime(set.duration))
                activityStat("BPM", bpmText)
                activityStat("TRACKS", "\(set.annotations.count)")
                activityStat("MEDIA", "\(set.photos.count + set.videos.count)")
            }
            .padding(.vertical, 13)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.panelBorder))
    }

    @ViewBuilder
    private var activityCover: some View {
        if let url = library.coverPhotoURL(for: set),
           let image = UIImage(contentsOfFile: url.path) {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                if set.photos.count + set.videos.count > 1 {
                    Label(
                        "\(set.photos.count + set.videos.count)",
                        systemImage: "photo.on.rectangle.angled")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(10)
                }
            }
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Theme.accent.opacity(0.28),
                        Theme.background,
                        Theme.warm.opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                ActivityWaveformThumbnail(set: set)
                    .padding(.horizontal, 18)
                VStack {
                    Spacer()
                    HStack {
                        Label(
                            set.videos.isEmpty
                                ? "Add photos or muted videos inside the set"
                                : "\(set.videos.count) muted video\(set.videos.count == 1 ? "" : "s")",
                            systemImage: set.videos.isEmpty
                                ? "photo.badge.plus"
                                : "video.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.72))
                        Spacer()
                    }
                    .padding(14)
                }
            }
        }
    }

    private var bpmText: String {
        guard let bpm = waveStore.waveforms[set.id]?.bpm, bpm > 0 else { return "—" }
        return String(format: "%.0f", bpm)
    }

    private func activityStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.textDim)
                .kerning(0.9)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ActivityWaveformThumbnail: View {
    @ObservedObject private var store = WaveformStore.shared
    let set: DJSet

    var body: some View {
        Canvas { context, size in
            guard let waveform = store.waveform(for: set.id), waveform.count > 0 else {
                var x: CGFloat = 0
                while x < size.width {
                    let height = size.height * (0.18 + abs(sin(x * 0.045)) * 0.48)
                    context.fill(
                        Path(roundedRect: CGRect(
                            x: x,
                            y: (size.height - height) / 2,
                            width: 2,
                            height: height), cornerRadius: 1),
                        with: .color(Theme.accent.opacity(0.45)))
                    x += 4
                }
                return
            }

            var x: CGFloat = 0
            while x < size.width {
                let index = min(
                    waveform.count - 1,
                    Int(CGFloat(waveform.count) * x / max(1, size.width)))
                let height = max(2, CGFloat(waveform.amps[index]) * size.height * 0.78)
                let color = Color(
                    red: Double(waveform.r[index]),
                    green: Double(waveform.g[index]),
                    blue: Double(waveform.b[index]))
                context.fill(
                    Path(roundedRect: CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: 2.2,
                        height: height), cornerRadius: 1),
                    with: .color(color))
                x += 4
            }
        }
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

                OverviewWaveform(set: set)
                    .frame(height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
