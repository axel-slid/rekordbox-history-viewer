import AppKit
import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var library: MacLibrary
    @ObservedObject private var recorder = MacSetRecorder.shared
    @ObservedObject private var themes = MacThemeStore.shared

    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showRecorder = false
    @State private var showRekordboxHistory = false
    @State private var showVolumeMixer = false
    @State private var showSettings = false
    @State private var rekordboxLaunchError: String?
    @State private var renameTarget: DJSet?
    @State private var renameText = ""
    @State private var deleteTarget: DJSet?
    @State private var showTracksSidebar = false
    @State private var isLaunching = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ZStack(alignment: .trailing) {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        sidebar
                            .overlay(alignment: .trailing) {
                                ZStack {
                                    Rectangle()
                                        .fill(Theme.panelBorder.opacity(0.9))
                                        .frame(width: 2)
                                    Capsule()
                                        .fill(themes.selectedTheme.accent.opacity(0.72))
                                        .frame(width: 5, height: 86)
                                }
                                .offset(x: 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                            .navigationSplitViewColumnWidth(min: 250, ideal: 285, max: 340)
                    } detail: {
                        ZStack {
                            Theme.background.ignoresSafeArea()
                            if let set = selectedSet {
                                MacPlayerDetail(
                                    set: set,
                                    showTracksSidebar: $showTracksSidebar,
                                    columnVisibility: $columnVisibility,
                                    onSync: {
                                        Task { await library.syncNow() }
                                    },
                                    onShowRekordboxHistory: {
                                        showRekordboxHistory = true
                                    },
                                    onOpenRekordbox: openRekordbox,
                                    onShowRecorder: {
                                        showRecorder = true
                                    },
                                    onShowVolumeMixer: {
                                        showVolumeMixer = true
                                    },
                                    onShowLiveLyrics: {
                                        openWindow(id: "live-lyrics")
                                    },
                                    onShowSettings: {
                                        showSettings = true
                                    },
                                    onShowImporter: {
                                        showImporter = true
                                    })
                                    .id(set.id)
                            } else {
                                emptyDetail
                            }
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .padding(.top, -38)

                }
            }

            if isLaunching {
                MacLaunchLoadingView()
                    .transition(.opacity)
                    .zIndex(20)
                    .allowsHitTesting(false)
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.mp3, .wav, .aiff, .mpeg4Audio, .audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                library.importFiles(urls)
            }
        }
        .sheet(isPresented: $showRecorder) {
            MacRecorderPanel()
                .environmentObject(library)
        }
        .sheet(isPresented: $showRekordboxHistory) {
            MacRekordboxHistoryPanel()
                .environmentObject(library)
        }
        .sheet(isPresented: $showVolumeMixer) {
            MacVolumeMixerPanel()
        }
        .sheet(isPresented: $showSettings) {
            MacSettingsPanel()
        }
        .alert("Couldn’t open Rekordbox", isPresented: .init(
            get: { rekordboxLaunchError != nil },
            set: { if !$0 { rekordboxLaunchError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rekordboxLaunchError ?? "Rekordbox could not be found.")
        }
        .alert("Rename set", isPresented: .init(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renameTarget {
                    library.rename(renameTarget.id, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
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
        .alert("Delete this set?", isPresented: .init(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete Set", role: .destructive) {
                if let deleteTarget {
                    if selection == deleteTarget.id {
                        selection = nil
                    }
                    library.delete(deleteTarget)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This permanently removes \(deleteTarget?.title ?? "the set") and its attached photos and videos.")
        }
        .overlay {
            MacPlaybackErrorPresenter()
        }
        .onChange(of: library.latestAddedSetID) { _, newValue in
            if let newValue {
                selection = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            MacSetRecorder.shared.shutdown()
            MacVolumeMixer.shared.shutdown()
        }
        .task {
            Task {
                await library.start()
            }
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.28)) {
                isLaunching = false
            }
        }
    }

    private var rekordboxToolbarIcon: some View {
        Image("RekordboxLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(themes.selectedTheme.accent)
            .frame(width: 18, height: 18)
            .accessibilityLabel("Rekordbox")
    }

    private var rekordboxApplicationURL: URL? {
        let workspace = NSWorkspace.shared
        let expectedLocations = [
            workspace.urlForApplication(withBundleIdentifier: "com.pioneerdj.rekordboxdj"),
            URL(fileURLWithPath: "/Applications/rekordbox 7/rekordbox.app"),
            URL(fileURLWithPath: "/Applications/rekordbox.app")
        ]
        return expectedLocations
            .compactMap({ $0 })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func openRekordbox() {
        guard let applicationURL = rekordboxApplicationURL else {
            rekordboxLaunchError = "Rekordbox is not installed in Applications."
            return
        }

        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { _, error in
            if let error {
                DispatchQueue.main.async {
                    rekordboxLaunchError = error.localizedDescription
                }
            }
        }
    }

    private var selectedSet: DJSet? {
        guard let selection else { return nil }
        return library.sets.first(where: { $0.id == selection })
    }

    @ViewBuilder
    private var trackDrawer: some View {
        if let set = selectedSet {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTracksSidebar.toggle()
                    }
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: showTracksSidebar
                              ? "chevron.right"
                              : "chevron.left")
                        Image(systemName: "music.note.list")
                            .font(.system(size: 15, weight: .semibold))
                        Text("TRACKS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .kerning(1)
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 116)
                    .background(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.panelBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .help(showTracksSidebar ? "Hide tracks" : "Show tracks")

                if showTracksSidebar {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showTracksSidebar = false
                                }
                            } label: {
                                Label("Close", systemImage: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .help("Hide tracks")
                            .padding(12)
                        }

                        Divider().overlay(Theme.panelBorder)

                        ScrollView {
                            MacTracksWidget(set: set)
                                .padding(12)
                        }
                    }
                    .frame(width: 440)
                    .background(Theme.background)
                    .overlay(alignment: .leading) {
                        Divider().overlay(Theme.panelBorder)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.vertical, 12)
            .shadow(color: .black.opacity(showTracksSidebar ? 0.35 : 0.18), radius: 18)
        }
    }

    private var filteredSets: [DJSet] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.sets }
        return library.sets.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.fileName.localizedCaseInsensitiveContains(query)
                || ($0.folder?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.locationName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Keep the window controls in their own titlebar row instead of
            // letting the search field sit underneath them.
            Color.clear
                .frame(height: 38)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textDim)
                TextField("Search sets", text: $searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) { _, newValue in
                        let singleLine = newValue
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\r", with: " ")
                        if singleLine != newValue {
                            searchText = singleLine
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Clear set search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.panelBorder))
            .padding(12)

            ZStack {
                List(selection: $selection) {
                    ForEach(visibleFolders, id: \.self) { folder in
                        Section(folder) {
                            setRows(filteredSets.filter { $0.folder == folder })
                        }
                    }

                    let unfiled = filteredSets.filter { $0.folder == nil }
                    if !unfiled.isEmpty {
                        Section(visibleFolders.isEmpty ? "LIBRARY" : "UNFILED") {
                            setRows(unfiled)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.background)

                if !library.sets.isEmpty && filteredSets.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        Text("No matching sets")
                            .font(.headline)
                        Text("Your sets are still here. Clear the search to show all \(library.sets.count).")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 210)
                        Button("Clear Search") {
                            searchText = ""
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                }
            }

            Divider().overlay(Theme.panelBorder)

            HStack {
                Text("\(library.sets.count) SETS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Button("Show Files") {
                    library.revealLibrary()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.accent)
            }
            .padding(12)
        }
        .background(Theme.background)
    }

    private var visibleFolders: [String] {
        library.folderNames.filter { folder in
            filteredSets.contains(where: { $0.folder == folder })
        }
    }

    @ViewBuilder
    private func setRows(_ sets: [DJSet]) -> some View {
        ForEach(sets) { set in
            MacSetRow(
                set: set,
                coverURL: library.coverPhotoURL(for: set))
                .tag(set.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = set.id
                }
                .listRowBackground(
                    selection == set.id ? Theme.accent.opacity(0.16) : Theme.panel)
                .contextMenu {
                    Button("Rename…") {
                        renameText = set.title
                        renameTarget = set
                    }
                    if !library.folderNames.isEmpty {
                        Menu("Move to Folder") {
                            ForEach(library.folderNames, id: \.self) { folder in
                                Button(folder) {
                                    library.setFolder(set.id, folder: folder)
                                }
                            }
                            if set.folder != nil {
                                Divider()
                                Button("Remove from Folder") {
                                    library.setFolder(set.id, folder: nil)
                                }
                            }
                        }
                    }
                    Button("Reveal Audio File") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            library.audioURL(for: set)
                        ])
                    }
                    Divider()
                    Button("Delete Set…", role: .destructive) {
                        deleteTarget = set
                    }
                }
        }
    }

    private var emptyDetail: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 68, weight: .thin))
                        .foregroundStyle(Theme.accent)
                    Text("Set Player")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("Choose a set to play it, or open one of your extensions.")
                        .font(.title3)
                        .foregroundStyle(Theme.textDim)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("EXTENSIONS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Theme.textDim)

                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: 5),
                        spacing: 12
                        ) {
                        homeExtensionButton(
                            "Rave Lyrics",
                            subtitle: "Beat & phrase visuals",
                            systemName: "sparkles.rectangle.stack.fill",
                            color: themes.selectedTheme.warm
                        ) {
                            openWindow(id: "rave-lyrics")
                        }
                        homeExtensionButton(
                            "Live Lyrics",
                            subtitle: "Synced to Rekordbox",
                            systemName: "quote.bubble.fill"
                        ) {
                            openWindow(id: "live-lyrics")
                        }
                        homeExtensionButton(
                            "Rekordbox History",
                            subtitle: "Sets, tracks & stats",
                            systemName: "clock.arrow.circlepath"
                        ) {
                            showRekordboxHistory = true
                        }
                        homeExtensionButton(
                            "Open Rekordbox",
                            subtitle: "Launch the DJ app",
                            systemName: "music.note.house.fill",
                            action: openRekordbox)
                        homeExtensionButton(
                            recorder.isRecording ? "Recording Set" : "Record Set",
                            subtitle: "Capture app audio",
                            systemName: recorder.isRecording
                                ? "record.circle.fill"
                                : "record.circle",
                            color: recorder.isRecording ? .red : Theme.accent
                        ) {
                            showRecorder = true
                        }
                        homeExtensionButton(
                            "Volume Mixer",
                            subtitle: "Control app levels",
                            systemName: "slider.horizontal.3",
                            color: themes.selectedTheme.warm
                        ) {
                            showVolumeMixer = true
                        }
                        homeExtensionButton(
                            "Sync iPhone",
                            subtitle: library.isSyncing ? "Syncing now…" : "Update your library",
                            systemName: "iphone.gen3.radiowaves.left.and.right"
                        ) {
                            Task { await library.syncNow() }
                        }
                        homeExtensionButton(
                            "Import Audio",
                            subtitle: "Add files to Sets",
                            systemName: "plus"
                        ) {
                            showImporter = true
                        }
                        homeExtensionButton(
                            "Settings",
                            subtitle: "Themes & preferences",
                            systemName: "gearshape.fill"
                        ) {
                            showSettings = true
                        }
                    }
                }
                .frame(maxWidth: 920)
            }
            .frame(maxWidth: .infinity, minHeight: 680)
            .padding(.horizontal, 42)
            .padding(.vertical, 54)
        }
    }

    private func homeExtensionButton(
        _ title: String,
        subtitle: String,
        systemName: String,
        color: Color = Theme.accent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(16)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(Theme.panelBorder))
        }
        .buttonStyle(.plain)
    }
}

private struct DesktopToolbarPlayer: View {
    @ObservedObject private var player = MacPlayer.shared
    @ObservedObject private var themes = MacThemeStore.shared

    var body: some View {
        HStack(spacing: 7) {
            Text(player.current?.title ?? "No Set")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(minWidth: 66, idealWidth: 90, maxWidth: 118, alignment: .leading)
                .layoutPriority(1)

            Text(formatTime(player.displayTime))
                .frame(width: 42, alignment: .trailing)

            Button {
                player.skip(-15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(themes.selectedTheme.accent)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasSet || player.isLoading)
            .help("Go back 15 seconds")
            .immediateHint("Go back 15 seconds")

            Button {
                player.toggle()
            } label: {
                ZStack {
                    Circle().fill(themes.selectedTheme.accent)
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: player.isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!hasSet || player.isLoading)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause set" : "Play set")
            .immediateHint(player.isPlaying ? "Pause set" : "Play set")

            Button {
                player.skip(15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(themes.selectedTheme.accent)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasSet || player.isLoading)
            .help("Go forward 15 seconds")
            .immediateHint("Go forward 15 seconds")

            Text("-\(formatTime(max(0, player.duration - player.displayTime)))")
                .frame(width: 50, alignment: .leading)

            Image(systemName: "speaker.fill")
                .foregroundStyle(themes.selectedTheme.accent)
                .help("Playback volume")
                .immediateHint("Playback volume")
            Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { player.volume = Float($0) }),
                in: 0...1)
                .frame(width: 88)
                .tint(themes.selectedTheme.accent)
                .help("Set playback volume")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.76))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.12)))
        .frame(minWidth: 320, idealWidth: 390, maxWidth: 460)
    }

    private var hasSet: Bool {
        player.current != nil
    }
}

private struct MacImmediateHint: ViewModifier {
    let text: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHovering = hovering
                }
            }
            .overlay(alignment: .bottom) {
                if isHovering {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.white.opacity(0.16)))
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                        .offset(y: 31)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(500)
                }
            }
            .zIndex(isHovering ? 500 : 0)
    }
}

private extension View {
    func immediateHint(_ text: String) -> some View {
        modifier(MacImmediateHint(text: text))
    }
}

private struct MacLaunchLoadingView: View {
    @ObservedObject private var themes = MacThemeStore.shared
    @State private var isSpinning = false
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Theme.panelBorder, lineWidth: 2)
                    .frame(width: 38, height: 38)

                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Theme.accent.opacity(0.08),
                                Theme.accent,
                                Theme.warm
                            ],
                            center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))

                Image(systemName: "waveform.path")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .scaleEffect(isPulsing ? 1.06 : 0.92)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Loading Sets")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Preparing content in the background…")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.panelBorder))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .onAppear {
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading sets")
    }
}

private struct MacToolbarWaveform: View {
    @ObservedObject private var player = MacPlayer.shared
    @ObservedObject private var themes = MacThemeStore.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let setID = player.current?.id {
                    MacStaticWaveformBars(setID: setID, opacity: 0.72)
                } else {
                    Capsule().fill(Theme.panelBorder)
                }

                Rectangle()
                    .fill(Theme.playhead)
                    .frame(width: 2)
                    .offset(x: playheadX(in: geometry.size.width))
            }
            .background(Theme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard player.duration > 0 else { return }
                        let fraction = max(0, min(1, value.location.x / geometry.size.width))
                        player.seek(to: Double(fraction) * player.duration)
                    })
        }
    }

    private func playheadX(in width: CGFloat) -> CGFloat {
        guard player.duration > 0 else { return 0 }
        return max(0, min(width - 2, CGFloat(player.displayTime / player.duration) * width))
    }
}

private struct MacStaticWaveformBars: View {
    @ObservedObject private var store = MacWaveformStore.shared
    @ObservedObject private var themes = MacThemeStore.shared

    let setID: UUID
    var opacity: Double = 1

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard let waveform = store.waveform(for: setID), waveform.count > 0 else {
                drawPlaceholder(context: context, size: size)
                return
            }

            let centerY = size.height / 2
            var bandBars = (0..<MacFrequencyPalette.bands.count).map { _ in Path() }
            var x: CGFloat = 0
            while x < size.width {
                let bin = min(
                    waveform.count - 1,
                    Int(CGFloat(waveform.count) * x / max(1, size.width)))
                let height = max(1.5, CGFloat(waveform.amps[bin]) * size.height * 0.84)
                let frequency = bin < waveform.frequency.count
                    ? waveform.frequency[bin]
                    : 0.45
                let band = MacFrequencyPalette.band(for: frequency)
                bandBars[band].move(to: CGPoint(x: x, y: centerY - height / 2))
                bandBars[band].addLine(to: CGPoint(x: x, y: centerY + height / 2))
                x += 2
            }

            for (band, path) in bandBars.enumerated() {
                let color = MacFrequencyPalette.bands[band]
                context.stroke(
                    path,
                    with: .color(Color(
                        red: Double(color.red),
                        green: Double(color.green),
                        blue: Double(color.blue))
                        .opacity(opacity)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }

    private func drawPlaceholder(context: GraphicsContext, size: CGSize) {
        let centerY = size.height / 2
        var bars = Path()
        var x: CGFloat = 1
        while x < size.width {
            let height = size.height * (0.18 + abs(sin(x * 0.04)) * 0.38)
            bars.move(to: CGPoint(x: x, y: centerY - height / 2))
            bars.addLine(to: CGPoint(x: x, y: centerY + height / 2))
            x += 3
        }
        context.stroke(
            bars,
            with: .color(Theme.accent.opacity(0.22)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }
}

private struct MacPlaybackErrorPresenter: View {
    @ObservedObject private var player = MacPlayer.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Playback error", isPresented: .init(
                get: { player.loadError != nil },
                set: { if !$0 { player.loadError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(player.loadError ?? "")
            }
    }
}

private struct MacSyncHeader: View {
    @EnvironmentObject private var library: MacLibrary
    @ObservedObject private var themes = MacThemeStore.shared

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.accent.opacity(0.15))
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(library.phoneName != nil ? Color.green : Theme.textDim)
                        .frame(width: 7, height: 7)
                    Text(library.phoneName ?? "iPhone Sync")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                Text(library.syncMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
            }

            Spacer()

            if library.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await library.syncNow() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
    }
}

private final class MacLocalImageCache: @unchecked Sendable {
    static let shared = MacLocalImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 48
        cache.totalCostLimit = 220 * 1_024 * 1_024
    }

    func cachedImage(for url: URL, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: cacheKey(url: url, maxPixelSize: maxPixelSize))
    }

    func loadImage(for url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = cacheKey(url: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        return await Task.detached(priority: .utility) {
            if let cached = self.cache.object(forKey: key) {
                return cached
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil
            }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height))
            self.cache.setObject(
                image,
                forKey: key,
                cost: cgImage.width * cgImage.height * 4)
            return image
        }.value
    }

    func prefetch(_ urls: [URL], maxPixelSize: Int) {
        for url in urls {
            Task {
                _ = await loadImage(for: url, maxPixelSize: maxPixelSize)
            }
        }
    }

    private func cacheKey(url: URL, maxPixelSize: Int) -> NSString {
        "\(url.path)#\(maxPixelSize)" as NSString
    }
}

private struct MacAsyncLocalImage: View {
    let url: URL
    let maxPixelSize: Int
    let contentMode: ContentMode
    var showsProgress = true

    @State private var image: NSImage?
    @State private var loadedKey = ""

    private var key: String {
        "\(url.path)#\(maxPixelSize)"
    }

    var body: some View {
        ZStack {
            if loadedKey == key, let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.black.opacity(0.18)
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task(id: key) {
            if let cached = MacLocalImageCache.shared.cachedImage(
                for: url,
                maxPixelSize: maxPixelSize
            ) {
                image = cached
                loadedKey = key
                return
            }
            let loaded = await MacLocalImageCache.shared.loadImage(
                for: url,
                maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedKey = key
        }
    }
}

private struct MacSetRow: View {
    @ObservedObject private var player = MacPlayer.shared
    @ObservedObject private var themes = MacThemeStore.shared

    let set: DJSet
    let coverURL: URL?

    private var isPlaying: Bool {
        player.current?.id == set.id && player.isPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                LinearGradient(
                    colors: [Theme.accent.opacity(0.24), Theme.background],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                Image(systemName: isPlaying ? "waveform" : "music.note")
                    .foregroundStyle(isPlaying ? Theme.accent : Theme.textDim)

                if let coverURL {
                    MacAsyncLocalImage(
                        url: coverURL,
                        maxPixelSize: 128,
                        contentMode: .fill,
                        showsProgress: false)
                }
            }
            .frame(width: 46, height: 46)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(set.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(formatTime(set.duration))
                    if !set.photos.isEmpty {
                        Label("\(set.photos.count)", systemImage: "photo")
                    }
                    if !set.videos.isEmpty {
                        Label("\(set.videos.count)", systemImage: "video")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                if let location = set.locationName {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

private struct MacPlayerDetail: View {
    @EnvironmentObject private var library: MacLibrary
    @ObservedObject private var waveforms = MacWaveformStore.shared
    @ObservedObject private var player = MacPlayer.shared
    @ObservedObject private var recorder = MacSetRecorder.shared
    @ObservedObject private var themes = MacThemeStore.shared

    let set: DJSet
    @Binding var showTracksSidebar: Bool
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let onSync: () -> Void
    let onShowRekordboxHistory: () -> Void
    let onOpenRekordbox: () -> Void
    let onShowRecorder: () -> Void
    let onShowVolumeMixer: () -> Void
    let onShowLiveLyrics: () -> Void
    let onShowSettings: () -> Void
    let onShowImporter: () -> Void
    @State private var showPhotoImporter = false
    @State private var showVideoImporter = false
    @State private var showMediaImporter = false
    @State private var showLocationPicker = false
    @State private var showRekordboxMatcher = false
    @State private var selectedMediaID: UUID?
    @State private var isMediaExpanded = true
    @State private var showWaveformContent = false
    @State private var showMediaContent = false
    @State private var showLocationContent = false
    @State private var isMediaFullScreen = false
    @State private var previousColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var descriptionDraft = ""
    @State private var descriptionSaveTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width - 48, 520)
            let mediaHeight = min(max(geometry.size.width * 0.64, 640), 840)
            let mapHeight = min(max(contentWidth * 0.44, 420), 620)

            ZStack {
                if isMediaFullScreen {
                    fullScreenMediaView
                        .transition(.opacity)
                } else {
                    ScrollViewReader { proxy in
                        ZStack {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    Color.clear
                                        .frame(height: 0)
                                        .id("dashboard-top")

                                    performanceBanner(height: mediaHeight)

                                    Divider()
                                        .overlay(Theme.panelBorder)
                                        .padding(.horizontal, 24)

                                    supportingSection(width: contentWidth, height: mapHeight)
                                        .padding(.horizontal, 24)
                                        .id("map-and-tracks")

                                    setActionsFooter
                                        .padding(.horizontal, 24)
                                }
                                .padding(.top, 0)
                                .padding(.bottom, 32)
                            }
                            .onAppear {
                                DispatchQueue.main.async {
                                    proxy.scrollTo("dashboard-top", anchor: .top)
                                }
                            }

                            heroControlBar {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo("map-and-tracks", anchor: .top)
                                }
                            }
                                .padding(.horizontal, 18)
                                .padding(.top, 18)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .zIndex(10)
                        }
                    }
                }
            }
        }
        .background(Theme.background)
        .tint(themes.selectedTheme.accent)
        .task(id: set.id) {
            descriptionDraft = set.description ?? ""
            showWaveformContent = false
            showMediaContent = false
            showLocationContent = false
            selectedMediaID = mediaIDs.first
            await Task.yield()
            guard !Task.isCancelled else { return }

            MacPlayer.shared.load(
                set,
                from: library.audioURL(for: set),
                autoplay: false)
            waveforms.request(
                for: set,
                audioURL: library.audioURL(for: set),
                waveformsDir: library.waveformsURL)

            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled else { return }
            showWaveformContent = true

            try? await Task.sleep(for: .milliseconds(85))
            guard !Task.isCancelled else { return }
            showMediaContent = true
            prefetchPhotos(around: selectedMediaID)

            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            showLocationContent = true
        }
        .fileImporter(
            isPresented: $showPhotoImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                library.importPhotos(urls, to: set.id)
            }
        }
        .fileImporter(
            isPresented: $showVideoImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                library.importVideos(urls, to: set.id)
            }
        }
        .fileImporter(
            isPresented: $showMediaImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                let photos = urls.filter {
                    UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
                }
                let videos = urls.filter {
                    UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true
                }
                if !photos.isEmpty {
                    library.importPhotos(photos, to: set.id)
                }
                if !videos.isEmpty {
                    library.importVideos(videos, to: set.id)
                }
            }
        }
        .sheet(isPresented: $showLocationPicker) {
            MacSetLocationPicker(
                name: set.locationName,
                latitude: set.locationLatitude,
                longitude: set.locationLongitude
            ) { name, latitude, longitude in
                library.setLocation(
                    name,
                    latitude: latitude,
                    longitude: longitude,
                    for: set.id)
            }
        }
        .sheet(isPresented: $showRekordboxMatcher) {
            MacRekordboxSetMatcherSheet(set: set)
                .environmentObject(library)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            guard isMediaFullScreen else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isMediaFullScreen = false
                columnVisibility = previousColumnVisibility
            }
        }
    }

    private var performanceHeader: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(player.isPlaying && player.current?.id == set.id
                                ? themes.selectedTheme.accent
                                : Theme.textDim)
                            .frame(width: 7, height: 7)
                            .shadow(
                                color: themes.selectedTheme.accent.opacity(
                                    player.isPlaying ? 0.8 : 0),
                                radius: 5)
                        Text(player.isPlaying && player.current?.id == set.id
                            ? "NOW PLAYING"
                            : "SET READY")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .kerning(1.5)
                            .foregroundStyle(player.isPlaying
                                ? themes.selectedTheme.accent
                                : Theme.textDim)
                    }

                    Text(set.title)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    HStack(spacing: 12) {
                        if let location = set.locationName {
                            Label(location, systemImage: "mappin.and.ellipse")
                        }
                        Label("\(set.annotations.count) tracks", systemImage: "music.note.list")
                        Label("\(mediaIDs.count) landscape moments", systemImage: "rectangle.landscape.rotate")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textDim)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatTime(player.displayTime))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                    Text("-\(formatTime(max(0, player.duration - player.displayTime)))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }

                Button {
                    if player.current?.id == set.id {
                        player.toggle()
                    } else {
                        player.load(
                            set,
                            from: library.audioURL(for: set),
                            autoplay: true)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(themes.selectedTheme.accent)
                            .shadow(
                                color: themes.selectedTheme.accent.opacity(0.36),
                                radius: 15)
                        if player.isLoading && player.current?.id == set.id {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: player.isPlaying && player.current?.id == set.id
                                ? "pause.fill"
                                : "play.fill")
                                .font(.system(size: 21, weight: .black))
                                .foregroundStyle(.white)
                                .offset(x: player.isPlaying ? 0 : 1)
                        }
                    }
                    .frame(width: 58, height: 58)
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "Pause set" : "Play set")
            }

            headerWaveform
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 11))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Theme.panelBorder))

            HStack(spacing: 10) {
                Button {
                    showRekordboxMatcher = true
                } label: {
                    Label("Match Tracks", systemImage: "link.badge.plus")
                }
                .help("Match this recording to Rekordbox history")

                Button {
                    showTracksSidebar.toggle()
                } label: {
                    Label("Tracks", systemImage: "music.note.list")
                }

                Menu {
                    Button {
                        showPhotoImporter = true
                    } label: {
                        Label("Add Landscape Photos", systemImage: "photo.badge.plus")
                    }
                    Button {
                        showVideoImporter = true
                    } label: {
                        Label("Add Muted Videos", systemImage: "video.badge.plus")
                    }
                } label: {
                    Label("Add Moments", systemImage: "plus")
                }

                Spacer()

                Button {
                    showLocationPicker = true
                } label: {
                    Label("Edit Location", systemImage: "mappin.and.ellipse")
                }
            }
            .buttonStyle(.bordered)
            .tint(themes.selectedTheme.accent)
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [
                    Theme.panel,
                    themes.selectedTheme.accent.opacity(0.1),
                    Theme.panel
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.panelBorder))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                setArtwork

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(URL(fileURLWithPath: set.fileName).pathExtension.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(themes.selectedTheme.accent)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(themes.selectedTheme.accent.opacity(0.14), in: Capsule())

                        if let folder = set.folder {
                            Label(folder, systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                        }
                    }

                    Text(set.title)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .lineLimit(2)

                    Text(set.fileName)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)

                    Button {
                        showLocationPicker = true
                    } label: {
                        Label(
                            set.locationName ?? "Add a location",
                            systemImage: "mappin.and.ellipse")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        set.locationName == nil ? Theme.textDim : themes.selectedTheme.accent)

                    HStack(spacing: 8) {
                        Button {
                            showTracksSidebar.toggle()
                        } label: {
                            Label("\(set.annotations.count) Tracks", systemImage: "music.note.list")
                        }
                        .help(showTracksSidebar ? "Hide tracks" : "Show tracks")

                        Button {
                            setMediaExpanded(!isMediaExpanded)
                        } label: {
                            Label(
                                "\(set.photos.count + set.videos.count) Moments",
                                systemImage: "photo.on.rectangle.angled")
                        }
                        .help(isMediaExpanded ? "Collapse moments" : "Expand moments")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themes.selectedTheme.accent)
                }
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 360, alignment: .leading)

                Divider()
                    .overlay(Theme.panelBorder)
                    .frame(height: 88)

                headerWaveform
                    .frame(minWidth: 170, maxWidth: .infinity)
                    .frame(height: 88)

                Button {
                    if player.current?.id == set.id {
                        player.toggle()
                    } else {
                        player.load(
                            set,
                            from: library.audioURL(for: set),
                            autoplay: true)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(themes.selectedTheme.accent)
                            .shadow(color: themes.selectedTheme.accent.opacity(0.32), radius: 12)
                        if player.isLoading && player.current?.id == set.id {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: player.isPlaying && player.current?.id == set.id
                                  ? "pause.fill"
                                  : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: player.isPlaying && player.current?.id == set.id ? 0 : 1)
                        }
                    }
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(.plain)
                .help(player.isPlaying && player.current?.id == set.id ? "Pause set" : "Play set")
            }

            HStack(spacing: 10) {
                Button {
                    showRekordboxMatcher = true
                } label: {
                    Label("Match Tracks", systemImage: "link.badge.plus")
                }
                .buttonStyle(.bordered)
                .help("Match this recording to Rekordbox history")

                Menu {
                    Button {
                        showPhotoImporter = true
                    } label: {
                        Label("Add Photos", systemImage: "camera.fill")
                    }
                    Button {
                        showVideoImporter = true
                    } label: {
                        Label("Add Muted Videos", systemImage: "video.fill")
                    }
                    Button {
                        showLocationPicker = true
                    } label: {
                        Label("Edit Location", systemImage: "mappin.and.ellipse")
                    }
                } label: {
                    Label("Add Media", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    showLocationPicker = true
                } label: {
                    Label("Edit Location", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .tint(themes.selectedTheme.accent)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Theme.panel, Theme.accent.opacity(0.075)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.panelBorder))
    }

    private var setArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.accent.opacity(0.3), Theme.warm.opacity(0.14), Theme.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            Image(systemName: "waveform.path")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.8))

            if let cover = set.photos.first {
                MacAsyncLocalImage(
                    url: library.photoURL(for: cover),
                    maxPixelSize: 360,
                    contentMode: .fill,
                    showsProgress: false)
            }
        }
        .frame(width: 118, height: 118)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.panelBorder))
    }

    @ViewBuilder
    private var headerWaveform: some View {
        if showWaveformContent,
           waveforms.waveform(for: set.id) != nil {
            MacOverviewWaveform(set: set)
        } else {
            MacWaveformLoadingView(compact: true)
        }
    }

    private func performanceBanner(height: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 11) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(set.title)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)

                        HStack(spacing: 12) {
                            if let location = set.locationName {
                                Label(location, systemImage: "mappin.and.ellipse")
                            }
                            Label("\(set.annotations.count) tracks", systemImage: "music.note.list")
                            Label(
                                set.addedAt.formatted(
                                    .dateTime.month(.wide).day().year()),
                                systemImage: "calendar")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.76))

                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(themes.selectedTheme.accent)
                            TextField(
                                "Add a description…",
                                text: $descriptionDraft,
                                axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...3)
                                .onChange(of: descriptionDraft) { _, newValue in
                                    descriptionSaveTask?.cancel()
                                    descriptionSaveTask = Task {
                                        try? await Task.sleep(for: .milliseconds(450))
                                        guard !Task.isCancelled else { return }
                                        library.setDescription(newValue, for: set.id)
                                    }
                                }
                                .help("Click to edit the set description")
                        }
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: 620, alignment: .leading)
                    }

                    Spacer(minLength: 14)
                }

                Spacer(minLength: 0)

                trackDeckOverlay
            }
            .padding(.top, 162)
            .padding(.bottom, 76)

            liveWaveformOverlay
                .padding(.horizontal, 18)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            ZStack {
                Theme.background

                performanceMediaCanvas

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.84), location: 0),
                        .init(color: .black.opacity(0.28), location: 0.44),
                        .init(color: .black.opacity(0.12), location: 0.62),
                        .init(color: .black.opacity(0.9), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Theme.background.opacity(0.34), location: 0.3),
                            .init(color: Theme.background.opacity(0.9), location: 0.68),
                            .init(color: Theme.background, location: 0.9),
                            .init(color: Theme.background, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom)
                        .frame(height: 82)
                }
                .allowsHitTesting(false)
            }
        }
        .clipped()
        .task(id: selectedMediaID) {
            guard mediaIDs.count > 1 else { return }
            do {
                try await Task.sleep(for: .seconds(selectedVideo == nil ? 7 : 9))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) {
                advanceMedia(by: 1)
            }
        }
    }

    private func heroControlBar(onShowMapAndTracks: @escaping () -> Void) -> some View {
        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 3) {
                heroActionButton(
                    systemName: "sidebar.left",
                    help: columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar",
                    color: themes.selectedTheme.accent
                ) {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }

                Button(action: onSync) {
                    if library.isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(themes.selectedTheme.accent)
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .frame(width: 30, height: 30)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(themes.selectedTheme.accent)
                .disabled(library.isSyncing)
                .help("Sync iPhone")
                .immediateHint("Sync iPhone")

                heroActionButton(
                    systemName: "clock.arrow.circlepath",
                    help: "Rekordbox played track history",
                    color: themes.selectedTheme.accent,
                    action: onShowRekordboxHistory)

                Button(action: onOpenRekordbox) {
                    Image("RekordboxLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(themes.selectedTheme.accent)
                .help("Open Rekordbox")
                .immediateHint("Open Rekordbox")

                heroActionButton(
                    systemName: recorder.isRecording ? "record.circle.fill" : "record.circle",
                    help: recorder.isRecording ? "Recording a set" : "Record a set",
                    color: recorder.isRecording ? .red : themes.selectedTheme.accent,
                    action: onShowRecorder)

                heroActionButton(
                    systemName: "slider.horizontal.3",
                    help: "Volume mixer",
                    color: themes.selectedTheme.warm,
                    action: onShowVolumeMixer)

                heroActionButton(
                    systemName: "quote.bubble.fill",
                    help: "Live Rekordbox lyrics",
                    color: themes.selectedTheme.accent,
                    action: onShowLiveLyrics)

                heroActionButton(
                    systemName: "gearshape",
                    help: "Settings",
                    color: themes.selectedTheme.accent,
                    action: onShowSettings)

                heroActionButton(
                    systemName: "plus",
                    help: "Import audio",
                    color: themes.selectedTheme.accent,
                    action: onShowImporter)

                heroActionButton(
                    systemName: "arrow.down.to.line.compact",
                    help: "Jump to map and tracks",
                    color: themes.selectedTheme.accent,
                    action: onShowMapAndTracks)

                heroActionButton(
                    systemName: isMediaFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    help: isMediaFullScreen
                        ? "Exit media full screen"
                        : "Show media full screen",
                    color: themes.selectedTheme.accent
                ) {
                    if isMediaFullScreen {
                        exitMediaFullScreen()
                    } else {
                        enterMediaFullScreen()
                    }
                }
                }
                .padding(4)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.12)))

                Spacer(minLength: 0)
            }

            DesktopToolbarPlayer()
        }
        .frame(maxWidth: .infinity)
    }

    private var fullScreenMediaView: some View {
        ZStack {
            Color.black

            performanceMediaCanvas

            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.78), location: 0.1),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.72),
                    .init(color: .black.opacity(0.8), location: 0.9),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom)
                .allowsHitTesting(false)

            liveWaveformOverlay
                .padding(.horizontal, 34)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()

                    Button {
                        if player.current?.id == set.id {
                            player.toggle()
                        } else {
                            player.load(
                                set,
                                from: library.audioURL(for: set),
                                autoplay: true)
                        }
                    } label: {
                        Image(systemName: player.isPlaying && player.current?.id == set.id
                            ? "pause.fill"
                            : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(themes.selectedTheme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .help(player.isPlaying ? "Pause set" : "Play set")

                    Button {
                        exitMediaFullScreen()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.64), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Exit media full screen")
                }
                    .padding(.horizontal, 22)
                    .padding(.top, 60)
                Spacer()
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            exitMediaFullScreen()
        }
        .task(id: selectedMediaID) {
            guard mediaIDs.count > 1 else { return }
            do {
                try await Task.sleep(for: .seconds(selectedVideo == nil ? 7 : 9))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) {
                advanceMedia(by: 1)
            }
        }
    }

    private func enterMediaFullScreen() {
        guard !isMediaFullScreen else { return }
        previousColumnVisibility = columnVisibility
        withAnimation(.easeInOut(duration: 0.25)) {
            columnVisibility = .detailOnly
            isMediaFullScreen = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard let window = NSApplication.shared.keyWindow,
                  !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    private func exitMediaFullScreen() {
        guard isMediaFullScreen else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            isMediaFullScreen = false
            columnVisibility = previousColumnVisibility
        }
        if let window = NSApplication.shared.keyWindow,
           window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    private func heroActionButton(
        systemName: String,
        help: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .immediateHint(help)
    }

    @ViewBuilder
    private var performanceMediaCanvas: some View {
        if !showMediaContent {
            ZStack {
                Theme.panel
                ProgressView()
                    .controlSize(.small)
            }
        } else if mediaIDs.isEmpty {
            ZStack {
                LinearGradient(
                    colors: [Theme.accent.opacity(0.25), Theme.background, Theme.warm.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.landscape.rotate")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(themes.selectedTheme.accent)
                    Text("Add photos & videos")
                        .font(.title2.weight(.bold))
                    Text(set.photos.isEmpty
                        ? "Landscape photos and muted videos become the cinematic backdrop for your set."
                        : "Portrait photos are hidden in this performance view.")
                        .font(.callout)
                        .foregroundStyle(Theme.textDim)
                    Button {
                        showMediaImporter = true
                    } label: {
                        Label("Choose Photos & Videos", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themes.selectedTheme.accent)
                }
            }
        } else {
            selectedMedia
                .id(selectedMediaID)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.8), value: selectedMediaID)
        }
    }

    private var liveWaveformOverlay: some View {
        ZStack(alignment: .top) {
            if showWaveformContent,
               let waveform = waveforms.waveform(for: set.id) {
                MacScrollingWaveform(
                    set: set,
                    waveform: waveform,
                    theme: themes.selectedTheme)
                    .frame(height: 118)
                    .opacity(0.68)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white, location: 0.1),
                                .init(color: .white, location: 0.9),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing)
                    }
            } else {
                HStack(spacing: 9) {
                    if waveforms.loading.contains(set.id) || !showWaveformContent {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Loading waveform…")
                    } else {
                        Image(systemName: "waveform.slash")
                        Text("Waveform unavailable")
                        Button("Retry") {
                            waveforms.request(
                                for: set,
                                audioURL: library.audioURL(for: set),
                                waveformsDir: library.waveformsURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
                .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
                .frame(maxWidth: .infinity)
                .frame(height: 118)
            }

            HStack {
                Spacer()
                Text("-\(formatTime(max(0, player.duration - player.displayTime)))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 4)
            .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
        }
        .foregroundStyle(.white)
        .frame(height: 118)
    }

    @ViewBuilder
    private var trackDeckOverlay: some View {
        if let currentTrackName {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Playing")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(themes.selectedTheme.accent)
                    Text(currentTrackName)
                        .font(.callout.weight(.bold))
                        .lineLimit(1)
                }

                if let nextTrackName {
                    VStack(alignment: .leading, spacing: 3) {
                    Text("Next")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .kerning(1.2)
                            .foregroundStyle(.white.opacity(0.58))
                        Text(nextTrackName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }

                Spacer()
            }
            .shadow(color: .black.opacity(0.95), radius: 4, y: 2)
        }
    }

    private var nextMomentPeek: some View {
        Button {
            advanceMedia(by: 1)
        } label: {
            ZStack {
                nextMomentPreview

                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom)

                VStack(spacing: 7) {
                    Spacer()
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 27, weight: .bold))
                    Text("NEXT")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .kerning(1)
                }
                .foregroundStyle(.white)
                .padding(.bottom, 13)
            }
            .frame(width: 126, height: 186)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .stroke(themes.selectedTheme.accent, lineWidth: 2))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 7)
        }
        .buttonStyle(.plain)
        .help("Show the next landscape moment")
    }

    @ViewBuilder
    private var nextMomentPreview: some View {
        if let nextPhoto {
            MacAsyncLocalImage(
                url: library.photoURL(for: nextPhoto),
                maxPixelSize: 420,
                contentMode: .fill,
                showsProgress: false)
        } else if nextVideo != nil {
            ZStack {
                Color.black
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8))
            }
        } else {
            Theme.panel
        }
    }

    @ViewBuilder
    private func locationSection(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(themes.selectedTheme.accent)
                Text("LOCATION")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.3)
                Spacer()
                Button {
                    showLocationPicker = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(themes.selectedTheme.accent)
            }

            Divider().overlay(Theme.panelBorder)

            if !showLocationContent {
                ZStack {
                    Theme.background.opacity(0.55)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading satellite map…")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if let latitude = set.locationLatitude,
               let longitude = set.locationLongitude {
                MacSetLocationPreview(
                    name: set.locationName ?? "Set location",
                    latitude: latitude,
                    longitude: longitude)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            } else {
                Button {
                    showLocationPicker = true
                } label: {
                    VStack(spacing: 9) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(themes.selectedTheme.accent)
                        Text("Place a pin")
                            .font(.headline)
                        Text("Add a 3D satellite location for this set.")
                            .font(.caption)
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.14), Theme.background],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func supportingSection(width: CGFloat, height: CGFloat) -> some View {
        let trackWidth = min(max(width * 0.42, 360), 540)

        return HStack(alignment: .top, spacing: 18) {
            locationSection(height: height)
                .frame(maxWidth: .infinity)

            ScrollView {
                MacTracksWidget(set: set)
            }
            .frame(width: trackWidth)
            .frame(height: height + 42)
        }
    }

    private var setActionsFooter: some View {
        HStack(spacing: 10) {
            Button {
                showRekordboxMatcher = true
            } label: {
                Label("Match Tracks", systemImage: "link.badge.plus")
            }
            .help("Match this recording to Rekordbox history")

            Button {
                showMediaImporter = true
            } label: {
                Label("Add Photos & Videos", systemImage: "photo.on.rectangle.angled")
            }

            Button {
                showLocationPicker = true
            } label: {
                Label("Edit Location", systemImage: "mappin.and.ellipse")
            }

            Spacer()
        }
        .buttonStyle(.bordered)
        .tint(themes.selectedTheme.accent)
        .padding(.bottom, 4)
    }

    private func momentsSection(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(themes.selectedTheme.accent)
                Text("MOMENTS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.3)
                Text("\(set.photos.count + set.videos.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(themes.selectedTheme.accent)
                Spacer()
                Button {
                    setMediaExpanded(!isMediaExpanded)
                } label: {
                    Label(
                        isMediaExpanded ? "Close" : "Open",
                        systemImage: isMediaExpanded
                            ? "rectangle.compress.vertical"
                            : "rectangle.expand.vertical")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(themes.selectedTheme.accent)
            }

            Divider().overlay(Theme.panelBorder)

            if isMediaExpanded {
                if showMediaContent {
                    mediaActivity(height: height)
                } else {
                    ZStack {
                        Theme.background.opacity(0.55)
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Loading moments…")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            } else {
                Button {
                    setMediaExpanded(true)
                } label: {
                    ZStack {
                        if let cover = set.photos.first {
                            MacAsyncLocalImage(
                                url: library.photoURL(for: cover),
                                maxPixelSize: 900,
                                contentMode: .fill)
                        } else {
                            LinearGradient(
                                colors: [Theme.warm.opacity(0.2), Theme.background],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing)
                        }

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.72)],
                            startPoint: .center,
                            endPoint: .bottom)

                        VStack {
                            Spacer()
                            HStack {
                                Label(
                                    "Open \(set.photos.count) photos · \(set.videos.count) videos",
                                    systemImage: "play.rectangle.on.rectangle")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .foregroundStyle(.white)
                            .padding(12)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: min(height, 360))
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("Open Moments")
            }
        }
    }

    @ViewBuilder
    private func mediaActivity(height: CGFloat) -> some View {
        if set.photos.isEmpty && set.videos.isEmpty {
            ZStack {
                LinearGradient(
                    colors: [
                        Theme.accent.opacity(0.28),
                        Theme.background,
                        Theme.warm.opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                    Text("Add moments from this set")
                        .font(.title3.weight(.semibold))
                    Text("Photos and muted videos sync with your iPhone.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.62))
                    HStack(spacing: 10) {
                        Button {
                            showPhotoImporter = true
                        } label: {
                            Label("Photos", systemImage: "camera.fill")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            showVideoImporter = true
                        } label: {
                            Label("Muted Videos", systemImage: "video.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(height: min(height, 520))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.panelBorder))
        } else {
            VStack(spacing: 10) {
                HStack {
                    Text("MEDIA")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .kerning(1.3)
                    Text("\(mediaIDs.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button {
                        advanceMedia(by: -1)
                    } label: {
                        Text("<")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .help("Previous image or video")
                    Button {
                        advanceMedia(by: 1)
                    } label: {
                        Text(">")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .help("Next image or video")
                }

                selectedMedia
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.panelBorder))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        Menu {
                            Button("Add Photos") {
                                showPhotoImporter = true
                            }
                            Button("Add Muted Videos") {
                                showVideoImporter = true
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.title2)
                                Text("Add")
                                    .font(.caption)
                            }
                            .frame(width: 92, height: 72)
                            .background(Theme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.panelBorder))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        ForEach(set.photos) { photo in
                            Button {
                                selectMedia(photo.id)
                            } label: {
                                MacAsyncLocalImage(
                                    url: library.photoURL(for: photo),
                                    maxPixelSize: 240,
                                    contentMode: .fill,
                                    showsProgress: false)
                                    .frame(width: 112, height: 72)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10).stroke(
                                            selectedMediaID == photo.id
                                                ? Theme.accent
                                                : Theme.panelBorder,
                                            lineWidth: selectedMediaID == photo.id ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    library.deletePhoto(photo.id, from: set.id)
                                    selectedMediaID = nil
                                } label: {
                                    Label("Remove Photo", systemImage: "trash")
                                }
                            }
                        }

                        ForEach(set.videos) { video in
                            Button {
                                selectMedia(video.id)
                            } label: {
                                ZStack {
                                    Rectangle().fill(Color.black)
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                    Label("Muted", systemImage: "speaker.slash.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(4)
                                        .background(.black.opacity(0.7), in: Capsule())
                                        .frame(
                                            maxWidth: .infinity,
                                            maxHeight: .infinity,
                                            alignment: .bottomTrailing)
                                        .padding(5)
                                }
                                .frame(width: 112, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10).stroke(
                                        selectedMediaID == video.id
                                            ? Theme.accent
                                            : Theme.panelBorder,
                                        lineWidth: selectedMediaID == video.id ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    library.deleteVideo(video.id, from: set.id)
                                    selectedMediaID = nil
                                } label: {
                                    Label("Remove Video", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedMedia: some View {
        if let photo = selectedPhoto {
            Button {
                advanceMedia(by: 1)
            } label: {
                ZStack {
                    Color.black
                    MacAsyncLocalImage(
                        url: library.photoURL(for: photo),
                        maxPixelSize: 2_200,
                        contentMode: .fill)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    library.deletePhoto(photo.id, from: set.id)
                    selectedMediaID = nil
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }
        } else if let video = selectedVideo {
            MacMutedVideoPlayer(url: library.videoURL(for: video))
            .contextMenu {
                Button(role: .destructive) {
                    library.deleteVideo(video.id, from: set.id)
                    selectedMediaID = nil
                } label: {
                    Label("Remove Video", systemImage: "trash")
                }
            }
        } else {
            Color.black
                .overlay {
                    ProgressView()
                }
                .onAppear {
                    selectFirstMedia()
                }
        }
    }

    private var landscapePhotos: [SetPhoto] {
        self.set.photos.filter {
            macImageIsLandscape(at: library.photoURL(for: $0)) != false
        }
    }

    private var mediaIDs: [UUID] {
        landscapePhotos.map(\.id) + self.set.videos.map(\.id)
    }

    private var selectedPhoto: SetPhoto? {
        landscapePhotos.first(where: { $0.id == selectedMediaID })
    }

    private var selectedVideo: SetVideo? {
        self.set.videos.first(where: { $0.id == selectedMediaID })
    }

    private func advanceMedia(by offset: Int) {
        guard !mediaIDs.isEmpty else { return }
        let index = mediaIDs.firstIndex(where: { $0 == selectedMediaID }) ?? 0
        let newID = mediaIDs[
            (index + offset + mediaIDs.count) % mediaIDs.count]
        selectedMediaID = newID
        prefetchPhotos(around: newID)
    }

    private func selectMedia(_ id: UUID) {
        selectedMediaID = id
        prefetchPhotos(around: id)
    }

    private func selectFirstMedia() {
        selectedMediaID = mediaIDs.first
    }

    private func setMediaExpanded(_ expanded: Bool) {
        isMediaExpanded = expanded
    }

    private func prefetchPhotos(around id: UUID?) {
        guard !mediaIDs.isEmpty else { return }
        let index = mediaIDs.firstIndex(where: { $0 == id }) ?? 0
        let candidateIDs = [
            mediaIDs[index],
            mediaIDs[(index + 1) % mediaIDs.count],
            mediaIDs[(index - 1 + mediaIDs.count) % mediaIDs.count]
        ]
        let urls = candidateIDs.compactMap { candidateID in
            set.photos.first(where: { $0.id == candidateID })
                .map(library.photoURL(for:))
        }
        MacLocalImageCache.shared.prefetch(urls, maxPixelSize: 1_600)
    }

    private var currentMomentIndex: Int {
        mediaIDs.firstIndex(where: { $0 == selectedMediaID }) ?? 0
    }

    private var currentMomentLabel: String {
        guard !mediaIDs.isEmpty else { return "NO LANDSCAPE MOMENTS" }
        return String(
            format: "MOMENT %02d OF %02d",
            currentMomentIndex + 1,
            mediaIDs.count)
    }

    private var nextMediaID: UUID? {
        guard !mediaIDs.isEmpty else { return nil }
        return mediaIDs[(currentMomentIndex + 1) % mediaIDs.count]
    }

    private var nextPhoto: SetPhoto? {
        landscapePhotos.first(where: { $0.id == nextMediaID })
    }

    private var nextVideo: SetVideo? {
        self.set.videos.first(where: { $0.id == nextMediaID })
    }

    private var currentTrackName: String? {
        guard let currentTrackIndex else { return nil }
        return set.annotations[currentTrackIndex].label
    }

    private var nextTrackName: String? {
        guard let currentTrackIndex else { return nil }
        let nextIndex = currentTrackIndex + 1
        guard nextIndex < set.annotations.count else { return nil }
        return set.annotations[nextIndex].label
    }

    private var currentTrackIndex: Int? {
        guard player.current?.id == set.id, !set.annotations.isEmpty else { return nil }
        return set.annotations.lastIndex(where: { $0.time <= player.displayTime }) ?? 0
    }

}

private struct MacTracksWidget: View {
    @EnvironmentObject private var library: MacLibrary
    @ObservedObject private var player = MacPlayer.shared
    @ObservedObject private var rekordboxHistory = MacRekordboxHistoryStore.shared
    @ObservedObject private var themes = MacThemeStore.shared

    let set: DJSet

    var body: some View {
        let artworkByLabel = Dictionary(
            rekordboxHistory.data?.tracks.compactMap { track in
                track.artworkURL.map { (normalizedTrackLabel(track.displayLabel), $0) }
            } ?? [],
            uniquingKeysWith: { _, latest in latest })

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(set.annotations.count) TRACKS", systemImage: "music.note.list")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(1.3)
                Spacer()
                Button {
                    library.addCue(to: set.id, at: player.liveTime())
                } label: {
                    Label("Mark Track", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            if set.annotations.isEmpty {
                Text("No tracks marked yet. Add one at the current playhead.")
                    .font(.callout)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder))
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("#")
                            .frame(width: 28, alignment: .trailing)
                        Text("TRACK")
                        Spacer()
                        Text("START")
                            .frame(width: 54, alignment: .trailing)
                        Text("LENGTH")
                            .frame(width: 54, alignment: .trailing)
                        Color.clear.frame(width: 14, height: 1)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)

                    Divider().overlay(Theme.panelBorder)

                    ForEach(Array(set.annotations.enumerated()), id: \.element.id) { index, cue in
                        Button {
                            player.seek(to: cue.time)
                        } label: {
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.textDim)
                                    .frame(width: 28, alignment: .trailing)

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.cueColor(index))
                                    .frame(width: 4, height: 30)

                                MacTrackArtwork(
                                    url: cue.artworkURL
                                        ?? artworkByLabel[normalizedTrackLabel(cue.label)],
                                    title: trackLabel(cue, index: index))
                                    .frame(width: 34, height: 34)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(trackLabel(cue, index: index))
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    if isActiveTrack(index) {
                                        Text("Playing")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(Theme.accent)
                                    }
                                }

                                Spacer()

                                Text(formatTime(cue.time))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 54, alignment: .trailing)
                                    .foregroundStyle(Theme.textDim)

                                Text(formatTime(trackLength(index)))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 54, alignment: .trailing)
                                    .foregroundStyle(Theme.textDim)

                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(
                                        isActiveTrack(index) ? Theme.accent : Theme.textDim)
                                    .frame(width: 14)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                isActiveTrack(index)
                                    ? Theme.accent.opacity(0.1)
                                    : Color.clear)
                        }
                        .buttonStyle(.plain)

                        if index < set.annotations.count - 1 {
                            Divider()
                                .overlay(Theme.panelBorder)
                                .padding(.leading, 58)
                        }
                    }
                }
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder))
            }
        }
        .padding(14)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
        .task {
            await rekordboxHistory.load()
        }
    }

    private func trackLength(_ index: Int) -> TimeInterval {
        let start = set.annotations[index].time
        let end = index + 1 < set.annotations.count
            ? set.annotations[index + 1].time
            : set.duration
        return max(0, end - start)
    }

    private func isActiveTrack(_ index: Int) -> Bool {
        guard player.current?.id == set.id else { return false }
        let start = set.annotations[index].time
        let end = index + 1 < set.annotations.count
            ? set.annotations[index + 1].time
            : set.duration
        return player.displayTime >= start && player.displayTime < end
    }

    private func trackLabel(_ cue: SetAnnotation, index: Int) -> String {
        let components = cue.label.split(separator: " ")
        if components.count == 2,
           components[0].localizedCaseInsensitiveCompare("cue") == .orderedSame,
           Int(components[1]) != nil {
            return "Track \(index + 1)"
        }
        return cue.label
    }

    private func normalizedTrackLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct MacTrackArtwork: View {
    @ObservedObject private var themes = MacThemeStore.shared
    let url: URL?
    let title: String

    @State private var localImage: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.accent.opacity(0.14))

            if let url, url.isFileURL {
                if let localImage {
                    Image(nsImage: localImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    fallback
                }
            } else if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.1)))
        .task(id: url) {
            guard let url, url.isFileURL else {
                localImage = nil
                return
            }
            localImage = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
        }
    }

    private var fallback: some View {
        Image(systemName: "music.note")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accent.opacity(0.72))
            .accessibilityLabel("Artwork for \(title)")
    }
}

private struct MacMutedVideoPlayer: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        MacAVPlayerView(player: player)
            .background(Color.black)
            .allowsHitTesting(false)
            .onAppear {
                muteVideo()
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
                muteVideo()
                player.play()
            }
    }

    private func muteVideo() {
        player.isMuted = true
        player.volume = 0
    }
}

private struct MacAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player = nil
    }
}

private struct MacWaveformLoadingView: View {
    @ObservedObject private var themes = MacThemeStore.shared
    var compact = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.accent.opacity(0.08),
                    Theme.background.opacity(0.2),
                    Theme.accent.opacity(0.05)
                ],
                startPoint: .leading,
                endPoint: .trailing)

            HStack(spacing: compact ? 7 : 10) {
                ProgressView()
                    .controlSize(compact ? .mini : .small)
                if !compact {
                    Text("Loading waveform…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .accessibilityLabel("Loading waveform")
    }
}

private struct MacScrollingWaveform: NSViewRepresentable {
    let set: DJSet
    let waveform: MacWaveform
    let theme: MacThemePreset

    func makeNSView(context: Context) -> MacScrollingWaveformView {
        let view = MacScrollingWaveformView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ view: MacScrollingWaveformView, context: Context) {
        view.configure(
            waveform: waveform,
            duration: set.duration,
            annotations: set.annotations,
            playheadColor: Self.cgColor(for: theme.playheadHex))
    }

    private static func cgColor(for hex: UInt32) -> CGColor {
        CGColor(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1)
    }
}

@MainActor
private final class MacScrollingWaveformView: NSView {
    private let player = MacPlayer.shared
    private var waveform: MacWaveform?
    private var duration: TimeInterval = 0
    private var annotations: [SetAnnotation] = []
    private var ticker: Timer?
    private var lastDrawnTime: TimeInterval = -1
    private var pixelsPerSecond: CGFloat = 48
    private var scrubStartTime: TimeInterval?
    private var scrubStartX: CGFloat?
    private var cachedWaveformImage: CGImage?
    private var cachedCenterTime: TimeInterval = -.greatestFiniteMagnitude
    private var cachedViewSize: CGSize = .zero
    private var cachedAnnotationIDs: [UUID] = []
    private var cachedWaveformCount = 0
    private let cachePadding: CGFloat = 240
    private let waveformLayer = CALayer()
    private let playheadLayer = CALayer()
    private let playheadCapLayer = CAShapeLayer()
    private var playheadColor = CGColor(
        red: 1,
        green: 59.0 / 255.0,
        blue: 48.0 / 255.0,
        alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(
        waveform: MacWaveform?,
        duration: TimeInterval,
        annotations: [SetAnnotation],
        playheadColor: CGColor
    ) {
        let shouldInvalidate = cachedWaveformCount != (waveform?.count ?? 0)
            || self.duration != duration
            || cachedAnnotationIDs != annotations.map(\.id)
        self.waveform = waveform
        self.duration = duration
        self.annotations = annotations
        self.playheadColor = playheadColor
        if shouldInvalidate {
            cachedWaveformCount = waveform?.count ?? 0
            cachedAnnotationIDs = annotations.map(\.id)
            cachedWaveformImage = nil
        }
        updateWaveformLayers(at: player.liveTime())
    }

    override func layout() {
        super.layout()
        if cachedViewSize != bounds.size {
            cachedWaveformImage = nil
        }
        updateWaveformLayers(at: player.liveTime())
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            installLayersIfNeeded()
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
            updateWaveformLayers(at: player.liveTime())
        }
    }

    @objc private func tick() {
        let now = player.liveTime()
        guard player.isPlaying || abs(now - lastDrawnTime) > 0.001 else { return }
        lastDrawnTime = now
        updateWaveformLayers(at: now)
    }

    private func installLayersIfNeeded() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        if waveformLayer.superlayer == nil {
            waveformLayer.contentsGravity = .resize
            layer?.addSublayer(waveformLayer)
            layer?.addSublayer(playheadLayer)
            layer?.addSublayer(playheadCapLayer)
        }
    }

    private func updateWaveformLayers(at now: TimeInterval) {
        installLayersIfNeeded()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard let waveform, waveform.count > 0, duration > 0 else {
            waveformLayer.isHidden = true
            playheadLayer.isHidden = true
            playheadCapLayer.isHidden = true
            return
        }

        let shouldRebuild = cachedWaveformImage == nil
            || cachedViewSize != size
            || abs(now - cachedCenterTime) * Double(pixelsPerSecond) > Double(cachePadding * 0.6)
        if shouldRebuild {
            rebuildWaveformCache(size: size, centerTime: now)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shouldRebuild, let cachedWaveformImage {
            waveformLayer.contents = cachedWaveformImage
            waveformLayer.contentsScale = window?.backingScaleFactor ?? 2
            waveformLayer.bounds = CGRect(
                origin: .zero,
                size: CGSize(width: size.width + cachePadding * 2, height: size.height))
        }
        waveformLayer.position = CGPoint(
            x: bounds.midX + CGFloat(cachedCenterTime - now) * pixelsPerSecond,
            y: bounds.midY)
        waveformLayer.isHidden = cachedWaveformImage == nil

        let centerX = size.width / 2
        playheadLayer.backgroundColor = playheadColor
        playheadLayer.frame = CGRect(x: centerX - 1, y: 0, width: 2, height: size.height)
        playheadLayer.isHidden = false
        let cap = CGMutablePath()
        cap.move(to: CGPoint(x: centerX - 7, y: 0))
        cap.addLine(to: CGPoint(x: centerX + 7, y: 0))
        cap.addLine(to: CGPoint(x: centerX, y: 9))
        cap.closeSubpath()
        playheadCapLayer.frame = bounds
        playheadCapLayer.path = cap
        playheadCapLayer.fillColor = playheadColor
        playheadCapLayer.isHidden = false
        CATransaction.commit()
    }

    private func rebuildWaveformCache(size: CGSize, centerTime: TimeInterval) {
        guard let waveform, waveform.count > 0, duration > 0 else { return }
        let canvasSize = CGSize(
            width: size.width + cachePadding * 2,
            height: size.height)
        let scale = window?.backingScaleFactor ?? 2
        let pixelWidth = max(1, Int(ceil(canvasSize.width * scale)))
        let pixelHeight = max(1, Int(ceil(canvasSize.height * scale)))
        guard let bitmap = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }

        bitmap.scaleBy(x: scale, y: scale)
        let centerY = canvasSize.height / 2
        let secondsPerBin = duration / Double(waveform.count)
        let step: CGFloat = 5
        let secondsPerBar = Double(step / pixelsPerSecond)
        var time = centerTime - Double(canvasSize.width / 2 / pixelsPerSecond)
        time = floor(time / secondsPerBar) * secondsPerBar
        let endTime = centerTime + Double(canvasSize.width / 2 / pixelsPerSecond)
        let bandBars = (0..<MacFrequencyPalette.bands.count).map { _ in
            CGMutablePath()
        }

        while time <= endTime {
            defer { time += secondsPerBar }
            guard time >= 0, time < duration else { continue }
            let x = canvasSize.width / 2 + CGFloat(time - centerTime) * pixelsPerSecond
            let bin = min(waveform.count - 1, max(0, Int(time / secondsPerBin)))
            let height = max(2, CGFloat(waveform.amps[bin]) * canvasSize.height * 0.86)
            let frequency = bin < waveform.frequency.count
                ? waveform.frequency[bin]
                : 0.45
            let band = MacFrequencyPalette.band(for: frequency)
            bandBars[band].move(to: CGPoint(x: x, y: centerY - height / 2))
            bandBars[band].addLine(to: CGPoint(x: x, y: centerY + height / 2))
        }

        bitmap.setLineWidth(2.4)
        bitmap.setLineCap(.round)
        for (band, path) in bandBars.enumerated() {
            let color = MacFrequencyPalette.bands[band]
            bitmap.setStrokeColor(CGColor(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: 1))
            bitmap.addPath(path)
            bitmap.strokePath()
        }

        for (index, track) in annotations.enumerated() {
            let x = canvasSize.width / 2
                + CGFloat(track.time - centerTime) * pixelsPerSecond
            guard x > -10, x < canvasSize.width + 10 else { continue }
            bitmap.setFillColor(cueCGColors[index % cueCGColors.count])
            bitmap.fill(CGRect(x: x - 0.75, y: 0, width: 1.5, height: canvasSize.height))
        }

        cachedWaveformImage = bitmap.makeImage()
        cachedCenterTime = centerTime
        cachedViewSize = size
    }

    override func mouseDown(with event: NSEvent) {
        scrubStartTime = player.liveTime()
        scrubStartX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrubStartTime, let scrubStartX else { return }
        let currentX = convert(event.locationInWindow, from: nil).x
        player.seek(to: scrubStartTime - Double((currentX - scrubStartX) / pixelsPerSecond))
        updateWaveformLayers(at: player.liveTime())
    }

    override func mouseUp(with event: NSEvent) {
        scrubStartTime = nil
        scrubStartX = nil
    }

    override func magnify(with event: NSEvent) {
        pixelsPerSecond = min(
            180,
            max(12, pixelsPerSecond * (1 + event.magnification)))
        cachedWaveformImage = nil
        updateWaveformLayers(at: player.liveTime())
    }

    override func scrollWheel(with event: NSEvent) {
        // The waveform supports scrubbing and zooming, but ordinary two-finger
        // scrolling should continue to move the surrounding dashboard.
        nextResponder?.scrollWheel(with: event)
    }
}

private let cueCGColors: [CGColor] = [
    CGColor(red: 47.0 / 255.0, green: 208.0 / 255.0, blue: 88.0 / 255.0, alpha: 1),
    CGColor(red: 1, green: 138.0 / 255.0, blue: 30.0 / 255.0, alpha: 1),
    CGColor(red: 248.0 / 255.0, green: 87.0 / 255.0, blue: 193.0 / 255.0, alpha: 1),
    CGColor(red: 25.0 / 255.0, green: 200.0 / 255.0, blue: 222.0 / 255.0, alpha: 1),
    CGColor(red: 182.0 / 255.0, green: 123.0 / 255.0, blue: 1, alpha: 1),
    CGColor(red: 1, green: 210.0 / 255.0, blue: 30.0 / 255.0, alpha: 1),
    CGColor(red: 1, green: 77.0 / 255.0, blue: 77.0 / 255.0, alpha: 1),
    CGColor(red: 77.0 / 255.0, green: 123.0 / 255.0, blue: 1, alpha: 1)
]

private func cgWaveformGradient(
    _ waveform: MacWaveform,
    startTime: TimeInterval,
    endTime: TimeInterval,
    duration: TimeInterval
) -> CGGradient? {
    let sampleCount = 20
    let safeDuration = max(duration, 0.001)
    let colors = (0..<sampleCount).map { index -> CGColor in
        let fraction = Double(index) / Double(sampleCount - 1)
        let time = startTime + (endTime - startTime) * fraction
        let waveformFraction = max(0, min(1, time / safeDuration))
        let bin = min(
            waveform.count - 1,
            max(0, Int(waveformFraction * Double(waveform.count - 1))))
        return CGColor(
            red: CGFloat(waveform.red[bin]),
            green: CGFloat(waveform.green[bin]),
            blue: CGFloat(waveform.blue[bin]),
            alpha: 1)
    }
    return CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: nil)
}

private func waveformGradient(
    _ waveform: MacWaveform,
    startTime: TimeInterval,
    endTime: TimeInterval,
    duration: TimeInterval = 1,
    opacity: Double = 1,
    startPoint: CGPoint,
    endPoint: CGPoint
) -> GraphicsContext.Shading {
    let sampleCount = 20
    let safeDuration = max(duration, 0.001)
    let colors = (0..<sampleCount).map { index -> Color in
        let fraction = Double(index) / Double(sampleCount - 1)
        let time = startTime + (endTime - startTime) * fraction
        let waveformFraction = max(0, min(1, time / safeDuration))
        let bin = min(
            waveform.count - 1,
            max(0, Int(waveformFraction * Double(waveform.count - 1))))
        return Color(
            red: Double(waveform.red[bin]),
            green: Double(waveform.green[bin]),
            blue: Double(waveform.blue[bin]))
            .opacity(opacity)
    }
    return .linearGradient(
        Gradient(colors: colors),
        startPoint: startPoint,
        endPoint: endPoint)
}

private struct MacOverviewWaveform: View {
    @ObservedObject private var player = MacPlayer.shared
    @ObservedObject private var themes = MacThemeStore.shared

    let set: DJSet

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                MacStaticWaveformBars(setID: set.id)

                Rectangle()
                    .fill(Theme.background.opacity(0.72))
                    .frame(width: max(0, geometry.size.width - playedX(in: geometry.size.width)))
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1.5)
                    .offset(x: playedX(in: geometry.size.width))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / geometry.size.width))
                        player.seek(to: Double(fraction) * player.duration)
                    }
            )
        }
    }

    private func playedX(in width: CGFloat) -> CGFloat {
        guard player.duration > 0 else { return 0 }
        return max(0, min(width, CGFloat(player.displayTime / player.duration) * width))
    }
}
