import SwiftUI

struct PlayerView: View {
    let setID: UUID

    @EnvironmentObject private var library: Library
    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var waveStore = WaveformStore.shared

    @State private var renamingCue: SetAnnotation?
    @State private var cueName = ""

    private var set: DJSet? {
        library.sets.first(where: { $0.id == setID })
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if let set {
                VStack(spacing: 14) {
                    ScrollingWaveform(set: set)
                        .frame(height: 150)
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder))

                    OverviewWaveform(set: set)
                        .frame(height: 44)
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    timeRow
                    transport
                    cueList(set)
                }
                .padding(14)
            }
        }
        .navigationTitle(set?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let set else { return }
            if player.current?.id != set.id {
                player.load(set)
            }
            waveStore.request(for: set, url: library.audioURL(for: set))
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

    private var timeRow: some View {
        HStack {
            Text(formatTime(player.displayTime))
                .font(.system(.title3, design: .monospaced).weight(.medium))
            Spacer()
            Text(formatTime(player.duration))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
    }

    private var transport: some View {
        HStack(spacing: 34) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 30))
            }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }
            Button { player.skip(15) } label: {
                Image(systemName: "goforward.15").font(.system(size: 30))
            }
        }
        .foregroundStyle(Theme.accent)
    }

    private func cueList(_ set: DJSet) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("TRACKS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.5)
                Spacer()
                Button {
                    addCue(set)
                } label: {
                    Label("Mark track", systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                }
            }

            if set.annotations.isEmpty {
                Text("Hit “Mark track” while playing to delineate songs in the set")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(Array(set.annotations.enumerated()), id: \.element.id) { index, cue in
                        Button {
                            player.seek(to: cue.time)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Theme.cueColor(index))
                                    .frame(width: 10, height: 10)
                                Text(cue.label)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatTime(cue.time))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.textDim)
                            }
                        }
                        .listRowBackground(Theme.panel)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                var anns = set.annotations
                                anns.removeAll { $0.id == cue.id }
                                library.setAnnotations(anns, for: set.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renamingCue = cue
                                cueName = cue.label
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(Theme.accent)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
