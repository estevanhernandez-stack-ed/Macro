// UpdateSettingsView.swift
// UI — Sparkle update controls + downgrade list (stub for 11a).
//
// Mounted as a tab inside `LibrarySettingsView`'s TabView (item 11a).
// Sparkle's standard controller lives on `MacRoApp` as @State; we pass
// the underlying `SPUUpdater` down. The optional shape covers the brief
// pre-.onAppear window where the controller hasn't booted yet — the
// gear icon that opens this sheet is unreachable until LibraryView is
// up, so in practice the updater is always non-nil at sheet time.
//
// Sections:
//   • Updates — automatic-checks toggle, manual "Check Now", last-checked
//     timestamp.
//   • Downgrade — STUB for 11a. Always empty until Sparkle's history-
//     tracking + downgrade-pointer-swap lands in a later item. Shows
//     "Download history coming soon" copy when the list is empty.
//
// Spec ref: docs/spec.md > Distribution & release; docs/checklist.md item 11a.

import Sparkle
import SwiftUI

/// Single row in the (future) downgrade list. v1 stub — never populated
/// in 11a; lands when Sparkle history-tracking + version-pointer swap
/// is wired in a later iteration.
struct DowngradeVersion: Identifiable, Hashable {
    let id: String
    let version: String
    let installedAt: Date
}

struct UpdateSettingsView: View {

    /// Live Sparkle updater. Optional to cover pre-.onAppear boot
    /// timing — at sheet-time this should always be non-nil.
    let updater: SPUUpdater?

    /// Local mirror of Sparkle's `automaticallyChecksForUpdates`.
    /// Initialized from the updater on appear, written back on toggle.
    @State private var automaticallyChecks: Bool = true

    /// Stub state — always empty in 11a. Populated when Sparkle history
    /// tracking lands.
    @State private var downgradeVersions: [DowngradeVersion] = []

    /// Forces last-checked label refresh after manual checks.
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.lg) {
            updatesSection
            Divider().background(MacRoTheme.Color.laneBorder)
            downgradeSection
            Spacer(minLength: 0)
        }
        .padding(MacRoTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacRoTheme.Color.bgPage)
        .onAppear {
            if let updater {
                automaticallyChecks = updater.automaticallyChecksForUpdates
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            Text("UPDATES")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)

            Toggle(isOn: $automaticallyChecks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically check for updates")
                        .font(MacRoTheme.Font.body)
                        .foregroundStyle(MacRoTheme.Color.fg1)
                    Text("Daily check against the Sparkle appcast feed.")
                        .font(MacRoTheme.Font.bodySmall)
                        .foregroundStyle(MacRoTheme.Color.fg3)
                }
            }
            .toggleStyle(.switch)
            .disabled(updater == nil)
            .onChange(of: automaticallyChecks) { _, newValue in
                updater?.automaticallyChecksForUpdates = newValue
            }

            HStack(spacing: MacRoTheme.Spacing.md) {
                Button("Check for Updates Now") {
                    updater?.checkForUpdates()
                    // Bump the tick so the last-checked label re-reads
                    // after the synchronous handoff. The actual check
                    // is async; the timestamp updates whenever Sparkle
                    // finishes.
                    refreshTick &+= 1
                }
                .buttonStyle(.borderedProminent)
                .tint(MacRoTheme.Color.productTeal)
                .disabled(updater == nil || (updater?.canCheckForUpdates == false))

                Spacer()

                lastCheckedLabel
            }
        }
    }

    private var lastCheckedLabel: some View {
        // refreshTick is referenced to force re-evaluation after the
        // user hits the manual button — even if Sparkle hasn't finished
        // yet, the binding stays consistent.
        let _ = refreshTick
        let formatted: String = {
            guard let updater, let date = updater.lastUpdateCheckDate else { return "Never" }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }()
        return Text("Last checked: \(formatted)")
            .font(MacRoTheme.Font.monoMicro)
            .tracking(0.12 * 11)
            .foregroundStyle(MacRoTheme.Color.fg3)
    }

    // MARK: - Downgrade (stub)

    private var downgradeSection: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            Text("DOWNGRADE")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)

            if downgradeVersions.isEmpty {
                Text("Download history coming soon — available after the first published Sparkle release.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(downgradeVersions) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("v\(version.version)")
                                    .font(MacRoTheme.Font.body)
                                    .foregroundStyle(MacRoTheme.Color.fg1)
                                Text(installedDateString(version.installedAt))
                                    .font(MacRoTheme.Font.monoMicro)
                                    .tracking(0.12 * 11)
                                    .foregroundStyle(MacRoTheme.Color.fg3)
                            }
                            Spacer()
                            Button("Downgrade to v\(version.version)") {
                                // Wired when Sparkle history-tracking
                                // + version-pointer swap lands in a
                                // later iteration.
                            }
                            .buttonStyle(.bordered)
                            .disabled(true)
                        }
                        .padding(MacRoTheme.Spacing.md)
                        if version.id != downgradeVersions.last?.id {
                            Divider().background(MacRoTheme.Color.laneBorder)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                        .fill(MacRoTheme.Color.bgSurface)
                )
            }
        }
    }

    private func installedDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

#Preview {
    UpdateSettingsView(updater: nil)
        .frame(width: 560, height: 580)
}
