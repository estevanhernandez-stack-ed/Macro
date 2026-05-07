// LibraryViewModel.swift
// UI — pure-data view-model for `LibraryView`.
//
// Why a separate model: SwiftUI views are awkward to unit-test, but the
// dedup-by-id and filter-by-game-slug logic is the load-bearing layer
// that decides what cards render. Extracting it to a value-typed model
// gives us testable seams without poking at private View state.
//
// `LibraryView` constructs a `LibraryViewModel` from the live
// `LibraryStore` on every render — the model is cheap (it's two arrays
// and a string) and re-derivation is the SwiftUI-native pattern.
//
// Spec ref: docs/spec.md > LibraryView (card grid, filter chips, source
// badge). Voice: builder-to-builder, sentence case, no emoji.

import Foundation

/// One renderable card on `LibraryView`. Either a fully installed local
/// macro, or a remote feed entry that the user hasn't installed yet.
/// `local` wins on id collision — the user's installed copy is the one
/// they care about; the remote entry is the future-state.
public enum LibraryCard: Hashable, Identifiable {
    case local(LibraryEntry)
    case remoteOnly(RemoteEntry)

    public var id: String {
        switch self {
        case .local(let entry):    return "local:\(entry.id)"
        case .remoteOnly(let r):   return "remote:\(r.id)"
        }
    }

    /// macro id — same across local + remote when both exist (we just
    /// dedup'd them so only one card shows up).
    public var macroId: String {
        switch self {
        case .local(let entry):    return entry.id
        case .remoteOnly(let r):   return r.id
        }
    }

    public var name: String {
        switch self {
        case .local(let entry):    return entry.name
        case .remoteOnly(let r):   return r.name
        }
    }

    public var game: String {
        switch self {
        case .local(let entry):    return entry.game
        case .remoteOnly(let r):   return r.game
        }
    }

    public var version: String {
        switch self {
        case .local(let entry):    return entry.version
        case .remoteOnly(let r):   return r.version
        }
    }

    public var factoryPatchable: Bool {
        switch self {
        case .local(let entry):    return entry.factoryPatchable
        case .remoteOnly(let r):   return r.factoryPatchable
        }
    }

    public var lastUpdated: Date {
        switch self {
        case .local(let entry):    return entry.lastUpdated
        case .remoteOnly(let r):   return r.lastUpdated
        }
    }

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

/// Pure-data view-model. No SwiftUI imports — built off whatever inputs
/// the View hands it, returns a sorted/dedup'd list of cards + the set
/// of game slugs available for filtering.
public struct LibraryViewModel: Equatable {

    /// Sentinel filter values. Public so the View + tests can spell them
    /// the same way without re-introducing magic strings.
    public enum FilterSentinel {
        public static let all: String = "__all__"
        public static let untagged: String = LibraryStore.untaggedGameSlug
    }

    public let localEntries: [LibraryEntry]
    public let remoteEntries: [RemoteEntry]
    public let pendingUpdates: [AvailableUpdate]
    /// Filter selection — a game slug, or `FilterSentinel.all` for "All".
    public let gameFilter: String

    public init(
        localEntries: [LibraryEntry],
        remoteEntries: [RemoteEntry],
        pendingUpdates: [AvailableUpdate] = [],
        gameFilter: String = FilterSentinel.all
    ) {
        self.localEntries = localEntries
        self.remoteEntries = remoteEntries
        self.pendingUpdates = pendingUpdates
        self.gameFilter = gameFilter
    }

    // MARK: - Derived

    /// All known game slugs across local + remote, sorted A→Z, deduped.
    /// Drives the filter chip row. Always seeds at least
    /// `FilterSentinel.all` (handled by the View, not the model — model
    /// returns just the data).
    public var availableGames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in localEntries where !seen.contains(entry.game) {
            seen.insert(entry.game)
            out.append(entry.game)
        }
        for remote in remoteEntries where !seen.contains(remote.game) {
            seen.insert(remote.game)
            out.append(remote.game)
        }
        return out.sorted()
    }

    /// Unified card list — local ∪ remote, dedup'd by macro id (local
    /// wins). Filtered by `gameFilter`. Sorted by game then name so the
    /// grid reads predictably across re-renders.
    public var cards: [LibraryCard] {
        var byId: [String: LibraryCard] = [:]

        for remote in remoteEntries {
            byId[remote.id] = .remoteOnly(remote)
        }
        // Locals overwrite — local always wins on id collision.
        for local in localEntries {
            byId[local.id] = .local(local)
        }

        let unfiltered = Array(byId.values)
        let filtered: [LibraryCard]
        switch gameFilter {
        case FilterSentinel.all:
            filtered = unfiltered
        default:
            filtered = unfiltered.filter { $0.game == gameFilter }
        }

        return filtered.sorted { lhs, rhs in
            if lhs.game != rhs.game { return lhs.game < rhs.game }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.macroId < rhs.macroId
        }
    }

    /// Is this card the empty-state? True iff local + remote are both
    /// empty (regardless of filter). Used by the View to flip into the
    /// hero empty-state panel.
    public var isEmpty: Bool {
        localEntries.isEmpty && remoteEntries.isEmpty
    }

    /// Pending update for a given local entry id, if any.
    public func pendingUpdate(forMacroId id: String) -> AvailableUpdate? {
        pendingUpdates.first(where: { $0.id == id })
    }
}
