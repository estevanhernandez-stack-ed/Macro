// PluginLoaderTests.swift
// 10a — PluginLoader core (3-location index + conflict resolution + trust).
//
// Strategy mirrors LibraryStoreTests:
//   • Each test gets unique tmp dirs as bundled / user-installed roots via
//     `PluginLoader.bundledPluginsRootOverride` +
//     `PluginLoader.userInstalledPluginsRootOverride`.
//   • Tests MUST NOT touch the real `Bundle.main.resourceURL/games/` or
//     `~/Library/Application Support/macRo/Plugins/`.
//   • Fixture plugin.yaml files are written into the scratch dirs at test
//     time — keeps the test bundle's flattened resources clean.
//   • The loader is `@MainActor`; tests are too via `@MainActor func`.

import XCTest
@testable import macRo

@MainActor
final class PluginLoaderTests: XCTestCase {

    // MARK: - Per-test scratch roots

    /// Tmp dir used as the bundled-plugins root for the current test.
    private var bundledRoot: URL!
    /// Tmp dir used as the user-installed-plugins root for the current test.
    private var userInstalledRoot: URL!
    /// UserDefaults keys this test wrote — cleaned up in tearDown so flags
    /// don't leak across tests in the same process.
    private var defaultsKeysToCleanup: Set<String> = []

    override func setUp() async throws {
        try await super.setUp()
        let unique = UUID().uuidString
        bundledRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macRoTests-PluginLoader-bundled-\(unique)", isDirectory: true)
        userInstalledRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macRoTests-PluginLoader-user-\(unique)", isDirectory: true)

        PluginLoader.bundledPluginsRootOverride = bundledRoot
        PluginLoader.userInstalledPluginsRootOverride = userInstalledRoot

        // Reset shared loader state — `PluginLoader.shared` survives across
        // tests in the same process; clear in-memory state with an empty
        // index pass against tmp roots that don't exist yet.
        await PluginLoader.shared.loadAll()
    }

    override func tearDown() async throws {
        let fm = FileManager.default
        if let bundledRoot, fm.fileExists(atPath: bundledRoot.path) {
            try? fm.removeItem(at: bundledRoot)
        }
        if let userInstalledRoot, fm.fileExists(atPath: userInstalledRoot.path) {
            try? fm.removeItem(at: userInstalledRoot)
        }
        PluginLoader.bundledPluginsRootOverride = nil
        PluginLoader.userInstalledPluginsRootOverride = nil

        for key in defaultsKeysToCleanup {
            UserDefaults.standard.removeObject(forKey: key)
        }
        defaultsKeysToCleanup.removeAll()

        try await super.tearDown()
    }

    // MARK: - Fixture authoring helpers

    /// Write a minimal valid `plugin.yaml` into `<root>/<id>/plugin.yaml`.
    /// Returns the plugin folder URL. `seedMacros` lets tests inject the
    /// seed-macros[] list without authoring the bundles themselves (10b's
    /// job).
    @discardableResult
    private func writePluginYAML(
        at root: URL,
        id: String,
        displayName: String,
        placeId: Int,
        windowClass: [String] = ["Roblox"],
        windowTitleMatch: String? = nil,
        defaultBindings: [String: String]? = nil,
        seedMacros: [String]? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let pluginDir = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        var yaml = """
        schemaVersion: 1
        id: \(id)
        displayName: "\(displayName)"
        placeId: \(placeId)
        windowClass:
        """
        for cls in windowClass {
            yaml += "\n  - \"\(cls)\""
        }
        if let windowTitleMatch {
            yaml += "\nwindowTitleMatch: \"\(windowTitleMatch)\""
        }
        if let defaultBindings, !defaultBindings.isEmpty {
            yaml += "\ndefaultBindings:"
            for (action, key) in defaultBindings.sorted(by: { $0.key < $1.key }) {
                yaml += "\n  \(action): \"\(key)\""
            }
        }
        if let seedMacros, !seedMacros.isEmpty {
            yaml += "\nseedMacros:"
            for slug in seedMacros {
                yaml += "\n  - \(slug)"
            }
        }
        yaml += "\n"

        let yamlURL = pluginDir.appendingPathComponent(PluginLoader.pluginYamlFilename)
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        return pluginDir
    }

    /// Mark a UserDefaults key for cleanup at the end of the test.
    private func trackDefault(_ key: String) {
        defaultsKeysToCleanup.insert(key)
    }

    // MARK: - Required tests

    /// Bundled discovery walks the override directory and finds the
    /// fixture plugin.
    func testBundledDiscoveryFindsFixturePlugin() async throws {
        try writePluginYAML(
            at: bundledRoot,
            id: "pet-sim-99",
            displayName: "Pet Simulator 99",
            placeId: 8737899170,
            windowClass: ["Roblox"],
            windowTitleMatch: "Pet Simulator 99|Roblox",
            defaultBindings: ["open-egg": "e", "hatch": "h"],
            seedMacros: ["auto-hatch", "auto-grind-biome-1"]
        )

        let loader = PluginLoader.shared
        await loader.loadAll()

        XCTAssertEqual(loader.plugins.count, 1, "expected exactly one bundled plugin")
        let plugin = try XCTUnwrap(loader.plugins.first)
        XCTAssertEqual(plugin.id, "pet-sim-99")
        XCTAssertEqual(plugin.displayName, "Pet Simulator 99")
        XCTAssertEqual(plugin.placeId, 8737899170)
        XCTAssertEqual(plugin.windowClass, ["Roblox"])
        XCTAssertEqual(plugin.windowTitleMatch, "Pet Simulator 99|Roblox")
        XCTAssertEqual(plugin.defaultBindings["open-egg"], "e")
        XCTAssertEqual(plugin.defaultBindings["hatch"], "h")
        XCTAssertEqual(plugin.seedMacros, ["auto-hatch", "auto-grind-biome-1"])
        XCTAssertEqual(plugin.source, .bundled)
        XCTAssertFalse(plugin.isUnsigned, "bundled plugins are trusted")
        // Seed-macros directory URL points at the right place even if the
        // dir doesn't exist (10c handles that absence).
        XCTAssertEqual(
            plugin.seedMacrosDirectoryURL.lastPathComponent,
            PluginLoader.seedMacrosDirectoryName
        )
    }

    /// User-installed discovery walks the override directory and surfaces
    /// the plugin under `.userInstalled` source.
    func testUserInstalledDiscoveryWalksOverrideDirectory() async throws {
        try writePluginYAML(
            at: userInstalledRoot,
            id: "community-fishing-game",
            displayName: "Community Fishing Game",
            placeId: 1234567890
        )

        let loader = PluginLoader.shared
        await loader.loadAll()

        XCTAssertEqual(loader.plugins.count, 1)
        let plugin = try XCTUnwrap(loader.plugins.first)
        XCTAssertEqual(plugin.id, "community-fishing-game")
        XCTAssertEqual(plugin.source, .userInstalled)
        XCTAssertTrue(plugin.isUnsigned)
    }

    /// `placeId` collision: bundled wins on tie. The user-installed
    /// duplicate is dropped, and `lastError` records the duplicate.
    func testConflictResolutionBundledWinsOnTie() async throws {
        // Same placeId in bundled + user-installed. The bundled `id` is
        // distinct from the user `id` so we can confirm WHICH instance
        // survived the dedup.
        try writePluginYAML(
            at: bundledRoot,
            id: "pet-sim-99",
            displayName: "Pet Simulator 99 (bundled)",
            placeId: 8737899170
        )
        try writePluginYAML(
            at: userInstalledRoot,
            id: "pet-sim-99-fork",
            displayName: "Pet Simulator 99 (community fork)",
            placeId: 8737899170
        )

        let loader = PluginLoader.shared
        await loader.loadAll()

        XCTAssertEqual(loader.plugins.count, 1, "duplicate placeId should collapse to one")
        let surviving = try XCTUnwrap(loader.plugin(forPlaceId: 8737899170))
        XCTAssertEqual(surviving.id, "pet-sim-99", "bundled instance must win")
        XCTAssertEqual(surviving.source, .bundled)

        // Duplicate warning surfaces in lastError.
        if case .duplicateId(let placeIdString, let locations) = loader.lastError {
            XCTAssertEqual(placeIdString, "8737899170")
            XCTAssertEqual(locations.count, 2, "both yamls should be recorded as the duplicate set")
        } else {
            XCTFail("expected duplicateId warning, got \(String(describing: loader.lastError))")
        }
    }

    /// Trust flag: bundled = trusted (`isUnsigned == false`),
    /// userInstalled = unsigned (`isUnsigned == true`).
    func testTrustFlagFalseForBundledTrueForUserInstalled() async throws {
        try writePluginYAML(
            at: bundledRoot,
            id: "trusted-plugin",
            displayName: "Trusted",
            placeId: 1
        )
        try writePluginYAML(
            at: userInstalledRoot,
            id: "community-plugin",
            displayName: "Community",
            placeId: 2
        )
        // Pre-acknowledge so loadAll() doesn't surface a warning that
        // contaminates this test's intent (warning surface is
        // testFirstLaunchWarningPopulatesForUnsignedPluginsOnce's job).
        let ackKey = PluginLoader.warningAcknowledgedKey(for: "community-plugin")
        UserDefaults.standard.set(true, forKey: ackKey)
        trackDefault(ackKey)

        let loader = PluginLoader.shared
        await loader.loadAll()

        let trusted = try XCTUnwrap(loader.plugins.first { $0.id == "trusted-plugin" })
        let community = try XCTUnwrap(loader.plugins.first { $0.id == "community-plugin" })
        XCTAssertFalse(trusted.isUnsigned)
        XCTAssertTrue(community.isUnsigned)
    }

    // MARK: - Bonus tests

    /// A subdirectory missing `plugin.yaml` doesn't crash `loadAll()`; it
    /// records a non-fatal `pluginYamlMissing` in `lastError` and keeps
    /// indexing the rest.
    func testMissingPluginYamlIsNonFatal() async throws {
        // Valid plugin.
        try writePluginYAML(
            at: bundledRoot,
            id: "valid-plugin",
            displayName: "Valid",
            placeId: 1
        )
        // Empty subdir — no plugin.yaml.
        let emptyPluginDir = bundledRoot.appendingPathComponent("empty-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPluginDir, withIntermediateDirectories: true)

        let loader = PluginLoader.shared
        await loader.loadAll()

        XCTAssertEqual(loader.plugins.count, 1, "only the valid plugin should index")
        XCTAssertEqual(loader.plugins.first?.id, "valid-plugin")

        if case .pluginYamlMissing(let url) = loader.lastError {
            XCTAssertEqual(url.lastPathComponent, PluginLoader.pluginYamlFilename)
        } else {
            XCTFail("expected pluginYamlMissing, got \(String(describing: loader.lastError))")
        }
    }

    /// First-launch warning surfaces unsigned plugins on initial loadAll(),
    /// then clears them after `acknowledgeFirstLaunchWarning(for:)` +
    /// another `loadAll()`.
    func testFirstLaunchWarningPopulatesForUnsignedPluginsOnce() async throws {
        // Bundled (trusted — never in the warning surface).
        try writePluginYAML(
            at: bundledRoot,
            id: "trusted-plugin",
            displayName: "Trusted",
            placeId: 1
        )
        // User-installed (unsigned — warning surface).
        try writePluginYAML(
            at: userInstalledRoot,
            id: "unsigned-plugin",
            displayName: "Unsigned",
            placeId: 2
        )

        // Make sure no leftover ack flag from a prior run is affecting us.
        let ackKey = PluginLoader.warningAcknowledgedKey(for: "unsigned-plugin")
        UserDefaults.standard.removeObject(forKey: ackKey)
        trackDefault(ackKey)

        let loader = PluginLoader.shared
        await loader.loadAll()

        XCTAssertEqual(loader.firstLaunchWarningPending.count, 1,
                       "exactly one unsigned plugin should land in the warning queue")
        XCTAssertEqual(loader.firstLaunchWarningPending.first?.id, "unsigned-plugin")
        XCTAssertFalse(loader.firstLaunchWarningPending.contains { $0.id == "trusted-plugin" },
                       "bundled plugins must never be in the warning queue")

        // Acknowledge — the entry leaves the in-memory queue immediately.
        loader.acknowledgeFirstLaunchWarning(for: "unsigned-plugin")
        XCTAssertTrue(loader.firstLaunchWarningPending.isEmpty,
                      "ack should clear the in-memory queue")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: ackKey),
                      "ack should persist via UserDefaults")

        // Second loadAll() must not re-file the acknowledged plugin.
        await loader.loadAll()
        XCTAssertTrue(loader.firstLaunchWarningPending.isEmpty,
                      "subsequent loadAll() must not re-file an acknowledged plugin")
    }

    // MARK: - URL-install stub

    /// `installPlugin(from:)` is a stub — should throw the deferred error
    /// so callers know to wait for the CLI subcommand to land.
    func testURLInstallStubThrows() async {
        let loader = PluginLoader.shared
        do {
            try await loader.installPlugin(from: URL(string: "https://example.com/plugin.zip")!)
            XCTFail("installPlugin should throw urlInstallNotYetWired")
        } catch let error as PluginLoaderError {
            XCTAssertEqual(error, .urlInstallNotYetWired)
        } catch {
            XCTFail("expected PluginLoaderError, got \(error)")
        }
    }

    // MARK: - 10c — Seed install integration

    /// Resolves the repo-root `games/` directory using `#filePath`.
    /// `#filePath` resolves to this test file under
    /// `<repo>/App/macRoTests/PluginLoaderTests.swift`; the `games/`
    /// dir lives at `<repo>/games/`.
    private static func repoGamesDir(file: StaticString = #filePath) -> URL {
        let testFile = URL(fileURLWithPath: String(describing: file))
        // …/macRoTests/PluginLoaderTests.swift → …/macRoTests → …/App → repo root.
        return testFile
            .deletingLastPathComponent()  // macRoTests
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("games", isDirectory: true)
    }

    /// 10c — `installSeedsFromBundledPlugins()` copies all 5 PS99 seeds
    /// from the repo's `games/pet-sim-99/seed-macros/` into a tmp library
    /// root, and `LibraryStore.localEntries` reflects them.
    func testSeedInstallCopiesPS99SeedsIntoLibrary() async throws {
        // Point the bundled-plugins root at the repo's real `games/`.
        // This mirrors how the production app resolves
        // `Bundle.main.resourceURL/games/` at runtime.
        let gamesDir = Self.repoGamesDir()
        let pluginYAML = gamesDir
            .appendingPathComponent("pet-sim-99", isDirectory: true)
            .appendingPathComponent("plugin.yaml")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: pluginYAML.path),
            "games/pet-sim-99/plugin.yaml not found at \(pluginYAML.path); is the repo layout correct?"
        )
        PluginLoader.bundledPluginsRootOverride = gamesDir

        // Tmp library root for the seed install destination.
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macRoTests-seed-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        LibraryStore.libraryRootOverride = libraryRoot
        defer { LibraryStore.libraryRootOverride = nil }

        // Reset the per-plugin seeds-installed flag so install actually runs.
        let seedsKey = LibraryStore.seedsInstalledKey(for: "pet-sim-99")
        UserDefaults.standard.removeObject(forKey: seedsKey)
        trackDefault(seedsKey)

        // Pre-acknowledge the trust warning so a stray
        // `firstLaunchWarningPending` doesn't bleed into the test —
        // bundled plugins are trusted, but be explicit.
        let ackKey = PluginLoader.warningAcknowledgedKey(for: "pet-sim-99")
        UserDefaults.standard.set(true, forKey: ackKey)
        trackDefault(ackKey)

        // Index the bundled plugin, then run the install.
        await PluginLoader.shared.loadAll()
        XCTAssertEqual(PluginLoader.shared.plugins.count, 1, "PS99 plugin should index")
        XCTAssertEqual(PluginLoader.shared.plugins.first?.id, "pet-sim-99")
        XCTAssertEqual(PluginLoader.shared.plugins.first?.seedMacros.count, 5)

        await LibraryStore.shared.installSeedsFromBundledPlugins()

        // Each seed should now exist under <libraryRoot>/pet-sim-99/<slug>.macro
        let pluginLib = libraryRoot.appendingPathComponent("pet-sim-99", isDirectory: true)
        for slug in ["auto-hatch", "auto-grind-biome-1", "auto-rebirth", "auto-fuse-pets", "clan-battle-helper"] {
            let dest = pluginLib.appendingPathComponent("\(slug).macro", isDirectory: true)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: dest.path),
                "seed \(slug).macro should exist under library/<plugin>/"
            )
        }

        // LibraryStore.localEntries should surface all 5 with game = pet-sim-99.
        let ps99Entries = LibraryStore.shared.localEntries.filter { $0.game == "pet-sim-99" }
        XCTAssertEqual(ps99Entries.count, 5, "all 5 PS99 seeds should appear in localEntries")

        // Flag should now be set.
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: seedsKey),
            "seeds-installed flag should flip after a successful install pass"
        )
    }

    /// 10c — second invocation is a no-op. Library entry count stays
    /// flat; UserDefaults flag stays set.
    func testSeedInstallIsIdempotent() async throws {
        let gamesDir = Self.repoGamesDir()
        let pluginYAML = gamesDir
            .appendingPathComponent("pet-sim-99", isDirectory: true)
            .appendingPathComponent("plugin.yaml")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: pluginYAML.path),
            "games/pet-sim-99/plugin.yaml not found; is the repo layout correct?"
        )
        PluginLoader.bundledPluginsRootOverride = gamesDir

        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macRoTests-seed-install-idem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        LibraryStore.libraryRootOverride = libraryRoot
        defer { LibraryStore.libraryRootOverride = nil }

        let seedsKey = LibraryStore.seedsInstalledKey(for: "pet-sim-99")
        UserDefaults.standard.removeObject(forKey: seedsKey)
        trackDefault(seedsKey)

        let ackKey = PluginLoader.warningAcknowledgedKey(for: "pet-sim-99")
        UserDefaults.standard.set(true, forKey: ackKey)
        trackDefault(ackKey)

        await PluginLoader.shared.loadAll()

        // Pass 1.
        await LibraryStore.shared.installSeedsFromBundledPlugins()
        let firstPassCount = LibraryStore.shared.localEntries
            .filter { $0.game == "pet-sim-99" }
            .count
        XCTAssertEqual(firstPassCount, 5)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: seedsKey))

        // Pass 2 — idempotent. No new entries, flag still set.
        await LibraryStore.shared.installSeedsFromBundledPlugins()
        let secondPassCount = LibraryStore.shared.localEntries
            .filter { $0.game == "pet-sim-99" }
            .count
        XCTAssertEqual(secondPassCount, 5, "second install pass must not duplicate entries")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: seedsKey),
                      "flag must stay set across repeat invocations")
    }
}
