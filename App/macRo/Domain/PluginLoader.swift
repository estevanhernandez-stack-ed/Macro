// PluginLoader.swift
// Domain — game-plugin index across three locations.
//
// 10a scope: indexes `plugin.yaml` files from
//   1. App-bundled `<Bundle.main.resourceURL>/games/<plugin>/plugin.yaml`
//   2. User-installed `~/Library/Application Support/macRo/Plugins/<plugin>/plugin.yaml`
//   3. URL-installed (CLI subcommand deferred — `installPlugin(from:)` is a
//      stub that throws `urlInstallNotYetWired`).
//
// 10b authors `games/pet-sim-99/plugin.yaml` + the 5 seed macros.
// 10c wires the first-launch trust warning UI + GamePickSheet integration +
// LibraryStore seed-install.
//
// Spec ref: docs/spec.md > PluginLoader
//           docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 9
//
// Threading: `@MainActor` for the class, mirroring LibraryStore. File IO
// hops onto a background `Task.detached` inside `loadAll()`.

import Foundation
import Observation
import Yams

// MARK: - Errors

/// Typed errors recorded by `PluginLoader`. None of these throw out of
/// `loadAll()` — that pass is non-fatal by design (a single broken plugin
/// shouldn't take the rest of the index down). Errors land in `lastError`
/// for the UI to surface non-modally; the only thrown case is the explicit
/// `urlInstallNotYetWired` from the deferred install stub.
public enum PluginLoaderError: Error, Equatable {
    /// `plugin.yaml` was missing in the indexed location.
    case pluginYamlMissing(URL)
    /// Yams couldn't decode `plugin.yaml`. The underlying error description
    /// is captured as a string so this case stays `Equatable` for tests.
    case pluginYamlParseFailed(URL, message: String)
    /// `schemaVersion` field doesn't match anything PluginLoader knows about.
    case schemaVersionUnsupported(URL, version: Int)
    /// More than one plugin claimed the same `placeId`. Soft-warn; the
    /// loader picks a winner via the source-priority rule (bundled wins).
    case duplicateId(String, locations: [URL])
    /// `installPlugin(from:)` was called before the URL-install path is
    /// wired. Reserved for CLI subcommand `macRo install plugin <url-or-git>`.
    case urlInstallNotYetWired

    public static func == (lhs: PluginLoaderError, rhs: PluginLoaderError) -> Bool {
        switch (lhs, rhs) {
        case (.pluginYamlMissing(let l), .pluginYamlMissing(let r)):
            return l == r
        case (.pluginYamlParseFailed(let lU, let lM), .pluginYamlParseFailed(let rU, let rM)):
            return lU == rU && lM == rM
        case (.schemaVersionUnsupported(let lU, let lV), .schemaVersionUnsupported(let rU, let rV)):
            return lU == rU && lV == rV
        case (.duplicateId(let lID, let lL), .duplicateId(let rID, let rL)):
            return lID == rID && lL == rL
        case (.urlInstallNotYetWired, .urlInstallNotYetWired):
            return true
        default:
            return false
        }
    }
}

// MARK: - Plugin

/// One indexed plugin. Mirrors the `plugin.yaml` schema (see
/// `schema/plugin.schema.yaml`). `pluginYamlURL` + `seedMacrosDirectoryURL`
/// give callers everything they need to copy seeds into the library
/// (10c) or to drive the GamePickSheet (10c).
public struct Plugin: Identifiable, Hashable, Sendable {
    /// Stable slug — pattern `[a-z0-9][a-z0-9-]*[a-z0-9]`.
    public let id: String
    public let displayName: String
    /// Roblox place ID. Load-bearing for conflict resolution (`placeId`
    /// collision = duplicate plugin claim).
    public let placeId: Int
    /// NSAccessibility class fallback array. ≥1 entry per schema.
    public let windowClass: [String]
    /// Optional regex matched against window title (passed through to
    /// Recorder.WindowDetector at record time).
    public let windowTitleMatch: String?
    /// `<action>: <key>` map. Defaults to empty when omitted from yaml.
    public let defaultBindings: [String: String]
    /// Seed macro slugs — references `seed-macros/<slug>.macro/` inside
    /// the plugin folder. 10c's seed-install reads this list.
    public let seedMacros: [String]
    /// Canonical location of the parsed `plugin.yaml`.
    public let pluginYamlURL: URL
    /// `<plugin-root>/seed-macros/`. NOT validated for existence by the
    /// loader — 10c's seed-install handles missing dirs as "no seeds".
    public let seedMacrosDirectoryURL: URL
    /// Where the plugin came from. Drives the trust model.
    public let source: Source

    public enum Source: String, Sendable, Hashable {
        /// App-bundled — trusted. Lives under `Bundle.main.resourceURL/games/`.
        case bundled
        /// User-installed — unsigned community. Lives under
        /// `~/Library/Application Support/macRo/Plugins/`.
        case userInstalled
        /// URL-installed via the deferred CLI flag. Unsigned community.
        case urlInstalled
    }

    /// Trust flag — bundled plugins are trusted; everything else gets the
    /// first-launch warning surface (10c).
    public var isUnsigned: Bool { source != .bundled }
}

// MARK: - YAML decode shape

/// Internal Decodable shape that mirrors `schema/plugin.schema.yaml`.
/// Kept private to PluginLoader — the public surface is `Plugin`.
private struct PluginYAML: Decodable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let placeId: Int
    let windowClass: [String]
    let windowTitleMatch: String?
    let defaultBindings: [String: String]?
    let seedMacros: [String]?
}

// MARK: - PluginLoader

/// In-memory plugin index. Singleton-style — mirrors `LibraryStore.shared`
/// + `Engine.shared` + `Recorder.shared`. UI binds via `@Observable`.
@MainActor
@Observable
public final class PluginLoader {

    // MARK: - Singleton

    public static let shared = PluginLoader()

    private init() {}

    // MARK: - Test seams

    /// Override the bundled plugins root for tests. Production reads
    /// `Bundle.main.resourceURL?.appendingPathComponent("games", isDirectory: true)`.
    /// Set in `setUp`, clear in `tearDown`. `nonisolated(unsafe)` mirrors
    /// `LibraryStore.libraryRootOverride` — XCTest sometimes runs setUp
    /// off-MainActor.
    nonisolated(unsafe) public static var bundledPluginsRootOverride: URL?

    /// Override the user-installed plugins root for tests. Production
    /// reads `~/Library/Application Support/macRo/Plugins/`.
    nonisolated(unsafe) public static var userInstalledPluginsRootOverride: URL?

    // MARK: - Constants

    /// Schema versions PluginLoader knows how to read. Bumping this set
    /// requires a logged decision (per the schema-as-source-of-truth
    /// contract in CLAUDE.md).
    nonisolated public static let supportedSchemaVersions: Set<Int> = [1]

    /// Subdirectory name under each plugin root for seed `.macro` bundles.
    /// Lives next to `plugin.yaml`.
    nonisolated public static let seedMacrosDirectoryName = "seed-macros"

    /// Filename of the yaml. Constant so tests + 10c don't redefine it.
    nonisolated public static let pluginYamlFilename = "plugin.yaml"

    // MARK: - Defaults keys

    /// UserDefaults key prefix for first-launch trust acknowledgement.
    /// 10c's UI flips these flags after the user clicks "Allow" / "Remove".
    nonisolated public static let warningAcknowledgedKeyPrefix = "macRo.PluginLoader.warningAcknowledged."

    /// Key for a single plugin's first-launch warning acknowledgement.
    nonisolated public static func warningAcknowledgedKey(for pluginId: String) -> String {
        return warningAcknowledgedKeyPrefix + pluginId
    }

    // MARK: - Observable state

    /// Indexed plugins. Empty until `loadAll()` runs. After loadAll: sorted
    /// by `displayName` so the GamePickSheet shows a stable order.
    public private(set) var plugins: [Plugin] = []

    /// Unsigned plugins surfaced for the first-launch warning. Populated
    /// by `loadAll()` for any user-installed / url-installed plugin whose
    /// `warningAcknowledgedKey` flag is unset. 10c's UI consumes this list.
    public private(set) var firstLaunchWarningPending: [Plugin] = []

    /// Last non-fatal error from `loadAll()`. Cleared at the start of
    /// every `loadAll()` invocation.
    public private(set) var lastError: PluginLoaderError?

    // MARK: - Paths

    /// Resolved bundled-plugins root, honoring the test override.
    /// Returns nil if no test override is set AND `Bundle.main.resourceURL`
    /// is nil (vanishingly rare in practice — only happens in command-line
    /// hosts with no resource bundle).
    public var bundledPluginsRootURL: URL? {
        if let override = PluginLoader.bundledPluginsRootOverride { return override }
        return Bundle.main.resourceURL?.appendingPathComponent("games", isDirectory: true)
    }

    /// Resolved user-installed-plugins root, honoring the test override.
    public var userInstalledPluginsRootURL: URL {
        if let override = PluginLoader.userInstalledPluginsRootOverride { return override }
        return PluginLoader.defaultUserInstalledPluginsRootURL
    }

    /// Production user-installed plugins root.
    /// `~/Library/Application Support/macRo/Plugins/`.
    public static let defaultUserInstalledPluginsRootURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("macRo", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }()

    // MARK: - Public API

    /// Walk all three index locations, parse every `plugin.yaml` we can
    /// find, resolve `placeId` conflicts (bundled wins), populate
    /// `firstLaunchWarningPending` for unsigned plugins. Never throws —
    /// individual file failures land in `lastError` and the rest of the
    /// index keeps loading.
    public func loadAll() async {
        // Snapshot the override / production roots BEFORE the detached
        // task so we don't read MainActor state off-main.
        let bundledRoot = bundledPluginsRootURL
        let userInstalledRoot = userInstalledPluginsRootURL
        // Reset per-call: the loader is the system of record for this
        // index, so nothing should leak across calls. (Acknowledged
        // warnings persist via UserDefaults, not in-memory state.)
        self.lastError = nil

        let result = await Task.detached(priority: .utility) {
            return PluginLoader.indexAll(
                bundledRoot: bundledRoot,
                userInstalledRoot: userInstalledRoot
            )
        }.value

        self.plugins = result.plugins
        // Surface the FIRST non-fatal warning seen during indexing.
        // Multiple errors collapse to the last-seen — good enough for v1
        // (one bad plugin is the realistic case; multiple is "the user
        // copied a corrupted plugin folder, surface anything").
        self.lastError = result.firstError

        // First-launch warning: only unsigned plugins whose ack flag is
        // unset get filed here. UserDefaults reads must happen on
        // MainActor (via UserDefaults.standard, which is thread-safe but
        // the @Observable surface mutation needs to land here).
        let pending = result.plugins.filter { plugin in
            guard plugin.isUnsigned else { return false }
            return !UserDefaults.standard.bool(
                forKey: PluginLoader.warningAcknowledgedKey(for: plugin.id)
            )
        }
        self.firstLaunchWarningPending = pending
    }

    /// Mark a plugin's first-launch warning as acknowledged. Persists in
    /// UserDefaults so subsequent `loadAll()` calls don't re-file it.
    public func acknowledgeFirstLaunchWarning(for pluginId: String) {
        UserDefaults.standard.set(
            true,
            forKey: PluginLoader.warningAcknowledgedKey(for: pluginId)
        )
        firstLaunchWarningPending.removeAll { $0.id == pluginId }
    }

    /// Lookup helper for `Recorder` / `GamePickSheet` (wired by 10c). The
    /// resolution rule from `loadAll()` already picked the winner; this
    /// is just a `placeId → Plugin` map.
    public func plugin(forPlaceId placeId: Int) -> Plugin? {
        plugins.first { $0.placeId == placeId }
    }

    /// Stub for the deferred URL-install CLI subcommand. Always throws
    /// `urlInstallNotYetWired` until the install path lands.
    public func installPlugin(from url: URL) async throws {
        _ = url
        throw PluginLoaderError.urlInstallNotYetWired
    }

    // MARK: - Indexing (off-main worker)

    /// Result of the off-main indexing pass.
    private struct IndexResult: Sendable {
        let plugins: [Plugin]
        let firstError: PluginLoaderError?
    }

    /// Walks all three locations, parses every `plugin.yaml`, resolves
    /// conflicts, returns the final list + the first non-fatal error.
    /// Static + nonisolated so it runs cleanly off the MainActor inside
    /// a `Task.detached`.
    nonisolated private static func indexAll(
        bundledRoot: URL?,
        userInstalledRoot: URL
    ) -> IndexResult {
        var allPlugins: [Plugin] = []
        var firstError: PluginLoaderError?

        // 1. Bundled.
        if let bundledRoot {
            let (loaded, err) = walkPluginRoot(bundledRoot, source: .bundled)
            allPlugins.append(contentsOf: loaded)
            if firstError == nil, let err { firstError = err }
        }

        // 2. User-installed.
        let (userLoaded, userErr) = walkPluginRoot(userInstalledRoot, source: .userInstalled)
        allPlugins.append(contentsOf: userLoaded)
        if firstError == nil, let userErr { firstError = userErr }

        // 3. URL-installed: deferred. No-op for now; the storage area
        //    doesn't exist on disk yet and will be added when the CLI
        //    subcommand lands.

        // Conflict resolution: same `placeId` across multiple plugins.
        // Bundled wins on tie; if no bundled, first source-order wins.
        // Source order is bundled (1) → userInstalled (2) → urlInstalled (3),
        // and `walkPluginRoot` returns plugins in the order it finds
        // them, so the array is already in source-priority order.
        var seenPlaceIds: [Int: Plugin] = [:]
        var seenLocations: [Int: [URL]] = [:]
        var deduped: [Plugin] = []
        for plugin in allPlugins {
            if let existing = seenPlaceIds[plugin.placeId] {
                // Record the duplicate location for the warning.
                seenLocations[plugin.placeId, default: [existing.pluginYamlURL]]
                    .append(plugin.pluginYamlURL)
                if firstError == nil {
                    let locs = seenLocations[plugin.placeId] ?? []
                    firstError = .duplicateId(
                        String(plugin.placeId),
                        locations: locs
                    )
                }
                continue
            }
            seenPlaceIds[plugin.placeId] = plugin
            deduped.append(plugin)
        }

        // Sort by displayName for stable UI ordering.
        deduped.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return IndexResult(plugins: deduped, firstError: firstError)
    }

    /// Walks one plugin root directory. Returns the parsed plugins + the
    /// first non-fatal error encountered (missing yaml, parse failure,
    /// unsupported schema version).
    nonisolated private static func walkPluginRoot(
        _ root: URL,
        source: Plugin.Source
    ) -> ([Plugin], PluginLoaderError?) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return ([], nil)
        }

        let pluginDirs = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var loaded: [Plugin] = []
        var firstError: PluginLoaderError?

        for pluginDir in pluginDirs {
            var dirCheck: ObjCBool = false
            guard fm.fileExists(atPath: pluginDir.path, isDirectory: &dirCheck),
                  dirCheck.boolValue else { continue }

            let yamlURL = pluginDir.appendingPathComponent(pluginYamlFilename)
            guard fm.fileExists(atPath: yamlURL.path) else {
                if firstError == nil {
                    firstError = .pluginYamlMissing(yamlURL)
                }
                continue
            }

            do {
                let plugin = try parsePluginYAML(at: yamlURL, source: source)
                loaded.append(plugin)
            } catch let error as PluginLoaderError {
                if firstError == nil { firstError = error }
                FileHandle.standardError.write(Data(
                    "PluginLoader: skipped \(pluginDir.lastPathComponent) — \(error)\n".utf8
                ))
            } catch {
                if firstError == nil {
                    firstError = .pluginYamlParseFailed(yamlURL, message: error.localizedDescription)
                }
                FileHandle.standardError.write(Data(
                    "PluginLoader: skipped \(pluginDir.lastPathComponent) — \(error.localizedDescription)\n".utf8
                ))
            }
        }

        return (loaded, firstError)
    }

    /// Parse a single `plugin.yaml`. Throws `PluginLoaderError` on parse /
    /// schema-version failure.
    nonisolated private static func parsePluginYAML(
        at yamlURL: URL,
        source: Plugin.Source
    ) throws -> Plugin {
        let raw: String
        do {
            raw = try String(contentsOf: yamlURL, encoding: .utf8)
        } catch {
            throw PluginLoaderError.pluginYamlParseFailed(yamlURL, message: error.localizedDescription)
        }

        let decoded: PluginYAML
        do {
            let decoder = YAMLDecoder()
            decoded = try decoder.decode(PluginYAML.self, from: raw)
        } catch {
            throw PluginLoaderError.pluginYamlParseFailed(yamlURL, message: String(describing: error))
        }

        guard supportedSchemaVersions.contains(decoded.schemaVersion) else {
            throw PluginLoaderError.schemaVersionUnsupported(yamlURL, version: decoded.schemaVersion)
        }

        let pluginRoot = yamlURL.deletingLastPathComponent()
        let seedDir = pluginRoot.appendingPathComponent(seedMacrosDirectoryName, isDirectory: true)

        return Plugin(
            id: decoded.id,
            displayName: decoded.displayName,
            placeId: decoded.placeId,
            windowClass: decoded.windowClass,
            windowTitleMatch: decoded.windowTitleMatch,
            defaultBindings: decoded.defaultBindings ?? [:],
            seedMacros: decoded.seedMacros ?? [],
            pluginYamlURL: yamlURL,
            seedMacrosDirectoryURL: seedDir,
            source: source
        )
    }
}
