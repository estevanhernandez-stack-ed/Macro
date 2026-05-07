// LibrarySettingsView.swift
// UI — feed URL override + per-macro auto-update toggles.
//
// 9c surface, presented as a sheet from `LibraryView`'s top-bar gear
// icon. Lives in its own file so the settings layout doesn't bloat
// `LibraryView`. Persistence is via UserDefaults keys defined on
// `LibraryStore.Defaults` — nothing extra to wire.
//
// Validation: feed URL must be `https://` or `file://` (matches the
// store's scheme allowlist). Inline error shown on commit; the field
// keeps the user's invalid entry so they can correct it without
// retyping.

import SwiftUI

struct LibrarySettingsView: View {

    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var feedURLText: String = ""
    @State private var feedURLError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.lg) {
            header
            feedURLSection
            Divider().background(MacRoTheme.Color.laneBorder)
            autoUpdateSection
            Spacer(minLength: 0)
            footer
        }
        .padding(MacRoTheme.Spacing.xl)
        .frame(width: 560, height: 580)
        .background(MacRoTheme.Color.bgPage)
        .onAppear {
            feedURLText = store.feedURL.absoluteString
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
            Text("Library Settings")
                .font(MacRoTheme.Font.heading1)
                .foregroundStyle(MacRoTheme.Color.fg1)
            Text("Override the feed URL or pin macros against auto-update. Settings apply immediately.")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Feed URL

    private var feedURLSection: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            Text("FEED URL")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)

            HStack(spacing: MacRoTheme.Spacing.sm) {
                TextField("https://macros.626labs.com/feed.json", text: $feedURLText, onCommit: {
                    commitFeedURL()
                })
                .textFieldStyle(.roundedBorder)
                .font(MacRoTheme.Font.mono)
                .frame(maxWidth: .infinity)

                Button("Save") { commitFeedURL() }
                    .buttonStyle(.borderedProminent)
                    .tint(MacRoTheme.Color.productTeal)

                Button("Reset") {
                    feedURLText = LibraryStore.defaultFeedURLString
                    commitFeedURL()
                }
                .buttonStyle(.bordered)
            }

            if let feedURLError {
                Text(feedURLError)
                    .font(MacRoTheme.Font.monoMicro)
                    .foregroundStyle(MacRoTheme.Color.stateDanger)
            } else {
                Text("https:// for production, file:// for local-test feeds. Other schemes are refused.")
                    .font(MacRoTheme.Font.monoMicro)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
        }
    }

    private func commitFeedURL() {
        let trimmed = feedURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            feedURLError = "Could not parse URL — check for typos."
            return
        }
        guard LibraryStore.isAllowedFeedScheme(url) else {
            feedURLError = "Scheme must be https:// or file://."
            return
        }
        feedURLError = nil
        store.feedURL = url
        // Refresh immediately so the user sees the result.
        Task {
            await store.refreshRemoteCatalog()
            await store.checkForUpdates()
        }
    }

    // MARK: - Auto-update

    private var autoUpdateSection: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            Text("AUTO-UPDATE")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)

            let factoryEntries = store.localEntries.filter { $0.factoryPatchable }

            if factoryEntries.isEmpty {
                Text("No factory-patchable macros installed yet. Auto-update applies only to macros with `factoryPatchable: true` in their manifest.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(factoryEntries) { entry in
                            AutoUpdateRow(store: store, entry: entry)
                            if entry.id != factoryEntries.last?.id {
                                Divider().background(MacRoTheme.Color.laneBorder)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                            .fill(MacRoTheme.Color.bgSurface)
                    )
                }
                .frame(maxHeight: 280)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(MacRoTheme.Color.productTeal)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Row

/// One row in the auto-update list. `Toggle` is bound to the inverse of
/// `isAutoUpdateDisabled` so "ON" reads as "auto-update enabled".
private struct AutoUpdateRow: View {
    @Bindable var store: LibraryStore
    let entry: LibraryEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text("\(entry.game) · v\(entry.version)")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { !store.isAutoUpdateDisabled(for: entry.id) },
                set: { newValue in
                    store.setAutoUpdateDisabled(!newValue, for: entry.id)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(MacRoTheme.Spacing.md)
    }
}

#Preview {
    LibrarySettingsView(store: .shared)
}
