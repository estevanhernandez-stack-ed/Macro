// GamePickSheet.swift
// UI — modal sheet for picking a game before recording starts.
//
// 10c: replaces the hardcoded PS99 + Untagged pair with a list driven
// by `PluginLoader.shared.plugins`. Each indexed plugin renders as its
// own card; bundled plugins ship a "Default" tag, user-installed /
// url-installed plugins get a "Community" tag (matches the
// FirstLaunchTrustWarning's framing — they're unsigned but allowed).
// "Untagged" stays at the bottom as the escape hatch for ad-hoc
// recordings (no plugin matchers; manifest.game.name = "Roblox").
//
// Spec ref: docs/spec.md > Recorder ("game-pick sheet") +
// docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + docs/prd.md > Epic B (game-pick acceptance) +
// docs/spec.md > PluginLoader (10c integration).
//
// Voice: builder-to-builder, sentence case, no emoji. All visuals via
// MacRoTheme.

import SwiftUI

/// Sheet presented before recording starts. Caller passes a
/// `onConfirm(GameSelection)` callback; we dismiss before invoking it
/// so the calling view can drive the post-pick orchestration
/// (countdown overlay → recorder start) without competing for a
/// dismissal animation.
struct GamePickSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// Plugin index. Defaults to `PluginLoader.shared` so production
    /// callers don't need to thread the singleton; tests override.
    @State private var loader: PluginLoader = .shared

    /// Currently-selected row. `.untagged` is the safe default when no
    /// plugins are indexed (clean install before bundled-seed install
    /// runs); after `loadAll()` populates plugins, the first plugin
    /// (sorted by displayName) wins.
    @State private var selection: Selection = .untagged

    /// Called with the chosen GameSelection AFTER the sheet dismisses.
    /// ContentView wires this to present the CountdownOverlay.
    let onConfirm: (GameSelection) -> Void
    let onCancel: () -> Void

    /// Internal sheet selection. Mirrors `GameSelection` shape but stays
    /// `Hashable` for SwiftUI's selection-state plumbing (the embedded
    /// `Plugin` is `Hashable` too, so this rides cleanly).
    fileprivate enum Selection: Hashable {
        case plugin(Plugin)
        case untagged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.lg) {
            header
            cards
            Spacer(minLength: 0)
            footer
        }
        .padding(MacRoTheme.Spacing.xl)
        .frame(width: 560, height: 480)
        .background(MacRoTheme.Color.bgPage)
        .task {
            // Re-index every time the sheet opens so a plugin installed
            // since launch shows up. Idempotent; loadAll() is cheap.
            await loader.loadAll()
            // Default to first plugin (sorted by displayName) if any.
            if case .untagged = selection, let first = loader.plugins.first {
                selection = .plugin(first)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            Text("What game?")
                .font(MacRoTheme.Font.heading1)
                .foregroundStyle(MacRoTheme.Color.fg1)
            Text("Pick the game you're recording for. The choice pre-fills the macro's window matchers and target resolution.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cards

    private var cards: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: MacRoTheme.Spacing.md) {
                ForEach(loader.plugins, id: \.id) { plugin in
                    GameCard(
                        name: plugin.displayName,
                        description: pluginDescription(for: plugin),
                        tag: tag(for: plugin),
                        tagPalette: tagPalette(for: plugin),
                        isSelected: selection == .plugin(plugin),
                        onTap: { selection = .plugin(plugin) }
                    )
                }
                GameCard(
                    name: "Untagged / general",
                    description: "For Roblox games we don't have a plugin for. You'll set the window selectors manually later.",
                    tag: nil,
                    tagPalette: .neutral,
                    isSelected: selection == .untagged,
                    onTap: { selection = .untagged }
                )
            }
        }
    }

    /// Per-plugin caption — short, builder-to-builder. Bundled plugins
    /// auto-fill matchers; community plugins flag their unsigned status
    /// in the description so the user reads it twice.
    private func pluginDescription(for plugin: Plugin) -> String {
        switch plugin.source {
        case .bundled:
            return "Auto-fills target window selectors and recorded resolution. Bundled plugin — trusted."
        case .userInstalled, .urlInstalled:
            return "Auto-fills target window selectors. Community plugin — installed locally, not signed by 626 Labs."
        }
    }

    /// Top-right pill tag. Bundled plugins ship "Default", community
    /// plugins ship "Community"; nil for Untagged.
    private func tag(for plugin: Plugin) -> String? {
        switch plugin.source {
        case .bundled:        return "Default"
        case .userInstalled,
             .urlInstalled:   return "Community"
        }
    }

    /// Pill palette per source. Bundled = teal (matches the brand
    /// product accent), community = warn-amber so the user clocks the
    /// trust difference at a glance. Untagged uses .neutral (no pill).
    private func tagPalette(for plugin: Plugin) -> TagPalette {
        switch plugin.source {
        case .bundled:        return .teal
        case .userInstalled,
             .urlInstalled:   return .warn
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: MacRoTheme.Spacing.md) {
            SecondaryCTAButton(title: "Cancel") {
                dismiss()
                onCancel()
            }
            Spacer()
            PrimaryCTAButton(title: "Start Recording") {
                let chosen = currentGameSelection()
                dismiss()
                // Defer one runloop so the sheet's dismissal animation
                // doesn't fight the next overlay's presentation. Without
                // this, the countdown panel can race the sheet's
                // unmount and end up underneath.
                DispatchQueue.main.async {
                    onConfirm(chosen)
                }
            }
        }
    }

    /// Map the local Selection back to a GameSelection. PS99 routes
    /// through the legacy `.ps99` path so existing callsites
    /// (CountdownOverlay copy, RecorderTests fixtures) keep their
    /// shape; non-PS99 plugins flow through `.plugin(...)`.
    private func currentGameSelection() -> GameSelection {
        switch selection {
        case .plugin(let plugin):
            // PS99 has special-case behavior baked into the legacy
            // `.ps99` enum branch (placeId 8737899170, slug pet-sim-99,
            // displayName "Pet Simulator 99"). Map to it explicitly so
            // the recorder + manifest + library paths land in the same
            // slots as before.
            if plugin.id == "pet-sim-99" {
                return .ps99
            }
            return .plugin(GameSelection.PluginPick(
                id: plugin.id,
                displayName: plugin.displayName,
                placeId: plugin.placeId,
                windowClass: plugin.windowClass,
                windowTitleMatch: plugin.windowTitleMatch
            ))
        case .untagged:
            return .untagged
        }
    }
}

// MARK: - Tag palette

fileprivate enum TagPalette {
    case teal
    case warn
    case neutral
}

// MARK: - Per-game card

private struct GameCard: View {
    let name: String
    let description: String
    let tag: String?
    let tagPalette: TagPalette
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
                HStack(spacing: MacRoTheme.Spacing.sm) {
                    Text(name)
                        .font(MacRoTheme.Font.body)
                        .foregroundStyle(MacRoTheme.Color.fg1)
                    if let tag {
                        TagPill(text: tag, palette: tagPalette)
                    }
                    Spacer()
                    SelectionDot(isSelected: isSelected)
                }
                Text(description)
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(MacRoTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.lg, style: .continuous)
                    .fill(MacRoTheme.Color.bgRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? MacRoTheme.Color.brandCyan
                            : (hovering ? MacRoTheme.Color.fg3 : MacRoTheme.Color.bgSurface),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TagPill: View {
    let text: String
    let palette: TagPalette

    var body: some View {
        Text(text)
            .font(MacRoTheme.Font.monoMicro)
            .foregroundStyle(foreground)
            .tracking(0.12 * 11)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
    }

    private var foreground: Color {
        switch palette {
        case .teal:    return MacRoTheme.Color.productTeal
        case .warn:    return MacRoTheme.Color.stateWarn
        case .neutral: return MacRoTheme.Color.fg3
        }
    }

    private var background: Color {
        switch palette {
        case .teal:    return MacRoTheme.Color.productTeal.opacity(0.16)
        case .warn:    return MacRoTheme.Color.stateWarn.opacity(0.16)
        case .neutral: return MacRoTheme.Color.bgSurface
        }
    }
}

private struct SelectionDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? MacRoTheme.Color.brandCyan : MacRoTheme.Color.fg3,
                    lineWidth: 2
                )
                .frame(width: 18, height: 18)
            if isSelected {
                Circle()
                    .fill(MacRoTheme.Color.brandCyan)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// MARK: - CTAs

/// Primary CTA. Replicates OnboardingView's PrimaryButton inline because
/// that file's button is fileprivate; the consistent spec is "teal fill,
/// bgPage text, 10pt radius, contentShape rect for hit-test".
private struct PrimaryCTAButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.bgPage)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MacRoTheme.Color.productTeal.opacity(hovering ? 0.92 : 1.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SecondaryCTAButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            hovering
                                ? MacRoTheme.Color.brandCyan
                                : MacRoTheme.Color.fg3,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#Preview {
    GamePickSheet(
        onConfirm: { _ in },
        onCancel: {}
    )
}
