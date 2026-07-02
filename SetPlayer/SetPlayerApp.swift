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
                BackgroundAnalyzer.scheduleIfNeeded()
            case .active:
                // pick up grids analyzed while we were in the background
                library.analyzeAll()
            default:
                break
            }
        }
    }
}
