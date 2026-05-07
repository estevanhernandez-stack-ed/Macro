// FirstLaunchTrustWarning.swift
// UI — Gatekeeper-style modal for unsigned community plugins.
//
// Shown when `PluginLoader.shared.firstLaunchWarningPending` is non-empty.
// One row per pending plugin with two actions: Allow (records the
// per-plugin acknowledgement in UserDefaults — `loadAll()` won't re-file
// it on subsequent launches) or Remove (deletes the plugin's directory
// under `~/Library/Application Support/macRo/Plugins/<id>/` so the next
// `loadAll()` doesn't rediscover it).
//
// Bundled plugins are NEVER in the pending list — `Plugin.isUnsigned`
// is false for `.bundled`, and `loadAll()` filters on that. The modal
// stays up until every pending plugin gets a decision (one Allow or
// Remove per row).
//
// Spec ref: docs/spec.md > PluginLoader (trust model + first-launch
//           warning seam) +
//           docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 9.
//
// Voice: builder-to-builder, plain English, no scary-modal hyperbole.
// All visuals via MacRoTheme. Mirrors BindingMismatchPrompt's overall
// layout (header / list / footer) so the two trust-prompts feel like
// they came from the same hand.

import SwiftUI

/// Modal sheet listing each pending unsigned plugin with Allow / Remove
/// actions. Mounted in `ContentView` as a `.sheet(isPresented:)` keyed
/// off `!PluginLoader.shared.firstLaunchWarningPending.isEmpty`.
public struct FirstLaunchTrustWarning: View {

    /// Bound loader. Production passes `PluginLoader.shared`; tests pass
    /// a fixture loader.
    @Bindable public var loader: PluginLoader

    /// Called when the user has resolved every pending row. Caller
    /// dismisses the sheet here; it doesn't dismiss itself because the
    /// presenting view owns the `isPresented` binding.
    public let onAllResolved: () -> Void

    public init(
        loader: PluginLoader,
        onAllResolved: @escaping () -> Void
    ) {
        self.loader = loader
        self.onAllResolved = onAllResolved
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.lg) {
            header
            pluginList
            Spacer(minLength: 0)
            footer
        }
        .padding(MacRoTheme.Spacing.xl)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360)
        .background(MacRoTheme.Color.bgPage)
        .onChange(of: loader.firstLaunchWarningPending.count) { _, newValue in
            if newValue == 0 {
                onAllResolved()
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            Text("Allow community plugins?")
                .font(MacRoTheme.Font.heading1)
                .foregroundStyle(MacRoTheme.Color.fg1)

            Text("These plugins were installed locally and are not signed by 626 Labs. Allow each one to be used for recording and macro discovery, or remove it.")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var pluginList: some View {
        VStack(spacing: MacRoTheme.Spacing.sm) {
            ForEach(loader.firstLaunchWarningPending, id: \.id) { plugin in
                TrustRow(
                    plugin: plugin,
                    onAllow: {
                        loader.acknowledgeFirstLaunchWarning(for: plugin.id)
                    },
                    onRemove: {
                        Self.removePlugin(plugin)
                        // After deletion, reload so the pending list
                        // drops the row. Acknowledgement persists too —
                        // a second copy at the same id wouldn't re-prompt.
                        loader.acknowledgeFirstLaunchWarning(for: plugin.id)
                        Task { await loader.loadAll() }
                    }
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("Bundled plugins (e.g., Pet Simulator 99) are signed by 626 Labs and never appear here.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg3)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - File ops

    /// Remove an unsigned plugin's directory. Best-effort — failures are
    /// logged to stderr so the user gets out of the modal even if the
    /// disk operation fails. The next `loadAll()` will re-discover the
    /// plugin if it's still on disk; the acknowledgement persists in
    /// UserDefaults so the prompt won't fire again, but the user can
    /// always remove the directory by hand.
    static func removePlugin(_ plugin: Plugin) {
        // The plugin directory is the plugin.yaml's parent.
        let pluginDir = plugin.pluginYamlURL.deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: pluginDir)
        } catch {
            FileHandle.standardError.write(Data(
                "FirstLaunchTrustWarning: failed to remove plugin dir at \(pluginDir.path): \(error.localizedDescription)\n".utf8
            ))
        }
    }
}

// MARK: - Per-plugin row

private struct TrustRow: View {
    let plugin: Plugin
    let onAllow: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: MacRoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: MacRoTheme.Spacing.sm) {
                    Text(plugin.displayName)
                        .font(MacRoTheme.Font.body)
                        .foregroundStyle(MacRoTheme.Color.fg1)

                    UnsignedTag()
                }
                Text("ID \(plugin.id) — placeId \(plugin.placeId)")
                    .font(MacRoTheme.Font.monoMicro)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                    .tracking(0.12 * 11)
                    .textCase(.uppercase)
                Text("This plugin was installed locally and is not signed by 626 Labs. Allow it to be used for recording and macro discovery?")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Spacer(minLength: MacRoTheme.Spacing.md)

            VStack(alignment: .trailing, spacing: MacRoTheme.Spacing.xs) {
                PrimaryButton(title: "Allow", action: onAllow)
                SecondaryButton(title: "Remove", action: onRemove)
            }
        }
        .padding(MacRoTheme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                .fill(MacRoTheme.Color.bgSurface)
        )
    }
}

private struct UnsignedTag: View {
    var body: some View {
        Text("Unsigned")
            .font(MacRoTheme.Font.monoMicro)
            .foregroundStyle(MacRoTheme.Color.stateWarn)
            .tracking(0.12 * 11)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(MacRoTheme.Color.stateWarn.opacity(0.16))
            )
    }
}

// MARK: - Buttons

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.bgPage)
                .padding(.horizontal, MacRoTheme.Spacing.lg)
                .padding(.vertical, MacRoTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                        .fill(MacRoTheme.Color.productTeal.opacity(hovering ? 0.92 : 1.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, MacRoTheme.Spacing.lg)
                .padding(.vertical, MacRoTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                        .strokeBorder(
                            hovering
                                ? MacRoTheme.Color.stateDanger
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
