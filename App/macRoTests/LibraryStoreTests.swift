// LibraryStoreTests.swift
// 9a — LibraryStore core (bootstrap + reload + delete).
//
// Strategy:
//   • Each test gets a unique tmp dir as the library root via
//     `LibraryStore.libraryRootOverride`. Tests MUST NOT touch the real
//     `~/Library/Application Support/macRo/Library/`.
//   • Fixture copy: bundles come from `App/macRoTests/Fixtures/` resolved
//     relative to `#filePath` (same trick MacroBundleTests uses).
//   • The store is `@MainActor`; tests are too via `@MainActor func`.

import XCTest
@testable import macRo

@MainActor
final class LibraryStoreTests: XCTestCase {

    // MARK: - Per-test scratch root

    /// Unique tmp library root for the current test. Reset before/after
    /// each test so cases don't leak fixtures into one another.
    private var scratchRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macRoTests-LibraryStore-\(UUID().uuidString)", isDirectory: true)
        LibraryStore.libraryRootOverride = scratchRoot

        // Reset shared store state — `LibraryStore.shared` survives across
        // tests in the same process; clear the in-memory inventory so
        // assertions don't see leftovers from a prior test.
        await LibraryStore.shared.reloadLocalInventory()
    }

    override func tearDown() async throws {
        if let scratchRoot, FileManager.default.fileExists(atPath: scratchRoot.path) {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
        LibraryStore.libraryRootOverride = nil
        try await super.tearDown()
    }

    // MARK: - Fixture path

    /// Repo-relative path to the hand-authored test fixtures (item 6).
    /// Same `#filePath` trick MacroBundleTests uses — works across
    /// xcodebuild test + the Xcode IDE runner.
    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    // MARK: - Tests

    func testBootstrapCreatesEmptyLibraryDirectory() throws {
        let store = LibraryStore.shared
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchRoot.path),
                       "scratch root should not exist before bootstrap")

        try store.bootstrapLibraryDirectory()

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: scratchRoot.path,
            isDirectory: &isDir
        )
        XCTAssertTrue(exists)
        XCTAssertTrue(isDir.boolValue)

        let contents = try FileManager.default.contentsOfDirectory(
            at: scratchRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.count, 0, "fresh library should be empty")

        // Idempotent — second call must not throw.
        XCTAssertNoThrow(try store.bootstrapLibraryDirectory())
    }

    func testReloadLocalInventoryReadsExistingFixtures() async throws {
        let store = LibraryStore.shared
        try store.bootstrapLibraryDirectory()

        // Stage tiny-click-loop.macro under pet-sim-99/.
        let fm = FileManager.default
        let gameDir = scratchRoot.appendingPathComponent("pet-sim-99", isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let srcBundle = fixturesDir.appendingPathComponent("tiny-click-loop.macro", isDirectory: true)
        let dstBundle = gameDir.appendingPathComponent("tiny-click-loop.macro", isDirectory: true)
        try fm.copyItem(at: srcBundle, to: dstBundle)

        // Also drop a sibling `.versions/` to confirm the walker skips it.
        let versionsDir = scratchRoot
            .appendingPathComponent(LibraryStore.versionsDirectoryName, isDirectory: true)
        try fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        await store.reloadLocalInventory()

        XCTAssertEqual(store.localEntries.count, 1, "expected exactly one entry from staged fixture")
        let entry = try XCTUnwrap(store.localEntries.first)
        XCTAssertEqual(entry.id, "fixture-tiny-click-loop")
        XCTAssertEqual(entry.name, "Tiny click loop")
        XCTAssertEqual(entry.version, "1.0.0")
        XCTAssertEqual(entry.game, "pet-sim-99")
        XCTAssertEqual(entry.source, .local)
        XCTAssertFalse(entry.factoryPatchable)
        // macOS symlinks /var → /private/var; FileManager enumeration
        // resolves the prefix, so compare via standardized paths.
        XCTAssertEqual(entry.bundleURL.standardizedFileURL.path,
                       dstBundle.standardizedFileURL.path)
    }

    func testDeleteRemovesBundleDir() async throws {
        let store = LibraryStore.shared
        try store.bootstrapLibraryDirectory()

        // Stage a bundle to delete.
        let fm = FileManager.default
        let gameDir = scratchRoot.appendingPathComponent("pet-sim-99", isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let srcBundle = fixturesDir.appendingPathComponent("tiny-click-loop.macro", isDirectory: true)
        let dstBundle = gameDir.appendingPathComponent("tiny-click-loop.macro", isDirectory: true)
        try fm.copyItem(at: srcBundle, to: dstBundle)

        // Drop a forward-compat sidecar + a versions subtree so we can
        // confirm `delete(_:)` scrubs them too (9b's plumbing).
        let sidecarURL = LibraryStore.installHashSidecarURL(forBundle: dstBundle)
        try Data("dummy-hash".utf8).write(to: sidecarURL)
        let versionsSubtree = scratchRoot
            .appendingPathComponent(LibraryStore.versionsDirectoryName, isDirectory: true)
            .appendingPathComponent("pet-sim-99", isDirectory: true)
            .appendingPathComponent("fixture-tiny-click-loop", isDirectory: true)
        try fm.createDirectory(at: versionsSubtree, withIntermediateDirectories: true)
        try Data().write(to: versionsSubtree.appendingPathComponent("v1.placeholder"))

        await store.reloadLocalInventory()
        let entry = try XCTUnwrap(store.localEntries.first)

        try await store.delete(entry)

        XCTAssertFalse(fm.fileExists(atPath: dstBundle.path), "bundle dir should be gone")
        XCTAssertFalse(fm.fileExists(atPath: sidecarURL.path), "sidecar should be gone")
        XCTAssertFalse(fm.fileExists(atPath: versionsSubtree.path), "versions subtree should be gone")
        XCTAssertEqual(store.localEntries.count, 0, "inventory should be empty after delete")
    }

    // MARK: - 9b — install / drift / rollback

    /// Build a `RemoteEntry` whose downloadURL is a `file://` pointing at
    /// a zip we just authored — keeps the install path real (URLSession +
    /// /usr/bin/unzip + sha256) while staying offline.
    private func makeRemoteEntry(
        id: String,
        version: String,
        zipURL: URL,
        zipBytes: Data,
        factoryPatchable: Bool = true,
        game: String = "pet-sim-99"
    ) -> RemoteEntry {
        return RemoteEntry(
            id: id,
            name: id.replacingOccurrences(of: "-", with: " "),
            game: game,
            version: version,
            downloadURL: zipURL,
            sha256: LibraryStore.sha256Hex(zipBytes),
            factoryPatchable: factoryPatchable,
            lastUpdated: Date()
        )
    }

    /// Zip the fixture bundle so the install path can unzip it. Uses
    /// /usr/bin/zip — installed on every macOS host. Returns (zipURL, zipBytes).
    private func zipFixtureBundle(
        bundleId: String,
        targetVersion: String? = nil
    ) throws -> (URL, Data) {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("macRoTests-zip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        // Stage a copy of tiny-click-loop.macro under <bundleId>.macro so
        // the unzip locator picks it up cleanly.
        let stagedBundle = workDir.appendingPathComponent("\(bundleId).macro", isDirectory: true)
        let srcBundle = fixturesDir.appendingPathComponent("tiny-click-loop.macro", isDirectory: true)
        try fm.copyItem(at: srcBundle, to: stagedBundle)

        // Rewrite manifest id + (optionally) version so the zip behaves
        // like a real remote macro.
        let manifestURL = stagedBundle.appendingPathComponent("manifest.yaml")
        var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        manifest = manifest.replacingOccurrences(
            of: "id: fixture-tiny-click-loop",
            with: "id: \(bundleId)"
        )
        if let targetVersion {
            manifest = manifest.replacingOccurrences(
                of: "version: 1.0.0",
                with: "version: \(targetVersion)"
            )
        }
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        // /usr/bin/zip works in cwd — chdir to the workDir so the zip
        // entries are relative (`<bundleId>.macro/...`).
        let zipURL = workDir.appendingPathComponent("\(bundleId).zip")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = workDir
        task.arguments = ["-rq", zipURL.path, "\(bundleId).macro"]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "zip should succeed")

        let zipBytes = try Data(contentsOf: zipURL)
        return (zipURL, zipBytes)
    }

    func testInstallWithValidHashSucceeds() async throws {
        let store = LibraryStore.shared
        try store.bootstrapLibraryDirectory()

        let bundleId = "remote-fixture-a"
        let (zipURL, zipBytes) = try zipFixtureBundle(bundleId: bundleId)
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }

        let remote = makeRemoteEntry(
            id: bundleId,
            version: "1.0.0",
            zipURL: zipURL,
            zipBytes: zipBytes
        )

        try await store.install(remote)

        let installedURL = scratchRoot
            .appendingPathComponent("pet-sim-99", isDirectory: true)
            .appendingPathComponent("\(bundleId).macro", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path),
                      "bundle should land under <game>/<id>.macro")

        let sidecar = LibraryStore.installHashSidecarURL(forBundle: installedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path),
                      "install hash sidecar should exist")
        let sidecarHash = try String(contentsOf: sidecar, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedSidecarHash = try LibraryStore.canonicalBundleHash(at: installedURL)
        XCTAssertEqual(sidecarHash, expectedSidecarHash,
                       "sidecar should match canonical bundle hash")

        XCTAssertTrue(store.localEntries.contains { $0.id == bundleId },
                      "store inventory should include installed bundle")
    }

    func testInstallWithHashMismatchThrowsAndLeavesLibraryUntouched() async throws {
        let store = LibraryStore.shared
        try store.bootstrapLibraryDirectory()

        let bundleId = "remote-fixture-mismatch"
        let (zipURL, zipBytes) = try zipFixtureBundle(bundleId: bundleId)
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }

        // Bogus expected hash — will not match the actual SHA-256 of the
        // zip bytes. zipBytes is unused except to confirm the helper path.
        _ = zipBytes
        let remote = RemoteEntry(
            id: bundleId,
            name: "Mismatch fixture",
            game: "pet-sim-99",
            version: "1.0.0",
            downloadURL: zipURL,
            sha256: String(repeating: "0", count: 64),
            factoryPatchable: true,
            lastUpdated: Date()
        )

        let libraryGameDir = scratchRoot.appendingPathComponent("pet-sim-99", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryGameDir, withIntermediateDirectories: true)
        let installedURL = libraryGameDir.appendingPathComponent("\(bundleId).macro", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path),
                       "bundle dir must not exist pre-install")

        do {
            try await store.install(remote)
            XCTFail("install should throw on hash mismatch")
        } catch let error as LibraryError {
            switch error {
            case .hashMismatch: break
            default: XCTFail("expected .hashMismatch, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path),
                       "library should be untouched after hash mismatch")
        let sidecar = LibraryStore.installHashSidecarURL(forBundle: installedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "no sidecar should exist on a failed install")
    }

    func testDriftDetectionTrueAfterManualEdit() async throws {
        let store = LibraryStore.shared
        try store.bootstrapLibraryDirectory()

        // Install v1.0.0 cleanly.
        let bundleId = "remote-fixture-drift"
        let (zipURL, zipBytes) = try zipFixtureBundle(bundleId: bundleId)
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }
        let remote = makeRemoteEntry(
            id: bundleId,
            version: "1.0.0",
            zipURL: zipURL,
            zipBytes: zipBytes
        )
        try await store.install(remote)

        let installedURL = scratchRoot
            .appendingPathComponent("pet-sim-99", isDirectory: true)
            .appendingPathComponent("\(bundleId).macro", isDirectory: true)

        // Sanity: sidecar matches active bundle hash, no drift yet.
        let sidecarPath = LibraryStore.installHashSidecarURL(forBundle: installedURL)
        let initialSidecar = try String(contentsOf: sidecarPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialHash = try LibraryStore.canonicalBundleHash(at: installedURL)
        XCTAssertEqual(initialSidecar, initialHash, "no drift right after install")

        // Manually mutate manifest.yaml — simulates the user editing the
        // macro post-install.
        let manifestURL = installedURL.appendingPathComponent("manifest.yaml")
        var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        manifest += "\n# locally edited at \(Date())\n"
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        // Stage a "newer" remote in the feed so checkForUpdates fires.
        let (newZipURL, newZipBytes) = try zipFixtureBundle(
            bundleId: bundleId,
            targetVersion: "1.1.0"
        )
        defer { try? FileManager.default.removeItem(at: newZipURL.deletingLastPathComponent()) }
        let newer = makeRemoteEntry(
            id: bundleId,
            version: "1.1.0",
            zipURL: newZipURL,
            zipBytes: newZipBytes
        )

        // Hand-stuff the remoteEntries via a feed-stub: write a JSON feed
        // to a file and refresh from it.
        let feedURL = scratchRoot.appendingPathComponent("feed.json")
        let feedJSON: [String: Any] = [
            "entries": [[
                "id": newer.id,
                "name": newer.name,
                "game": newer.game,
                "version": newer.version,
                "downloadURL": newer.downloadURL.absoluteString,
                "sha256": newer.sha256,
                "factoryPatchable": newer.factoryPatchable,
                "lastUpdated": ISO8601DateFormatter().string(from: newer.lastUpdated)
            ]]
        ]
        let feedData = try JSONSerialization.data(withJSONObject: feedJSON, options: [.prettyPrinted])
        try feedData.write(to: feedURL)

        // Point the store at our local-test feed.
        store.feedURL = feedURL
        await store.refreshRemoteCatalog()
        XCTAssertTrue(store.feedReachable, "file:// feed should read as reachable")
        XCTAssertEqual(store.remoteEntries.count, 1, "feed should produce exactly one remote entry")

        // Reload local inventory so checkForUpdates sees the post-edit
        // local bundle.
        await store.reloadLocalInventory()
        await store.checkForUpdates()
        XCTAssertEqual(store.pendingUpdates.count, 1, "newer remote should produce a pending update")
        let update = try XCTUnwrap(store.pendingUpdates.first)
        XCTAssertTrue(update.drifted, "manual manifest edit should mark the entry as drifted")

        // Reset the feedURL UserDefaults override the test wrote, so it
        // doesn't leak into other tests in the same process.
        UserDefaults.standard.removeObject(forKey: LibraryStore.Defaults.feedURL)
    }

    func testRollbackReturnsToPriorVersion() async throws {
        let store = LibraryStore.shared
        try store.bootstrapLibraryDirectory()

        // Install v1.0.0.
        let bundleId = "remote-fixture-rollback"
        let (zipV1, bytesV1) = try zipFixtureBundle(bundleId: bundleId, targetVersion: "1.0.0")
        defer { try? FileManager.default.removeItem(at: zipV1.deletingLastPathComponent()) }
        let v1 = makeRemoteEntry(id: bundleId, version: "1.0.0", zipURL: zipV1, zipBytes: bytesV1)
        try await store.install(v1)

        // Stage a v1.1.0 zip + remote, then apply via overwrite to rotate
        // v1.0.0 into .versions/.
        let (zipV2, bytesV2) = try zipFixtureBundle(bundleId: bundleId, targetVersion: "1.1.0")
        defer { try? FileManager.default.removeItem(at: zipV2.deletingLastPathComponent()) }
        let v2 = makeRemoteEntry(id: bundleId, version: "1.1.0", zipURL: zipV2, zipBytes: bytesV2)

        // Build the AvailableUpdate by hand — we don't need to involve the
        // feed for this rollback path test.
        await store.reloadLocalInventory()
        let localV1 = try XCTUnwrap(store.localEntries.first { $0.id == bundleId })
        XCTAssertEqual(localV1.version, "1.0.0")
        let update = AvailableUpdate(local: localV1, remote: v2, drifted: false)
        try await store.applyUpdate(update, mode: .overwrite)

        await store.reloadLocalInventory()
        let localV2 = try XCTUnwrap(store.localEntries.first { $0.id == bundleId })
        XCTAssertEqual(localV2.version, "1.1.0", "active should now be v1.1.0")

        // Confirm v1.0.0 is parked under .versions/.
        let versions = store.availableRollbackVersions(for: localV2)
        XCTAssertEqual(versions.count, 1, "exactly one rotated version should exist")
        let rolled = try XCTUnwrap(versions.first)
        XCTAssertEqual(rolled.version, "1.0.0")

        // Rollback.
        try await store.rollback(localV2, to: rolled)
        await store.reloadLocalInventory()
        let active = try XCTUnwrap(store.localEntries.first { $0.id == bundleId })
        XCTAssertEqual(active.version, "1.0.0", "active should be v1.0.0 after rollback")

        // After rollback, .versions/ should now hold v1.1.0 (the rotation
        // swap put the previous active into storage and consumed the
        // requested version's slot).
        let versionsAfter = store.availableRollbackVersions(for: active)
        XCTAssertEqual(versionsAfter.count, 1, "rollback should leave exactly one rotated version")
        XCTAssertEqual(versionsAfter.first?.version, "1.1.0",
                       "the formerly-active version should now sit in .versions/")
    }
}
