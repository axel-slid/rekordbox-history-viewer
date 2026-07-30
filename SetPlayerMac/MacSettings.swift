import SwiftUI

enum MacThemeCategory: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    case transparent = "Transparent"

    var id: String { rawValue }
}

struct MacThemePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let category: MacThemeCategory
    let backgroundHex: UInt32
    let panelHex: UInt32
    let borderHex: UInt32
    let accentHex: UInt32
    let warmHex: UInt32
    let mutedHex: UInt32
    let playheadHex: UInt32
    var backgroundOpacity: Double = 1
    var panelOpacity: Double = 1

    var isDark: Bool { category != .light }
    var isTransparent: Bool { category == .transparent }
    var background: Color { Color(hex: backgroundHex).opacity(backgroundOpacity) }
    var panel: Color { Color(hex: panelHex).opacity(panelOpacity) }
    var border: Color { Color(hex: borderHex) }
    var accent: Color { Color(hex: accentHex) }
    var warm: Color { Color(hex: warmHex) }
    var muted: Color { Color(hex: mutedHex) }
    var playhead: Color { Color(hex: playheadHex) }

    static let all: [MacThemePreset] = [
        MacThemePreset(
            id: "light-plus", name: "Light+", category: .light,
            backgroundHex: 0xEEF2F7, panelHex: 0xFAFCFF,
            borderHex: 0xC8D0DA, accentHex: 0x007ACC,
            warmHex: 0xD97706, mutedHex: 0x667085, playheadHex: 0xD1242F),
        MacThemePreset(
            id: "quiet-light", name: "Quiet Light", category: .light,
            backgroundHex: 0xF6F8FA, panelHex: 0xFFFFFF,
            borderHex: 0xD6DAE1, accentHex: 0x5876A3,
            warmHex: 0xA16207, mutedHex: 0x6B7280, playheadHex: 0xB91C1C),
        MacThemePreset(
            id: "solarized-light", name: "Solarized Light", category: .light,
            backgroundHex: 0xFDF6E3, panelHex: 0xEEE8D5,
            borderHex: 0xC8BFA8, accentHex: 0x268BD2,
            warmHex: 0xB58900, mutedHex: 0x657B83, playheadHex: 0xDC322F),
        MacThemePreset(
            id: "catppuccin-latte", name: "Catppuccin Latte", category: .light,
            backgroundHex: 0xEFF1F5, panelHex: 0xE6E9EF,
            borderHex: 0xCCD0DA, accentHex: 0x1E66F5,
            warmHex: 0xFE640B, mutedHex: 0x6C6F85, playheadHex: 0xD20F39),
        MacThemePreset(
            id: "minimal-light", name: "Minimal", category: .light,
            backgroundHex: 0xF8FAFC, panelHex: 0xFFFFFF,
            borderHex: 0xDCE3EC, accentHex: 0x007ACC,
            warmHex: 0xE67E22, mutedHex: 0x718096, playheadHex: 0xE53E3E),

        MacThemePreset(
            id: "set-player", name: "Set Player", category: .dark,
            backgroundHex: 0x121419, panelHex: 0x1C1F26,
            borderHex: 0x2A2E38, accentHex: 0x00AEEF,
            warmHex: 0xE8641E, mutedHex: 0x8A919E, playheadHex: 0xFF3B30),
        MacThemePreset(
            id: "dark-plus", name: "Dark+", category: .dark,
            backgroundHex: 0x1E1E1E, panelHex: 0x252526,
            borderHex: 0x414145, accentHex: 0x3794FF,
            warmHex: 0xCE9178, mutedHex: 0x969696, playheadHex: 0xF44747),
        MacThemePreset(
            id: "monokai", name: "Monokai", category: .dark,
            backgroundHex: 0x272822, panelHex: 0x37382F,
            borderHex: 0x535448, accentHex: 0xF92672,
            warmHex: 0xFD971F, mutedHex: 0xC2C2B0, playheadHex: 0xF92672),
        MacThemePreset(
            id: "solarized-dark", name: "Solarized Dark", category: .dark,
            backgroundHex: 0x002B36, panelHex: 0x073642,
            borderHex: 0x28515A, accentHex: 0x268BD2,
            warmHex: 0xB58900, mutedHex: 0x93A1A1, playheadHex: 0xDC322F),
        MacThemePreset(
            id: "dracula", name: "Dracula", category: .dark,
            backgroundHex: 0x282A36, panelHex: 0x343746,
            borderHex: 0x44475A, accentHex: 0xFF79C6,
            warmHex: 0xFFB86C, mutedHex: 0xBD93F9, playheadHex: 0xFF5555),
        MacThemePreset(
            id: "nord", name: "Nord", category: .dark,
            backgroundHex: 0x2E3440, panelHex: 0x3B4252,
            borderHex: 0x4C566A, accentHex: 0x88C0D0,
            warmHex: 0xD08770, mutedHex: 0xD8DEE9, playheadHex: 0xBF616A),
        MacThemePreset(
            id: "gruvbox-dark", name: "Gruvbox Dark", category: .dark,
            backgroundHex: 0x282828, panelHex: 0x3C3836,
            borderHex: 0x504945, accentHex: 0xFABD2F,
            warmHex: 0xFE8019, mutedHex: 0xBDAE93, playheadHex: 0xFB4934),
        MacThemePreset(
            id: "one-dark-pro", name: "One Dark Pro", category: .dark,
            backgroundHex: 0x282C34, panelHex: 0x21252B,
            borderHex: 0x3E4451, accentHex: 0x61AFEF,
            warmHex: 0xD19A66, mutedHex: 0x828997, playheadHex: 0xE06C75),
        MacThemePreset(
            id: "github-dark", name: "GitHub Dark", category: .dark,
            backgroundHex: 0x0D1117, panelHex: 0x161B22,
            borderHex: 0x30363D, accentHex: 0x58A6FF,
            warmHex: 0xFFA657, mutedHex: 0x8B949E, playheadHex: 0xFF7B72),
        MacThemePreset(
            id: "catppuccin-mocha", name: "Catppuccin Mocha", category: .dark,
            backgroundHex: 0x1E1E2E, panelHex: 0x181825,
            borderHex: 0x45475A, accentHex: 0x89B4FA,
            warmHex: 0xFAB387, mutedHex: 0xA6ADC8, playheadHex: 0xF38BA8),
        MacThemePreset(
            id: "tokyo-night", name: "Tokyo Night", category: .dark,
            backgroundHex: 0x1A1B26, panelHex: 0x16161E,
            borderHex: 0x34364A, accentHex: 0x7AA2F7,
            warmHex: 0xFF9E64, mutedHex: 0x9AA5CE, playheadHex: 0xF7768E),
        MacThemePreset(
            id: "ayu-dark", name: "Ayu Dark", category: .dark,
            backgroundHex: 0x0F1419, panelHex: 0x111822,
            borderHex: 0x28323C, accentHex: 0xFFCC66,
            warmHex: 0xFF8F40, mutedHex: 0xB3B1AD, playheadHex: 0xF07178),
        MacThemePreset(
            id: "palenight", name: "Palenight", category: .dark,
            backgroundHex: 0x292D3E, panelHex: 0x222638,
            borderHex: 0x444A63, accentHex: 0x82AAFF,
            warmHex: 0xF78C6C, mutedHex: 0x8796B0, playheadHex: 0xF07178),
        MacThemePreset(
            id: "honey-dark", name: "Honey Dark", category: .dark,
            backgroundHex: 0x120D05, panelHex: 0x1B1408,
            borderHex: 0x5B4316, accentHex: 0xFBBF24,
            warmHex: 0xFDBA74, mutedHex: 0xCAA96B, playheadHex: 0xF87171),
        MacThemePreset(
            id: "molten-amber", name: "Molten Amber", category: .dark,
            backgroundHex: 0x100706, panelHex: 0x1C0F0A,
            borderHex: 0x643219, accentHex: 0xFB923C,
            warmHex: 0xFD6E35, mutedHex: 0xE0AD80, playheadHex: 0xFB7185),
        MacThemePreset(
            id: "saffron-night", name: "Saffron Night", category: .dark,
            backgroundHex: 0x0F0A03, panelHex: 0x171005,
            borderHex: 0x5B4612, accentHex: 0xEAB308,
            warmHex: 0xF59E0B, mutedHex: 0xC9AA62, playheadHex: 0xFB7185),
        MacThemePreset(
            id: "amber-slate", name: "Amber Slate", category: .dark,
            backgroundHex: 0x111827, panelHex: 0x1F2937,
            borderHex: 0x4B3B22, accentHex: 0xF59E0B,
            warmHex: 0xFDBA74, mutedHex: 0xC7AD82, playheadHex: 0xFCA5A5),

        MacThemePreset(
            id: "graphite-glass", name: "Graphite Glass", category: .transparent,
            backgroundHex: 0x111318, panelHex: 0x20242C,
            borderHex: 0x6B7280, accentHex: 0x93C5FD,
            warmHex: 0xFDBA74, mutedHex: 0xCBD5E1, playheadHex: 0xFB7185,
            backgroundOpacity: 0.48, panelOpacity: 0.58),
        MacThemePreset(
            id: "ocean-glass", name: "Ocean Glass", category: .transparent,
            backgroundHex: 0x061927, panelHex: 0x0D334A,
            borderHex: 0x4D8BA8, accentHex: 0x38BDF8,
            warmHex: 0xFB923C, mutedHex: 0xBAE6FD, playheadHex: 0xF43F5E,
            backgroundOpacity: 0.46, panelOpacity: 0.56),
        MacThemePreset(
            id: "amber-glass", name: "Amber Glass", category: .transparent,
            backgroundHex: 0x1B0E04, panelHex: 0x3A210B,
            borderHex: 0xA16207, accentHex: 0xFBBF24,
            warmHex: 0xFB923C, mutedHex: 0xFDE68A, playheadHex: 0xFB7185,
            backgroundOpacity: 0.45, panelOpacity: 0.56)
    ]

    static let defaultTheme = all.first(where: { $0.id == "set-player" })!
}

final class MacThemeStore: ObservableObject {
    static let shared = MacThemeStore()

    @Published private(set) var selectedID: String

    private let defaultsKey = "setPlayerThemePreset"

    private init() {
        let saved = UserDefaults.standard.string(forKey: defaultsKey)
        selectedID = MacThemePreset.all.contains(where: { $0.id == saved })
            ? (saved ?? MacThemePreset.defaultTheme.id)
            : MacThemePreset.defaultTheme.id
    }

    var selectedTheme: MacThemePreset {
        MacThemePreset.all.first(where: { $0.id == selectedID })
            ?? MacThemePreset.defaultTheme
    }

    func select(_ theme: MacThemePreset) {
        guard selectedID != theme.id else { return }
        selectedID = theme.id
        UserDefaults.standard.set(theme.id, forKey: defaultsKey)
    }
}

struct MacSettingsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themes = MacThemeStore.shared
    @State private var category: MacThemeCategory = .dark
    @State private var searchText = ""

    private var visibleThemes: [MacThemePreset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return MacThemePreset.all.filter {
            $0.category == category
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider().overlay(Theme.panelBorder)
            appearanceContent
        }
        .frame(width: 860, height: 610)
        .background(Theme.background)
        .onAppear {
            category = themes.selectedTheme.category
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 20)

            Text("GENERAL")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textDim)

            Label("Appearance", systemImage: "paintpalette.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("CURRENT THEME")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Text(themes.selectedTheme.name)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(18)
        .frame(width: 210)
        .background(Theme.panel.opacity(0.72))
    }

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Appearance")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Choose a color or transparent glass preset for the whole workspace.")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textDim)
                    TextField("Search themes", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(width: 190, height: 32)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.panelBorder))
            }
            .padding(22)

            Picker("Theme category", selection: $category) {
                ForEach(MacThemeCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.bottom, 16)

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(visibleThemes) { theme in
                        MacThemePresetCard(
                            theme: theme,
                            isSelected: themes.selectedID == theme.id) {
                                themes.select(theme)
                            }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }
}

private struct MacThemePresetCard: View {
    let theme: MacThemePreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    theme.background
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Circle().fill(theme.accent).frame(width: 6, height: 6)
                            Capsule().fill(theme.muted.opacity(0.55)).frame(height: 5)
                            Capsule().fill(theme.muted.opacity(0.32)).frame(width: 24, height: 5)
                        }
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.panel)
                                .frame(width: 34)
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.panel)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.accent.opacity(0.24))
                                    .frame(height: 14)
                            }
                        }
                    }
                    .padding(9)
                }
                .frame(height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border))

                HStack {
                    Text(theme.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(9)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(isSelected ? Theme.accent : Theme.panelBorder, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}
