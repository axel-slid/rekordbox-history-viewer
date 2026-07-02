import SwiftUI

@main
struct SetPlayerApp: App {
    @StateObject private var library = Library()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundAnalyzer.register()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // in-app analysis must not run while backgrounded: sustained
                // CPU alongside background audio gets the whole app killed
                WaveformStore.shared.setSuspended(true)
                BackgroundAnalyzer.scheduleIfNeeded()
            case .active:
                WaveformStore.shared.setSuspended(false)
                // pick up grids analyzed while we were in the background
                library.analyzeAll()
            default:
                break
            }
        }
    }
}
