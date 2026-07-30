import AppKit
import SwiftUI

@main
struct SetPlayerMacApp: App {
    @StateObject private var library = MacLibrary()
    @StateObject private var themes = MacThemeStore.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                MacWindowBackdrop(theme: themes.selectedTheme)
                    .ignoresSafeArea()

                MacContentView()
                    .environmentObject(library)
                    .preferredColorScheme(themes.selectedTheme.isDark ? .dark : .light)
                    .tint(Theme.accent)
            }
            .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            MacLiveLyricsCommands()

            CommandGroup(after: .newItem) {
                Button("Sync with iPhone") {
                    Task { await library.syncNow() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Window("Live Lyrics", id: "live-lyrics") {
            MacLiveLyricsView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_180, height: 700)
        .windowResizability(.contentMinSize)

        Window("Rave Lyrics", id: "rave-lyrics") {
            MacLiveLyricsView(backdrop: .rave)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_280, height: 760)
        .windowResizability(.contentMinSize)
    }
}

private struct MacLiveLyricsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Lyrics") {
            Button("Open Live Lyrics") {
                openWindow(id: "live-lyrics")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Open Rave Lyrics") {
                openWindow(id: "rave-lyrics")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
    }
}

private struct MacWindowBackdrop: NSViewRepresentable {
    let theme: MacThemePreset

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.isHidden = !theme.isTransparent
        view.state = theme.isTransparent ? .active : .inactive

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = !theme.isTransparent
            window.backgroundColor = theme.isTransparent
                ? .clear
                : NSColor(rgbHex: theme.backgroundHex)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            for buttonType in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ] {
                window.standardWindowButton(buttonType)?.isHidden = false
                window.standardWindowButton(buttonType)?.alphaValue = 1
            }
        }
    }
}

private extension NSColor {
    convenience init(rgbHex: UInt32) {
        self.init(
            calibratedRed: CGFloat((rgbHex >> 16) & 0xff) / 255,
            green: CGFloat((rgbHex >> 8) & 0xff) / 255,
            blue: CGFloat(rgbHex & 0xff) / 255,
            alpha: 1)
    }
}
