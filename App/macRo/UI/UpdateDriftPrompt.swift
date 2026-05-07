// UpdateDriftPrompt.swift
// UI — warn-then-decide modal for `applyUpdate` when the user has local
// edits.
//
// `LibraryStore.checkForUpdates()` files an `AvailableUpdate { drifted }`
// for each local entry whose remote counterpart is newer. When the user
// clicks "Update" on a drifted entry, this sheet asks them how to handle
// their local edits. Three paths:
//
//   • Keep my version              → applyUpdate(_:, mode: .keepLocal)
//   • Install update (destructive) → applyUpdate(_:, mode: .overwrite)
//   • Save my copy as new + install → applyUpdate(_:, mode: .saveLocalAsNew)
//
// 9b builds the View and exposes `.onResolve(UpdateMode)`. 9c wires it
// into `LibraryView` via `.sheet(isPresented:)`.
//
// Pattern reference: BindingMismatchPrompt.swift — same domain-triggered
// modal shape, same Cancel-doesn't-persist discipline. All visuals route
// through `MacRoTheme`.

import SwiftUI

// MARK: - View

/// Modal sheet shown by `LibraryView` (in 9c) when the user clicks
/// "Update" on an `AvailableUpdate` whose `drifted == true`. Drives a
/// single `LibraryStore.UpdateMode` resolution callback — the library
/// view awaits this before calling `applyUpdate`.
public struct UpdateDriftPrompt: View {

    // MARK: Inputs

    /// The pending update — local + remote + drifted bit. Read-only.
    public let update: AvailableUpdate

    /// Resolution callback. Called exactly once with the user's choice,
    /// or nil if they dismiss without picking. The library view maps
    /// the choice to `applyUpdate(_:, mode:)`.
    public let onResolve: (LibraryStore.UpdateMode?) -> Void

    // MARK: Init

    public init(
        update: AvailableUpdate,
        onResolve: @escaping (LibraryStore.UpdateMode?) -> Void
    ) {
        self.update = update
        self.onResolve = onResolve
    }

    // MARK: Body

    public var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.lg) {
            header
            optionsList
            Spacer(minLength: 0)
            footer
        }
        .padding(MacRoTheme.Spacing.xl)
        .frame(minWidth: 520, minHeight: 420)
        .background(MacRoTheme.Color.bgPage)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            Text("\(update.local.name) has updates available, but you have local edits")
                .font(MacRoTheme.Font.heading1)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: MacRoTheme.Spacing.sm) {
                VersionChip(label: "Your version", version: update.local.version, accent: MacRoTheme.Color.brandMagenta)
                Text("→")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                VersionChip(label: "Remote", version: update.remote.version, accent: MacRoTheme.Color.brandCyan)
            }

            Text("macRo detected changes to your local copy since you installed it. Pick how to handle the update — your edits stay safe unless you choose to overwrite.")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var optionsList: some View {
        VStack(spacing: MacRoTheme.Spacing.sm) {
            OptionRow(
                title: "Keep my version",
                detail: "Skip the update. Your local edits stay intact. We'll re-prompt next time the feed refreshes.",
                accent: MacRoTheme.Color.fg2
            )
            OptionRow(
                title: "Install update",
                detail: "Replace your local copy with the remote version. Your edits will be lost — your previous version IS rotated into rollback storage if you change your mind later.",
                accent: MacRoTheme.Color.stateDanger
            )
            OptionRow(
                title: "Save my copy as new, then install",
                detail: "Duplicate your edited copy as a new macro under a derived id, then install the update over the original. You keep both.",
                accent: MacRoTheme.Color.productTeal
            )
        }
    }

    private var footer: some View {
        HStack(spacing: MacRoTheme.Spacing.md) {
            SecondaryButton(title: "Cancel") {
                onResolve(nil)
            }
            Spacer()
            SecondaryButton(title: "Keep my version") {
                onResolve(.keepLocal)
            }
            SecondaryButton(title: "Save copy + install") {
                onResolve(.saveLocalAsNew)
            }
            DestructiveButton(title: "Install update") {
                onResolve(.overwrite)
            }
        }
    }
}

// MARK: - Row + chip subviews

private struct VersionChip: View {
    let label: String
    let version: String
    let accent: SwiftUI.Color

    var body: some View {
        HStack(spacing: MacRoTheme.Spacing.xs) {
            Text(label.uppercased())
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("v\(version)")
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg1)
        }
        .padding(.horizontal, MacRoTheme.Spacing.md)
        .padding(.vertical, MacRoTheme.Spacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                .fill(MacRoTheme.Color.bgRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                .strokeBorder(accent.opacity(0.6), lineWidth: 1)
        )
    }
}

private struct OptionRow: View {
    let title: String
    let detail: String
    let accent: SwiftUI.Color

    var body: some View {
        HStack(alignment: .top, spacing: MacRoTheme.Spacing.md) {
            // Accent bar — visual hierarchy across three options without
            // turning the row into a button (the Cancel/Action buttons
            // live in the footer; rows are explanatory).
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text(title)
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(detail)
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(MacRoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                .fill(MacRoTheme.Color.bgSurface)
        )
    }
}

// MARK: - Buttons

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, MacRoTheme.Spacing.lg)
                .padding(.vertical, MacRoTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            hovering
                                ? MacRoTheme.Color.brandCyan
                                : MacRoTheme.Color.fg3,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct DestructiveButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .padding(.horizontal, MacRoTheme.Spacing.lg)
                .padding(.vertical, MacRoTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                        .fill(MacRoTheme.Color.stateDanger.opacity(hovering ? 0.92 : 1.0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    let local = LibraryEntry(
        id: "ps99-auto-hatch-v1",
        name: "Auto Hatch",
        game: "pet-sim-99",
        version: "1.0.0",
        source: .local,
        factoryPatchable: true,
        lastUpdated: Date(),
        bundleURL: URL(fileURLWithPath: "/tmp/preview.macro")
    )
    let remote = RemoteEntry(
        id: "ps99-auto-hatch-v1",
        name: "Auto Hatch",
        game: "pet-sim-99",
        version: "1.2.0",
        downloadURL: URL(string: "https://macros.626labs.com/ps99-auto-hatch-v1-1.2.0.zip")!,
        sha256: "deadbeef",
        factoryPatchable: true,
        lastUpdated: Date()
    )
    let update = AvailableUpdate(local: local, remote: remote, drifted: true)
    return UpdateDriftPrompt(update: update, onResolve: { _ in })
}
