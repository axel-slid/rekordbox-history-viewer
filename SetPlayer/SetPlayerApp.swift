import SwiftUI

@main
struct SetPlayerApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
