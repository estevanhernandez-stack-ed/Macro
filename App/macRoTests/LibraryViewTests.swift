// LibraryViewTests.swift
// 9c — LibraryViewModel smoke tests + LibraryView init smoke.
//
// Strategy:
//   • Test the dedup-by-id and filter-by-game-slug logic via the
//     extracted `LibraryViewModel` (a value type, no SwiftUI needed).
//   • Verify `LibraryView()` initializes against a configured
//     `LibraryStore` without crashing — catches obvious wiring breaks
//     even though SwiftUI views are awkward to render-test in XCTest.
//
// Spec ref: docs/checklist.md item 9c "at least 1 UI smoke test".

import XCTest
@testable import macRo

@MainActor
final class LibraryViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeLocal(
        id: String,
        name: String = "Local entry",
        game: String = "pet-sim-99",
        version: String = "1.0.0",
        factoryPatchable: Bool = false
    ) -> LibraryEntry {
        LibraryEntry(
            id: id,
            name: name,
            game: game,
            version: version,
            source: .local,
            factoryPatchable: factoryPatchable,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            bundleURL: URL(fileURLWithPath: "/tmp/\(id).macro")
        )
    }

    private func makeRemote(
        id: String,
        name: String = "Remote entry",
        game: String = "pet-sim-99",
        version: String = "1.1.0",
        factoryPatchable: Bool = true
    ) -> RemoteEntry {
        RemoteEntry(
            id: id,
            name: name,
            game: game,
            version: version,
            downloadURL: URL(string: "https://example.com/\(id).zip")!,
            sha256: String(repeating: "a", count: 64),
            factoryPatchable: factoryPatchable,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Dedup

    func testDedupByIdLocalWins() {
        // Same id appears in both local + remote. Expect a single card
        // and `isLocal == true`.
        let model = LibraryViewModel(
            localEntries: [makeLocal(id: "shared", name: "I am local")],
            remoteEntries: [makeRemote(id: "shared", name: "I am remote", version: "2.0.0")]
        )
        XCTAssertEqual(model.cards.count, 1, "duplicate id should produce exactly one card")
        let card = model.cards[0]
        XCTAssertTrue(card.isLocal, "local should win on id collision")
        XCTAssertEqual(card.name, "I am local")
        XCTAssertEqual(card.version, "1.0.0", "card should reflect the LOCAL version, not remote")
    }

    func testDedupKeepsUniqueRemotes() {
        // Local has one entry, remote has two — one shared (local wins),
        // one remote-only (renders).
        let model = LibraryViewModel(
            localEntries: [makeLocal(id: "shared")],
            remoteEntries: [
                makeRemote(id: "shared"),
                makeRemote(id: "remote-only-id", name: "Just on the feed")
            ]
        )
        XCTAssertEqual(model.cards.count, 2)
        XCTAssertEqual(model.cards.map(\.macroId).sorted(), ["remote-only-id", "shared"])
        let remoteOnly = model.cards.first(where: { $0.macroId == "remote-only-id" })!
        XCTAssertFalse(remoteOnly.isLocal)
    }

    // MARK: - Filter

    func testFilterByGameSlug() {
        let model = LibraryViewModel(
            localEntries: [
                makeLocal(id: "a", game: "pet-sim-99"),
                makeLocal(id: "b", game: "untagged")
            ],
            remoteEntries: [
                makeRemote(id: "c", game: "pet-sim-99")
            ],
            gameFilter: "pet-sim-99"
        )
        XCTAssertEqual(model.cards.count, 2, "only pet-sim-99 entries should remain")
        XCTAssertTrue(model.cards.allSatisfy { $0.game == "pet-sim-99" })
    }

    func testFilterAllReturnsEverything() {
        let model = LibraryViewModel(
            localEntries: [makeLocal(id: "a", game: "pet-sim-99")],
            remoteEntries: [makeRemote(id: "b", game: "untagged")],
            gameFilter: LibraryViewModel.FilterSentinel.all
        )
        XCTAssertEqual(model.cards.count, 2)
    }

    func testAvailableGamesIsDedupedAndSorted() {
        let model = LibraryViewModel(
            localEntries: [
                makeLocal(id: "a", game: "pet-sim-99"),
                makeLocal(id: "b", game: "untagged"),
                makeLocal(id: "c", game: "pet-sim-99")
            ],
            remoteEntries: [
                makeRemote(id: "d", game: "untagged"),
                makeRemote(id: "e", game: "another-game")
            ]
        )
        XCTAssertEqual(model.availableGames, ["another-game", "pet-sim-99", "untagged"])
    }

    // MARK: - Empty state

    func testIsEmptyWhenBothLocalsAndRemotesAreEmpty() {
        let model = LibraryViewModel(localEntries: [], remoteEntries: [])
        XCTAssertTrue(model.isEmpty)
    }

    func testIsNotEmptyWhenRemotesExist() {
        let model = LibraryViewModel(
            localEntries: [],
            remoteEntries: [makeRemote(id: "feed-only")]
        )
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.cards.count, 1)
    }

    // MARK: - Pending update lookup

    func testPendingUpdateLookup() {
        let local = makeLocal(id: "shared", version: "1.0.0")
        let remote = makeRemote(id: "shared", version: "1.1.0")
        let pending = AvailableUpdate(local: local, remote: remote, drifted: true)
        let model = LibraryViewModel(
            localEntries: [local],
            remoteEntries: [remote],
            pendingUpdates: [pending]
        )
        let lookup = model.pendingUpdate(forMacroId: "shared")
        XCTAssertNotNil(lookup)
        XCTAssertTrue(lookup?.drifted == true)
        XCTAssertNil(model.pendingUpdate(forMacroId: "missing"))
    }

    // MARK: - View init smoke

    func testLibraryViewInitDoesNotCrash() {
        // SwiftUI views are awkward to render in XCTest without a host;
        // initializing the View struct still exercises @State + property
        // wrappers. If a body-level reference broke (e.g., a token rename
        // in MacRoTheme), this catches the obvious case.
        _ = LibraryView()
    }

    func testLibrarySettingsViewInitDoesNotCrash() {
        _ = LibrarySettingsView(store: LibraryStore.shared)
    }
}
