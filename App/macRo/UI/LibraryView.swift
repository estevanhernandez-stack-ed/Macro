// LibraryView.swift
// UI — unified card grid + filter chips + empty/no-network states.
//
// Item 9c surface. Reads `LibraryStore.shared` (an `@Observable`
// singleton); SwiftUI tracks the dependencies that get touched in
// `body`. Layout follows the v1 design spec — top bar with feed status
// chip + refresh + settings, filter row with game-slug chips, card grid
// (LazyVGrid adaptive ~260pt min), per-card primary action that varies
// with the card's source + pending-update state.
//
// Modal sheets:
//   • UpdateDriftPrompt  — when the user hits "Update (drift)" on a
//     drifted local; resolves to LibraryStore.UpdateMode.
//   • LibrarySettingsView — feed URL override + per-macro auto-update
//     toggles.
//
// All visuals route through `MacRoTheme`. No hardcoded colors / fonts /
// spacing. Threading: SwiftUI body runs on main; long-running work
// (refreshRemoteCatalog, install, applyUpdate, delete, rollback) hops
// onto the engine queue inside the store via `Task { … }`.
//
// Spec ref: docs/spec.md > LibraryView + docs/prd.md > Epic E.

import AppKit
import SwiftUI

// MARK: - LibraryView

/// The top-level Library surface. Mounted in `ContentView` post-
/// onboarding when the user has `permissions.allGranted`.
struct LibraryView: View {

    /// Live store — single source of truth. `@Bindable` lets us pass
    /// bindings down (e.g., to the settings sheet).
    @Bindable var store: LibraryStore = .shared

    /// Filter chip selection. `FilterSentinel.all` = no filter.
    @State private var gameFilter: String = LibraryViewModel.FilterSentinel.all

    /// Pending drift-prompt (drives `.sheet(item:)`).
    @State private var driftPromptUpdate: AvailableUpdate? = nil

    /// Pending delete confirmation.
    @State private var pendingDelete: LibraryEntry? = nil

    /// Settings sheet visibility.
    @State private var showingSettings: Bool = false

    /// Last surfaced error (non-modal toast in the top bar).
    @State private var transientError: String? = nil

    var body: some View {
        let model = LibraryViewModel(
            localEntries: store.localEntries,
            remoteEntries: store.remoteEntries,
            pendingUpdates: store.pendingUpdates,
            gameFilter: gameFilter
        )

        VStack(alignment: .leading, spacing: 0) {
            topBar
            Divider().background(MacRoTheme.Color.laneBorder)
            filterRow(model: model)
            Divider().background(MacRoTheme.Color.laneBorder)

            if model.isEmpty {
                emptyState
            } else {
                gridScroll(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacRoTheme.Color.bgPage)
        .task {
            // Bootstrap + first-load. `try?` because bootstrap throwing
            // is genuinely a "library directory unreachable" disk error
            // — not actionable from this view, surfaced via store.lastError.
            try? store.bootstrapLibraryDirectory()
            await store.reloadLocalInventory()
            await store.refreshRemoteCatalog()
            await store.checkForUpdates()
        }
        .sheet(item: $driftPromptUpdate) { update in
            UpdateDriftPrompt(update: update) { mode in
                let updateRef = update
                driftPromptUpdate = nil
                guard let mode else { return }
                Task {
                    do {
                        try await store.applyUpdate(updateRef, mode: mode)
                    } catch {
                        transientError = error.localizedDescription
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            LibrarySettingsView(store: store)
        }
        .alert(item: $pendingDelete) { entry in
            Alert(
                title: Text("Delete \"\(entry.name)\"?"),
                message: Text("Removes the bundle, the install hash sidecar, and any rollback versions. This cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    Task {
                        do {
                            try await store.delete(entry)
                        } catch {
                            transientError = error.localizedDescription
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: MacRoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                    .font(MacRoTheme.Font.heading1)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(libraryCountSummary)
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }

            Spacer()

            FeedStatusChip(reachable: store.feedReachable)

            IconButton(systemName: "arrow.clockwise", help: "Refresh feed") {
                Task {
                    await store.refreshRemoteCatalog()
                    await store.checkForUpdates()
                }
            }

            IconButton(systemName: "gearshape", help: "Library Settings…") {
                showingSettings = true
            }
        }
        .padding(.horizontal, MacRoTheme.Spacing.lg)
        .padding(.vertical, MacRoTheme.Spacing.md)
        .background(MacRoTheme.Color.bgSurface)
        .overlay(alignment: .bottom) {
            if let transientError {
                Text(transientError)
                    .font(MacRoTheme.Font.monoMicro)
                    .foregroundStyle(MacRoTheme.Color.stateDanger)
                    .padding(.horizontal, MacRoTheme.Spacing.lg)
                    .padding(.vertical, MacRoTheme.Spacing.xs)
                    .onTapGesture { self.transientError = nil }
            }
        }
    }

    private var libraryCountSummary: String {
        let local = store.localEntries.count
        let remote = store.remoteEntries.count
        let pending = store.pendingUpdates.count
        var pieces: [String] = []
        pieces.append("\(local) installed")
        if remote > 0 { pieces.append("\(remote) on feed") }
        if pending > 0 { pieces.append("\(pending) update\(pending == 1 ? "" : "s") available") }
        return pieces.joined(separator: " · ")
    }

    // MARK: - Filter row

    private func filterRow(model: LibraryViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MacRoTheme.Spacing.sm) {
                FilterChip(
                    label: "All",
                    isActive: gameFilter == LibraryViewModel.FilterSentinel.all
                ) { gameFilter = LibraryViewModel.FilterSentinel.all }

                ForEach(model.availableGames, id: \.self) { slug in
                    FilterChip(
                        label: prettyGameLabel(slug),
                        isActive: gameFilter == slug
                    ) { gameFilter = slug }
                }
            }
            .padding(.horizontal, MacRoTheme.Spacing.lg)
            .padding(.vertical, MacRoTheme.Spacing.sm)
        }
        .background(MacRoTheme.Color.bgPage)
    }

    /// Map a game slug → display label. Special-cases a few well-known
    /// slugs; falls back to a title-cased version of the slug.
    private func prettyGameLabel(_ slug: String) -> String {
        switch slug {
        case "pet-sim-99":              return "Pet Simulator 99"
        case LibraryStore.untaggedGameSlug: return "Untagged"
        default:
            return slug.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        }
    }

    // MARK: - Card grid

    private func gridScroll(model: LibraryViewModel) -> some View {
        ScrollView {
            // The card grid + empty-no-network caption sit in a single
            // VStack so the caption (when feed is unreachable) appears
            // directly above the cards rather than floating.
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
                if !store.feedReachable {
                    Text("Showing local macros only — pull to refresh when you're back online.")
                        .font(MacRoTheme.Font.bodySmall)
                        .foregroundStyle(MacRoTheme.Color.fg3)
                        .padding(.horizontal, MacRoTheme.Spacing.lg)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: MacRoTheme.Spacing.md, alignment: .top)],
                    alignment: .leading,
                    spacing: MacRoTheme.Spacing.md
                ) {
                    ForEach(model.cards) { card in
                        cardView(card: card, model: model)
                    }
                }
                .padding(MacRoTheme.Spacing.lg)
            }
        }
    }

    @ViewBuilder
    private func cardView(card: LibraryCard, model: LibraryViewModel) -> some View {
        let pending: AvailableUpdate? = {
            switch card {
            case .local(let entry): return model.pendingUpdate(forMacroId: entry.id)
            case .remoteOnly:       return nil
            }
        }()

        LibraryCardView(
            card: card,
            pendingUpdate: pending,
            prettyGameLabel: prettyGameLabel(card.game),
            onPrimaryAction: { handlePrimary(card: card, pending: pending) }
        )
        .contextMenu {
            cardContextMenu(card: card)
        }
    }

    @ViewBuilder
    private func cardContextMenu(card: LibraryCard) -> some View {
        switch card {
        case .local(let entry):
            Button("Open in Editor") { EditorWindow.show(bundleURL: entry.bundleURL) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.bundleURL])
            }
            Divider()
            Button(autoUpdateMenuLabel(for: entry)) {
                let current = store.isAutoUpdateDisabled(for: entry.id)
                store.setAutoUpdateDisabled(!current, for: entry.id)
            }
            let versions = store.availableRollbackVersions(for: entry)
            if !versions.isEmpty {
                Menu("Rollback to…") {
                    ForEach(versions) { version in
                        Button("v\(version.version)") {
                            Task {
                                do {
                                    try await store.rollback(entry, to: version)
                                } catch {
                                    transientError = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                pendingDelete = entry
            }

        case .remoteOnly(let remote):
            Button("Install") {
                Task {
                    do {
                        try await store.install(remote)
                    } catch {
                        transientError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func autoUpdateMenuLabel(for entry: LibraryEntry) -> String {
        return store.isAutoUpdateDisabled(for: entry.id)
            ? "Enable auto-update"
            : "Disable auto-update"
    }

    private func handlePrimary(card: LibraryCard, pending: AvailableUpdate?) {
        switch card {
        case .local(let entry):
            if let pending {
                if pending.drifted {
                    driftPromptUpdate = pending
                } else {
                    Task {
                        do {
                            try await store.applyUpdate(pending, mode: .overwrite)
                        } catch {
                            transientError = error.localizedDescription
                        }
                    }
                }
                return
            }
            // No pending update — Run.
            runEntry(entry)

        case .remoteOnly(let remote):
            Task {
                do {
                    try await store.install(remote)
                } catch {
                    transientError = error.localizedDescription
                }
            }
        }
    }

    /// Load + run a local entry via `Engine.shared.run`. Errors flip the
    /// transient-error toast; the engine's RunHUD handles its own UI
    /// surface from there.
    private func runEntry(_ entry: LibraryEntry) {
        Task {
            do {
                let bundle = try MacroBundle.load(at: entry.bundleURL)
                try await Engine.shared.run(bundle)
            } catch {
                transientError = error.localizedDescription
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: MacRoTheme.Spacing.lg) {
            Spacer()

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [MacRoTheme.Color.brandCyan, MacRoTheme.Color.brandMagenta],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .frame(width: 64, height: 64)

            VStack(spacing: MacRoTheme.Spacing.xs) {
                Text("No macros yet")
                    .font(MacRoTheme.Font.heading1)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text("Record your first macro or refresh the feed to browse community macros.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: MacRoTheme.Spacing.md) {
                EmptyStateButton(title: "Start Recording", isPrimary: true) {
                    NotificationCenter.default.post(
                        name: LibraryView.startRecordingRequested,
                        object: nil
                    )
                }
                EmptyStateButton(title: "Refresh feed", isPrimary: false) {
                    Task {
                        await store.refreshRemoteCatalog()
                        await store.checkForUpdates()
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MacRoTheme.Spacing.xl)
        .background(MacRoTheme.Color.bgPage)
    }

    /// Notification fired when the empty-state CTA wants to start
    /// recording. `ContentView` is the natural listener (it owns the
    /// game-pick → countdown → recorder chain). Public + static so
    /// observers can match on the same name.
    static let startRecordingRequested = Notification.Name("macRo.LibraryView.startRecordingRequested")
}

// MARK: - Card view

private struct LibraryCardView: View {

    let card: LibraryCard
    let pendingUpdate: AvailableUpdate?
    let prettyGameLabel: String
    let onPrimaryAction: () -> Void

    @State private var hovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            header
            tagsRow
            Spacer(minLength: MacRoTheme.Spacing.sm)
            footerRow
        }
        .padding(MacRoTheme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                .fill(MacRoTheme.Color.bgSurface.opacity(hovering ? 0.92 : 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                .strokeBorder(MacRoTheme.Color.laneBorder, lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.name)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .lineLimit(2)

            Text(prettyGameLabel)
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
        }
    }

    // MARK: Tags

    private var tagsRow: some View {
        HStack(spacing: MacRoTheme.Spacing.xs) {
            SourceBadge(isLocal: card.isLocal)
            VersionBadge(version: card.version)
            if card.factoryPatchable {
                FactoryChip()
            }
            if let pendingUpdate, pendingUpdate.drifted {
                DriftChip()
            }
            Spacer()
        }
    }

    // MARK: Footer

    private var footerRow: some View {
        HStack {
            Text(relativeUpdated)
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Spacer()
            primaryButton
        }
    }

    private var primaryButton: some View {
        Button(action: onPrimaryAction) {
            Text(primaryLabel)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(primaryFg)
                .padding(.horizontal, MacRoTheme.Spacing.md)
                .padding(.vertical, MacRoTheme.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                        .fill(primaryBg)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var primaryLabel: String {
        switch card {
        case .local:
            if let pendingUpdate {
                return pendingUpdate.drifted ? "Update (drift)" : "Update available"
            }
            return "Run"
        case .remoteOnly:
            return "Install"
        }
    }

    private var primaryFg: SwiftUI.Color {
        switch card {
        case .local where pendingUpdate?.drifted == true: return MacRoTheme.Color.fg1
        default: return MacRoTheme.Color.bgPage
        }
    }

    private var primaryBg: SwiftUI.Color {
        switch card {
        case .local:
            if let pendingUpdate {
                return pendingUpdate.drifted
                    ? MacRoTheme.Color.stateDanger
                    : MacRoTheme.Color.brandCyan
            }
            return MacRoTheme.Color.productTeal
        case .remoteOnly:
            return MacRoTheme.Color.brandCyan
        }
    }

    private var relativeUpdated: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: card.lastUpdated, relativeTo: Date())
            .uppercased()
    }
}

// MARK: - Subviews

private struct FeedStatusChip: View {
    let reachable: Bool

    var body: some View {
        HStack(spacing: MacRoTheme.Spacing.xs) {
            Circle()
                .fill(reachable ? MacRoTheme.Color.stateOk : MacRoTheme.Color.stateWarn)
                .frame(width: 8, height: 8)
            Text(reachable ? "Feed connected" : "Feed unavailable")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(reachable ? MacRoTheme.Color.stateOk : MacRoTheme.Color.stateWarn)
        }
        .padding(.horizontal, MacRoTheme.Spacing.sm)
        .padding(.vertical, MacRoTheme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.pill, style: .continuous)
                .fill(MacRoTheme.Color.bgRaised)
        )
    }
}

private struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MacRoTheme.Color.fg2)
                .padding(MacRoTheme.Spacing.sm)
                .background(
                    Circle().fill(
                        hovering
                            ? MacRoTheme.Color.bgRaised
                            : MacRoTheme.Color.bgRaised.opacity(0.6)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct FilterChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(isActive ? MacRoTheme.Color.bgPage : MacRoTheme.Color.fg2)
                .padding(.horizontal, MacRoTheme.Spacing.md)
                .padding(.vertical, MacRoTheme.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.pill, style: .continuous)
                        .fill(
                            isActive
                                ? MacRoTheme.Color.productTeal
                                : MacRoTheme.Color.bgRaised.opacity(hovering ? 0.92 : 1.0)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SourceBadge: View {
    let isLocal: Bool

    var body: some View {
        Text(isLocal ? "LOCAL" : "REMOTE")
            .font(MacRoTheme.Font.monoMicro)
            .tracking(0.12 * 11)
            .foregroundStyle(isLocal ? MacRoTheme.Color.brandCyan : MacRoTheme.Color.brandMagenta)
            .padding(.horizontal, MacRoTheme.Spacing.sm)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                    .strokeBorder(
                        (isLocal ? MacRoTheme.Color.brandCyan : MacRoTheme.Color.brandMagenta).opacity(0.6),
                        lineWidth: 1
                    )
            )
    }
}

private struct VersionBadge: View {
    let version: String

    var body: some View {
        Text("v\(version)")
            .font(MacRoTheme.Font.monoMicro)
            .foregroundStyle(MacRoTheme.Color.fg2)
            .padding(.horizontal, MacRoTheme.Spacing.sm)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                    .fill(MacRoTheme.Color.bgRaised)
            )
    }
}

private struct FactoryChip: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 9, weight: .semibold))
            Text("FACTORY")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
        }
        .foregroundStyle(MacRoTheme.Color.productTeal)
        .padding(.horizontal, MacRoTheme.Spacing.sm)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                .strokeBorder(MacRoTheme.Color.productTeal.opacity(0.6), lineWidth: 1)
        )
    }
}

private struct DriftChip: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("DRIFT")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
        }
        .foregroundStyle(MacRoTheme.Color.stateDanger)
        .padding(.horizontal, MacRoTheme.Spacing.sm)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                .strokeBorder(MacRoTheme.Color.stateDanger.opacity(0.6), lineWidth: 1)
        )
    }
}

private struct EmptyStateButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.body)
                .foregroundStyle(isPrimary ? MacRoTheme.Color.bgPage : MacRoTheme.Color.fg1)
                .padding(.horizontal, MacRoTheme.Spacing.lg)
                .padding(.vertical, MacRoTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                        .fill(
                            isPrimary
                                ? MacRoTheme.Color.productTeal.opacity(hovering ? 0.92 : 1.0)
                                : MacRoTheme.Color.bgRaised.opacity(hovering ? 0.92 : 1.0)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            isPrimary ? Color.clear : MacRoTheme.Color.fg3.opacity(0.3),
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Identifiable conformance for `.alert(item:)` on LibraryEntry
// LibraryEntry already conforms to Identifiable via its `id: String` field.
// Kept here as a comment so future readers don't try to add a wrapper.

#Preview {
    LibraryView()
        .frame(width: 1100, height: 700)
}
