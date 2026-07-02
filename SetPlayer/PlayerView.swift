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
                VStack(spacing: 12) {
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
        Group {
            if set.annotations.isEmpty {
                VStack(spacing: 6) {
                    Text("No tracks marked yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textDim)
                    Text("Hit Mark Track while playing to delineate songs")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
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
                        }
                        .listRowBackground(Theme.panel)
                        .listRowSeparatorTint(Theme.panelBorder)
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
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
