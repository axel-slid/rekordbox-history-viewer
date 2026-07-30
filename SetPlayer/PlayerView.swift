import AVKit
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PlayerView: View {
    let setID: UUID

    @EnvironmentObject private var library: Library
    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var waveStore = WaveformStore.shared

    @State private var renamingCue: SetAnnotation?
    @State private var cueName = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedVideoItems: [PhotosPickerItem] = []
    @State private var importingPhotos = false
    @State private var importingVideos = false
    @State private var showLocationPicker = false
    @State private var fullScreenPhotoID: UUID?
    @State private var selectedMediaID: UUID?

    private var set: DJSet? {
        library.sets.first(where: { $0.id == setID })
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if let set {
                ScrollView {
                    VStack(spacing: 12) {
                        activitySummary(set)

                        if let latitude = set.locationLatitude,
                           let longitude = set.locationLongitude {
                            SetLocationPreview(
                                name: set.locationName ?? "Set location",
                                latitude: latitude,
                                longitude: longitude)
                                .frame(height: 230)
                        }

                        mediaGallery(set)

                        infoBar(set)

                        ScrollingWaveform(set: set)
                            .frame(height: 158)
                            .background(Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))

                        OverviewWaveform(set: set)
                            .frame(height: 46)
                            .background(Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.panelBorder))

                        transport

                        markTrackRow(set)

                        cueList(set)
                    }
                    .padding(14)
                }
            }
        }
        .navigationTitle(set?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 12,
                    matching: .images
                ) {
                    Image(systemName: "camera.fill")
                }
                PhotosPicker(
                    selection: $selectedVideoItems,
                    maxSelectionCount: 6,
                    matching: .videos
                ) {
                    Image(systemName: "video.fill")
                }
                Button {
                    showLocationPicker = true
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                AirPlayButton()
                    .frame(width: 32, height: 32)
            }
        }
        .onAppear {
            guard let set else { return }
            if player.current?.id != set.id {
                player.load(set, autoplay: false)
            }
            waveStore.request(for: set, url: library.audioURL(for: set), urgent: true)
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            importPhotos(items)
        }
        .onChange(of: selectedVideoItems) { _, items in
            guard !items.isEmpty else { return }
            importVideos(items)
        }
        .fullScreenCover(isPresented: .init(
            get: { fullScreenPhotoID != nil },
            set: { if !$0 { fullScreenPhotoID = nil } }
        )) {
            if let fullScreenPhotoID {
                FullScreenPhotoGallery(
                    setID: setID,
                    initialPhotoID: fullScreenPhotoID)
            }
        }
        .sheet(isPresented: $showLocationPicker) {
            SetLocationPicker(
                name: set?.locationName,
                latitude: set?.locationLatitude,
                longitude: set?.locationLongitude
            ) { name, latitude, longitude in
                library.setLocation(
                    name,
                    latitude: latitude,
                    longitude: longitude,
                    for: setID)
            }
        }
        .alert("Cue name", isPresented: .init(
            get: { renamingCue != nil },
            set: { if !$0 { renamingCue = nil } }
        )) {
            TextField("Name", text: $cueName)
            Button("Save") {
                if let cue = renamingCue, let set {
                    var anns = set.annotations
                    if let i = anns.firstIndex(where: { $0.id == cue.id }) {
                        anns[i].label = cueName.isEmpty ? cue.label : cueName
                        library.setAnnotations(anns, for: set.id)
                    }
                }
                renamingCue = nil
            }
            Button("Cancel", role: .cancel) { renamingCue = nil }
        }
        .alert("Playback error", isPresented: .init(
            get: { player.loadError != nil },
            set: { if !$0 { player.loadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.loadError ?? "")
        }
    }

    private func activitySummary(_ set: DJSet) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(set.title)
                    .font(.title2.weight(.bold))
                HStack(spacing: 5) {
                    Text(set.addedAt.formatted(date: .long, time: .shortened))
                    if let folder = set.folder {
                        Text("·")
                        Label(folder, systemImage: "folder.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                Button {
                    showLocationPicker = true
                } label: {
                    Label(
                        set.locationName ?? "Add location",
                        systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(
                            set.locationName == nil ? Theme.textDim : Theme.accent)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if importingPhotos || importingVideos {
                ProgressView()
            } else {
                Label(
                    "\(set.photos.count + set.videos.count)",
                    systemImage: "photo.on.rectangle.angled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
    }

    @ViewBuilder
    private func mediaGallery(_ set: DJSet) -> some View {
        if set.photos.isEmpty && set.videos.isEmpty {
            ZStack {
                LinearGradient(
                    colors: [
                        Theme.accent.opacity(0.3),
                        Theme.background,
                        Theme.warm.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34))
                    Text("Add moments from this set")
                        .font(.headline)
                    Text("Photos and muted videos become your activity recap.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))

                    HStack(spacing: 10) {
                        PhotosPicker(
                            selection: $selectedPhotoItems,
                            maxSelectionCount: 12,
                            matching: .images
                        ) {
                            Label("Photos", systemImage: "camera.fill")
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.13), in: Capsule())
                        }
                        PhotosPicker(
                            selection: $selectedVideoItems,
                            maxSelectionCount: 6,
                            matching: .videos
                        ) {
                            Label("Videos", systemImage: "video.fill")
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.13), in: Capsule())
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .frame(height: 220)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
        } else {
            VStack(spacing: 10) {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(set.photos) { photo in
                                if let image = UIImage(
                                    contentsOfFile: library.photoURL(for: photo).path) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(
                                            width: geometry.size.width,
                                            height: geometry.size.height)
                                        .background(Color.black)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            fullScreenPhotoID = photo.id
                                        }
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                library.deletePhoto(photo.id, from: set.id)
                                            } label: {
                                                Label("Remove Photo", systemImage: "trash")
                                            }
                                        }
                                        .id(photo.id)
                                }
                            }

                            ForEach(set.videos) { video in
                                MutedVideoPlayer(url: library.videoURL(for: video))
                                    .frame(
                                        width: geometry.size.width,
                                        height: geometry.size.height)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        library.deleteVideo(video.id, from: set.id)
                                    } label: {
                                        Label("Remove Video", systemImage: "trash")
                                    }
                                }
                                .id(video.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $selectedMediaID)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottomTrailing) {
                        Text(mediaPositionLabel(for: set))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(9)
                    }
                }
                .frame(height: 260)

                HStack(spacing: 12) {
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 12,
                        matching: .images
                    ) {
                        Label("Add photos", systemImage: "camera.fill")
                    }
                    PhotosPicker(
                        selection: $selectedVideoItems,
                        maxSelectionCount: 6,
                        matching: .videos
                    ) {
                        Label("Add videos", systemImage: "video.fill")
                    }
                    Spacer()
                    Label(
                        "\(set.videos.count) muted",
                        systemImage: "speaker.slash.fill")
                        .foregroundStyle(Theme.textDim)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 4)
            }
        }
    }

    private func mediaPositionLabel(for set: DJSet) -> String {
        let ids = set.photos.map(\.id) + set.videos.map(\.id)
        let position = ids.firstIndex(where: { $0 == selectedMediaID }).map { $0 + 1 } ?? 1
        return "\(position) / \(ids.count)"
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard let set else { return }
        importingPhotos = true
        Task {
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        continue
                    }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    try library.addPhoto(data: data, fileExtension: ext, to: set.id)
                } catch {
                    library.importError = "Couldn’t add photo: \(error.localizedDescription)"
                }
            }
            selectedPhotoItems = []
            importingPhotos = false
        }
    }

    private func importVideos(_ items: [PhotosPickerItem]) {
        guard let set else { return }
        importingVideos = true
        Task {
            for item in items {
                do {
                    guard let video = try await item.loadTransferable(
                        type: ImportedVideo.self) else { continue }
                    try library.addVideo(at: video.url, to: set.id)
                    try? FileManager.default.removeItem(at: video.url)
                } catch {
                    library.importError = "Couldn’t add video: \(error.localizedDescription)"
                }
            }
            selectedVideoItems = []
            importingVideos = false
        }
    }

    // CDJ-style readout: elapsed · BPM · remaining
    private func infoBar(_ set: DJSet) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("TIME")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.2)
                Text(formatTime(player.displayTime))
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
            }
            Spacer()
            VStack(spacing: 2) {
                Text("BPM")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.2)
                Text(bpmLabel)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("REMAIN")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.2)
                Text("-" + formatTime(max(0, player.duration - player.displayTime)))
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
    }

    private var bpmLabel: String {
        guard let wf = waveStore.waveforms[setID], wf.bpm > 0 else { return "––.–" }
        return String(format: "%.1f", wf.bpm)
    }

    private var transport: some View {
        HStack(spacing: 26) {
            transportButton("gobackward.15") { player.skip(-15) }

            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 78, height: 78)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.45), radius: 14)
            }
            .buttonStyle(.plain)

            transportButton("goforward.15") { player.skip(15) }
        }
        .padding(.vertical, 2)
    }

    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.panel, in: Circle())
                .overlay(Circle().stroke(Theme.panelBorder))
        }
        .buttonStyle(.plain)
    }

    private func markTrackRow(_ set: DJSet) -> some View {
        Button {
            addCue(set)
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("MARK TRACK")
                    .kerning(1.5)
                Spacer()
                Text(formatTime(player.displayTime))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.warm, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func cueList(_ set: DJSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRACKS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textDim)
                .kerning(1.2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if set.annotations.isEmpty {
                VStack(spacing: 6) {
                    Text("No tracks marked yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textDim)
                    Text("Hit Mark Track while playing to delineate songs")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(Array(set.annotations.enumerated()), id: \.element.id) { index, cue in
                    Button {
                        player.seek(to: cue.time)
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.cueColor(index))
                                .frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cue.label)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(formatTime(cue.time))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.to.line")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                        .padding(12)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.panelBorder))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renamingCue = cue
                            cueName = cue.label
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            var anns = set.annotations
                            anns.removeAll { $0.id == cue.id }
                            library.setAnnotations(anns, for: set.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func addCue(_ set: DJSet) {
        var anns = set.annotations
        let n = anns.count + 1
        anns.append(SetAnnotation(time: player.liveTime(), label: "Track \(n)"))
        library.setAnnotations(anns, for: set.id)
    }
}

private struct ImportedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty
                ? "mov"
                : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("set-player-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedVideo(url: destination)
        }
    }
}

private struct MutedVideoPlayer: View {
    @State private var player: AVPlayer
    @State private var isMuted = true

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoPlayer(player: player)
                .background(Color.black)

            Button {
                isMuted.toggle()
                applyMuteState()
            } label: {
                Label(
                    isMuted ? "Muted" : "Sound On",
                    systemImage: isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.68), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(10)
        }
            .onAppear {
                applyMuteState()
                player.play()
            }
            .onDisappear {
                player.pause()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .AVPlayerItemDidPlayToEndTime
            )) { notification in
                guard let item = notification.object as? AVPlayerItem,
                      item === player.currentItem else { return }
                player.seek(to: .zero)
                applyMuteState()
                player.play()
            }
    }

    private func applyMuteState() {
        player.isMuted = isMuted
        player.volume = isMuted ? 0 : 1
    }
}

private struct FullScreenPhotoGallery: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: Library

    let setID: UUID
    @State private var selectedPhotoID: UUID?

    init(setID: UUID, initialPhotoID: UUID) {
        self.setID = setID
        _selectedPhotoID = State(initialValue: initialPhotoID)
    }

    private var set: DJSet? {
        library.sets.first(where: { $0.id == setID })
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let set {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(set.photos) { photo in
                                if let image = UIImage(
                                    contentsOfFile: library.photoURL(for: photo).path) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(
                                            width: geometry.size.width,
                                            height: geometry.size.height)
                                        .id(photo.id)
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $selectedPhotoID)
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .padding()
        }
    }
}
