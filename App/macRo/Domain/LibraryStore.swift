// LibraryStore.swift
// Domain — local macro inventory + delete + library-dir bootstrap.
//
// 9a scope: local-only. Walks `~/Library/Application Support/macRo/Library/`
// and surfaces each `.macro` bundle as a `LibraryEntry`. Delete removes
// the bundle dir + any sidecar / rollback subtree if they exist.
//
// 9b adds: remote feed reader, install (download + SHA-256 + sidecar),
// auto-update, rollback, drift detection. Hooks below leave seams without
// taking a position on those flows.
//
// 9c adds: `LibraryView` + Settings pane + post-record integration.
//
// Spec ref: docs/spec.md > LibraryStore + docs/prd.md > Epic E.
// Threading: `@MainActor` for `localEntries` mutations and the public API
// surface; file IO hops onto a background priority `Task` inside
// `reloadLocalInventory()` and `delete(_:)`. Matches the
// MacroBundle-synchronous-IO + caller-wraps-in-Task convention.

import CryptoKit
import Foundation
import Observation

// MARK: - Errors

/// Typed errors surfaced by `LibraryStore`. 9a covers local-only state;
/// 9b adds remote-feed + install + rollback failure modes.
public enum LibraryError: LocalizedError, Equatable {
    /// `~/Library/Application Support/macRo/Library/` does not exist and
    /// could not be created (e.g., disk full, permission denied).
    case libraryDirectoryUnreachable
    /// `delete(_:)` failed; the bundle dir could not be removed. The
    /// underlying `Error` is captured as a string so this case stays
    /// `Equatable` for tests.
    case deleteFailed(URL, message: String)

    // 9b additions — remote install / auto-update / rollback.

    /// Downloaded bundle's SHA-256 didn't match the feed's stated hash.
    /// Library state is left untouched on this throw.
    case hashMismatch(expected: String, actual: String)
    /// Network / response error during download. `underlying` carries the
    /// localized description so the case stays `Equatable`.
    case downloadFailed(URL, message: String)
    /// `refreshRemoteCatalog()` couldn't decode the feed JSON. Surfaces
    /// via `feedReachable = false`; never thrown at the UI boundary.
    case feedDecodeFailed(message: String)
    /// `/usr/bin/unzip` returned non-zero or the archive contained a
    /// path-traversal entry. Library state is left untouched.
    case unzipFailed(URL, message: String)
    /// `rollback(_:to:)` couldn't find the requested version under
    /// `.versions/<game>/<id>/v<version>/`.
    case rollbackVersionUnavailable(macroId: String, version: String)
    /// `feedURL` was set to a non-https / non-file scheme — refused
    /// before any network call.
    case insecureFeedURL(URL)
    /// Download exceeded the 100 MB sanity cap — refused before unzip.
    case downloadTooLarge(URL, byteLength: Int64)

    public var errorDescription: String? {
        switch self {
        case .libraryDirectoryUnreachable:
            return "Library directory at ~/Library/Application Support/macRo/Library is unreachable."
        case .deleteFailed(let url, let message):
            return "Could not delete bundle at \(url.path): \(message)"
        case .hashMismatch(let expected, let actual):
            return "SHA-256 mismatch — feed expected \(expected), download produced \(actual)."
        case .downloadFailed(let url, let message):
            return "Download failed for \(url.absoluteString): \(message)"
        case .feedDecodeFailed(let message):
            return "Could not decode the macro feed: \(message)"
        case .unzipFailed(let url, let message):
            return "Could not unzip \(url.lastPathComponent): \(message)"
        case .rollbackVersionUnavailable(let id, let version):
            return "No stored version v\(version) for macro \(id)."
        case .insecureFeedURL(let url):
            return "Feed URL must be https:// or file:// — refused: \(url.absoluteString)"
        case .downloadTooLarge(let url, let byteLength):
            return "Download exceeded 100 MB sanity cap (\(byteLength) bytes) for \(url.absoluteString)."
        }
    }

    public static func == (lhs: LibraryError, rhs: LibraryError) -> Bool {
        switch (lhs, rhs) {
        case (.libraryDirectoryUnreachable, .libraryDirectoryUnreachable):
            return true
        case (.deleteFailed(let lURL, let lMsg), .deleteFailed(let rURL, let rMsg)):
            return lURL == rURL && lMsg == rMsg
        case (.hashMismatch(let lExp, let lAct), .hashMismatch(let rExp, let rAct)):
            return lExp == rExp && lAct == rAct
        case (.downloadFailed(let lURL, let lMsg), .downloadFailed(let rURL, let rMsg)):
            return lURL == rURL && lMsg == rMsg
        case (.feedDecodeFailed(let lMsg), .feedDecodeFailed(let rMsg)):
            return lMsg == rMsg
        case (.unzipFailed(let lURL, let lMsg), .unzipFailed(let rURL, let rMsg)):
            return lURL == rURL && lMsg == rMsg
        case (.rollbackVersionUnavailable(let lID, let lV), .rollbackVersionUnavailable(let rID, let rV)):
            return lID == rID && lV == rV
        case (.insecureFeedURL(let lURL), .insecureFeedURL(let rURL)):
            return lURL == rURL
        case (.downloadTooLarge(let lURL, let lN), .downloadTooLarge(let rURL, let rN)):
            return lURL == rURL && lN == rN
        default:
            return false
        }
    }
}

// MARK: - LibraryEntry

/// A single macro known to the library. 9a only emits `.local`; 9b will
/// emit `.remote` from feed entries that haven't been installed yet.
public struct LibraryEntry: Identifiable, Hashable, Sendable {
    /// `manifest.id` — stable slug, also used as the library subpath.
    public let id: String
    /// `manifest.name` — display string.
    public let name: String
    /// Game slug — comes from the parent directory name in the library
    /// tree, NOT from the manifest. `"untagged"` for bundles dropped at
    /// `Library/untagged/<id>.macro`.
    public let game: String
    /// `manifest.version` — semver string.
    public let version: String
    public let source: Source
    public let factoryPatchable: Bool
    /// Bundle directory's `contentModificationDate` for `.local`. 9b
    /// refines this for `.remote` (uses feed's `lastUpdated` field).
    public let lastUpdated: Date
    /// Absolute URL of the `.macro` directory on disk. For `.remote` in
    /// 9b: the URL the bundle WILL live at after install.
    public let bundleURL: URL

    public enum Source: String, Hashable, Sendable {
        case local
        case remote
    }
}

// MARK: - LibraryStore

/// Local macro inventory. Singleton-style — mirrors `Engine.shared` /
/// `Recorder.shared`. UI binds via SwiftUI's `@Observable` tracking.
@MainActor
@Observable
public final class LibraryStore {

    // MARK: - Singleton

    public static let shared = LibraryStore()

    private init() {}

    // MARK: - Test seam

    /// Override the library root for tests. Production reads
    /// `~/Library/Application Support/macRo/Library/`. Set in `setUp`,
    /// clear in `tearDown`. Static + nonisolated so `XCTestCase` (which
    /// runs setUp/tearDown synchronously off MainActor in some
    /// configurations) can write it without ceremony.
    nonisolated(unsafe) public static var libraryRootOverride: URL?

    /// Reserved subdirectory at the library root. Skipped during
    /// inventory because it isn't a game slug — 9b populates it with
    /// rollback versions.
    nonisolated public static let versionsDirectoryName = ".versions"

    /// Default game slug for bundles that landed without a plugin.
    nonisolated public static let untaggedGameSlug = "untagged"

    // MARK: - Observable state

    public private(set) var localEntries: [LibraryEntry] = []
    public private(set) var lastError: LibraryError?

    // MARK: - Observable state (9b)

    /// True iff the last `refreshRemoteCatalog()` call completed without a
    /// network/decode error. Drives 9c's "feed unavailable" UI badge.
    /// Default `true` so a fresh install doesn't show "unavailable" before
    /// the first refresh attempt fires.
    public private(set) var feedReachable: Bool = true

    /// Remote feed entries from the last successful refresh. Empty until
    /// refresh runs (or after a failed refresh — the prior list isn't
    /// preserved; a stale list is more dangerous than an empty one).
    public private(set) var remoteEntries: [RemoteEntry] = []

    /// Pending updates filed by `checkForUpdates()`. Drives 9c's update
    /// prompts.
    public private(set) var pendingUpdates: [AvailableUpdate] = []

    // MARK: - Paths

    /// Resolved root URL of the library tree, honoring the test override.
    public var libraryRootURL: URL {
        if let override = LibraryStore.libraryRootOverride { return override }
        return LibraryStore.defaultLibraryRootURL
    }

    /// Production library root. Identical to `Recorder.libraryDirectory`
    /// but resolved independently — the two callers shouldn't fight over
    /// who owns the path constant.
    public static let defaultLibraryRootURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("macRo", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }()

    // MARK: - Bootstrap

    /// Create the library directory if missing. Idempotent — repeated
    /// calls are no-ops once the dir exists.
    public func bootstrapLibraryDirectory() throws {
        let root = libraryRootURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            lastError = .libraryDirectoryUnreachable
            throw LibraryError.libraryDirectoryUnreachable
        }
    }

    // MARK: - Inventory

    /// Walk the library tree and refresh `localEntries`. Bundles that fail
    /// to load (corrupt YAML, missing manifest, broken cross-refs) are
    /// skipped with a warning logged to stderr — the inventory pass should
    /// never throw out a partial result, since the user wants to see
    /// every macro that DID load.
    public func reloadLocalInventory() async {
        let root = libraryRootURL
        let entries = await Task.detached(priority: .utility) {
            return Self.walkLibraryTree(root: root)
        }.value

        self.localEntries = entries
            .sorted { lhs, rhs in
                if lhs.game != rhs.game { return lhs.game < rhs.game }
                return lhs.name < rhs.name
            }
    }

    /// Filter helper. Pass `nil` to get every entry; pass a slug to get
    /// just that game's entries.
    public func entries(forGame game: String?) -> [LibraryEntry] {
        guard let game else { return localEntries }
        return localEntries.filter { $0.game == game }
    }

    // MARK: - Delete

    /// Remove the bundle directory + any `<bundle>.installhash` sidecar +
    /// any `.versions/<game>/<id>/` rollback subtree. Sidecar / versions
    /// cleanup is forward-compatible — 9b populates those locations, 9a
    /// just deletes them when present so 9b's flow is symmetric.
    /// Refreshes `localEntries` after delete.
    public func delete(_ entry: LibraryEntry) async throws {
        let bundleURL = entry.bundleURL
        let sidecarURL = Self.installHashSidecarURL(forBundle: bundleURL)
        let versionsURL = Self.versionsURL(
            forEntry: entry,
            libraryRoot: libraryRootURL
        )

        do {
            try await Task.detached(priority: .utility) {
                let fm = FileManager.default
                if fm.fileExists(atPath: bundleURL.path) {
                    try fm.removeItem(at: bundleURL)
                }
                if fm.fileExists(atPath: sidecarURL.path) {
                    try fm.removeItem(at: sidecarURL)
                }
                if fm.fileExists(atPath: versionsURL.path) {
                    try fm.removeItem(at: versionsURL)
                }
            }.value
        } catch {
            let err = LibraryError.deleteFailed(bundleURL, message: error.localizedDescription)
            lastError = err
            throw err
        }

        await reloadLocalInventory()
    }

    // MARK: - Path helpers (9b extension surface)

    /// Path to the `<bundle>.installhash` sidecar 9b writes at install
    /// time. Exposed on 9a so `delete(_:)` can scrub it without 9b having
    /// to retrofit deletion logic.
    nonisolated public static func installHashSidecarURL(forBundle bundleURL: URL) -> URL {
        let dir = bundleURL.deletingLastPathComponent()
        let filename = bundleURL.lastPathComponent + ".installhash"
        return dir.appendingPathComponent(filename)
    }

    /// Path to the `.versions/<game>/<id>/` rollback subtree 9b populates.
    nonisolated public static func versionsURL(forEntry entry: LibraryEntry, libraryRoot: URL) -> URL {
        return libraryRoot
            .appendingPathComponent(versionsDirectoryName, isDirectory: true)
            .appendingPathComponent(entry.game, isDirectory: true)
            .appendingPathComponent(entry.id, isDirectory: true)
    }

    // MARK: - Inventory walk (off-main worker)

    /// Walks `<root>/<game>/<id>.macro` two levels deep. Skips
    /// `.versions/` (9b's rollback subtree, not a game slug). Skips
    /// hidden entries. Bundles that throw on `MacroBundle.load(at:)` are
    /// dropped with a stderr warning — partial inventory is the right
    /// failure mode.
    nonisolated private static func walkLibraryTree(root: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let gameDirs = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var entries: [LibraryEntry] = []
        for gameDir in gameDirs {
            // Skip the rollback dir (9b territory).
            if gameDir.lastPathComponent == versionsDirectoryName { continue }
            var dirCheck: ObjCBool = false
            guard fm.fileExists(atPath: gameDir.path, isDirectory: &dirCheck),
                  dirCheck.boolValue else { continue }

            let gameSlug = gameDir.lastPathComponent
            let bundleDirs = (try? fm.contentsOfDirectory(
                at: gameDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for bundleDir in bundleDirs {
                guard bundleDir.pathExtension.lowercased() == "macro" else { continue }
                if let entry = loadEntry(bundleDir: bundleDir, gameSlug: gameSlug) {
                    entries.append(entry)
                }
            }
        }

        return entries
    }

    // MARK: - Remote feed (9b)

    /// UserDefaults keys for 9b state. Public so tests + 9c's settings pane
    /// don't redefine the strings.
    public enum Defaults {
        public static let feedURL = "macRo.LibraryStore.feedURL"
        public static func autoUpdateDisabledKey(for entryId: String) -> String {
            return "macRo.LibraryStore.autoUpdateDisabled.\(entryId)"
        }
    }

    /// Default feed URL. Hard-coded fallback — overridable via the
    /// `macRo.LibraryStore.feedURL` UserDefaults key (9c's settings pane).
    nonisolated public static let defaultFeedURLString = "https://macros.626labs.com/feed.json"

    /// Test seam: when set, `refreshRemoteCatalog()` and `install(_:)`
    /// route their downloads through this session. Production uses
    /// `URLSession.shared` if nil.
    nonisolated(unsafe) public static var urlSessionForTesting: URLSession?

    /// Hard cap on download size — macros are small (manifest + timeline +
    /// a handful of PNGs), and 100 MB is generous. Refusing larger pulls
    /// guards against a feed entry pointing at a tarball-bomb URL.
    nonisolated public static let maxDownloadBytes: Int64 = 100 * 1024 * 1024

    /// User-overridable feed URL. Stored in UserDefaults under
    /// `macRo.LibraryStore.feedURL`. Defaults to
    /// `https://macros.626labs.com/feed.json` if unset or invalid.
    public var feedURL: URL {
        get {
            if let raw = UserDefaults.standard.string(forKey: Defaults.feedURL),
               let url = URL(string: raw) {
                return url
            }
            return URL(string: Self.defaultFeedURLString)!
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: Defaults.feedURL)
        }
    }

    /// Read the per-macro auto-update opt-out flag.
    public func isAutoUpdateDisabled(for entryId: String) -> Bool {
        UserDefaults.standard.bool(forKey: Defaults.autoUpdateDisabledKey(for: entryId))
    }

    /// Persist the per-macro auto-update opt-out flag.
    public func setAutoUpdateDisabled(_ disabled: Bool, for entryId: String) {
        UserDefaults.standard.set(disabled, forKey: Defaults.autoUpdateDisabledKey(for: entryId))
    }

    /// Fetch the configured feed URL, decode `RemoteFeed`, refresh
    /// `remoteEntries` + `feedReachable`. NEVER throws — network/decode
    /// errors clear `remoteEntries`, set `feedReachable = false`, and
    /// surface a non-fatal `lastError`. Empty `remoteEntries` is a valid
    /// no-network state (drives 9c's "feed unavailable" badge).
    public func refreshRemoteCatalog() async {
        let url = feedURL
        guard Self.isAllowedFeedScheme(url) else {
            self.feedReachable = false
            self.remoteEntries = []
            self.lastError = .insecureFeedURL(url)
            return
        }

        let session = Self.urlSessionForTesting ?? URLSession.shared
        do {
            let (data, response) = try await session.data(from: url)
            // file:// URLs return a non-HTTPURLResponse; treat any
            // successful read as "feed reachable" for those.
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else {
                    self.feedReachable = false
                    self.remoteEntries = []
                    self.lastError = .downloadFailed(url, message: "HTTP \(http.statusCode)")
                    return
                }
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let feed = try decoder.decode(RemoteFeed.self, from: data)
            self.remoteEntries = feed.entries
            self.feedReachable = true
        } catch let error as DecodingError {
            self.feedReachable = false
            self.remoteEntries = []
            self.lastError = .feedDecodeFailed(message: String(describing: error))
        } catch {
            self.feedReachable = false
            self.remoteEntries = []
            self.lastError = .downloadFailed(url, message: error.localizedDescription)
        }
    }

    // MARK: - Install (9b)

    /// Download the bundle at `remoteEntry.downloadURL`, verify SHA-256,
    /// unzip into the local Library, write the `.installhash` sidecar,
    /// refresh inventory.
    ///
    /// On `LibraryError.hashMismatch`: nothing is written under the
    /// library root — the temp staging dir is removed and the throw is
    /// re-raised, so library state is untouched.
    public func install(_ remoteEntry: RemoteEntry) async throws {
        let libraryRoot = self.libraryRootURL
        let session = Self.urlSessionForTesting ?? URLSession.shared

        try await Self.installImpl(
            remoteEntry: remoteEntry,
            libraryRoot: libraryRoot,
            session: session
        )
        await reloadLocalInventory()
    }

    /// Walk `remoteEntries` × `localEntries`, file `AvailableUpdate`
    /// records into `pendingUpdates` for any local entry whose remote
    /// counterpart has a strictly newer `version`. `drifted` is computed
    /// by re-hashing the local bundle and comparing against the
    /// `.installhash` sidecar.
    public func checkForUpdates() async {
        let locals = self.localEntries
        let remotes = self.remoteEntries

        // Index remotes by id — feed ids should be unique; if a feed
        // duplicates an id, the last one wins (canonical-feed assumption).
        var remoteById: [String: RemoteEntry] = [:]
        for remote in remotes { remoteById[remote.id] = remote }

        let updates = await Task.detached(priority: .utility) {
            var out: [AvailableUpdate] = []
            for local in locals {
                guard let remote = remoteById[local.id] else { continue }
                guard Self.isVersion(remote.version, newerThan: local.version) else { continue }
                let drifted = Self.detectDrift(forBundleAt: local.bundleURL)
                out.append(AvailableUpdate(local: local, remote: remote, drifted: drifted))
            }
            return out
        }.value

        self.pendingUpdates = updates
    }

    /// Apply a pending update. Modes:
    ///   .keepLocal      — drop the update from `pendingUpdates`, no IO.
    ///   .overwrite      — rotate active into `.versions/`, install remote.
    ///   .saveLocalAsNew — copy active to a sibling slot under `<id>-edited-<ts>`,
    ///                     then rotate + install remote.
    public func applyUpdate(_ update: AvailableUpdate, mode: UpdateMode) async throws {
        switch mode {
        case .keepLocal:
            self.pendingUpdates.removeAll { $0.id == update.id }
            return
        case .overwrite:
            try await rotateAndInstall(update: update, savingLocalCopyAsNewID: nil)
            self.pendingUpdates.removeAll { $0.id == update.id }
            await reloadLocalInventory()
        case .saveLocalAsNew:
            // Derived id keeps the original slug + a timestamp so collisions
            // are deterministic across two presses inside the same second
            // (rare in practice, but it's still a path string we control).
            let stamp = Self.savedAsNewStamp()
            let derivedId = "\(update.local.id)-edited-\(stamp)"
            try await rotateAndInstall(
                update: update,
                savingLocalCopyAsNewID: derivedId
            )
            self.pendingUpdates.removeAll { $0.id == update.id }
            await reloadLocalInventory()
        }
    }

    /// Rollback / install support. The mode parameter on `applyUpdate`
    /// drives the three drift-handling paths.
    public enum UpdateMode: Sendable {
        case keepLocal
        case overwrite
        case saveLocalAsNew
    }

    // MARK: - Rollback (9b)

    /// List rollback versions stored under `.versions/<game>/<id>/`.
    /// Sorted newest → oldest, capped at 3 (FIFO eviction enforced at
    /// install / applyUpdate time).
    public func availableRollbackVersions(for entry: LibraryEntry) -> [RollbackVersion] {
        let dir = Self.versionsURL(forEntry: entry, libraryRoot: libraryRootURL)
        return Self.listRollbackVersions(in: dir)
    }

    /// Swap the active bundle pointer to a stored version. Rotates the
    /// current active bundle into `.versions/` (still capped at 3), then
    /// copies the requested version over the active slot.
    public func rollback(_ entry: LibraryEntry, to version: RollbackVersion) async throws {
        let libraryRoot = self.libraryRootURL
        let bundleURL = entry.bundleURL
        let entryId = entry.id
        let entryGame = entry.game
        let entryVersion = entry.version

        try await Task.detached(priority: .utility) {
            let fm = FileManager.default

            // Confirm the requested version is still on disk.
            guard fm.fileExists(atPath: version.url.path) else {
                throw LibraryError.rollbackVersionUnavailable(
                    macroId: entryId,
                    version: version.version
                )
            }

            // Rotate current active into versions/, then overwrite active
            // with the requested version's contents.
            let versionsDir = libraryRoot
                .appendingPathComponent(LibraryStore.versionsDirectoryName, isDirectory: true)
                .appendingPathComponent(entryGame, isDirectory: true)
                .appendingPathComponent(entryId, isDirectory: true)
            try fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)

            let activeSnapshot = versionsDir.appendingPathComponent("v\(entryVersion)", isDirectory: true)
            if fm.fileExists(atPath: activeSnapshot.path) {
                // The previous version slot already exists (e.g., the user
                // is rolling back from v1.1.0 to v1.0.0 and v1.1.0 was
                // already a rotated slot). Remove and re-archive so the
                // mtime reflects this rotation.
                try? fm.removeItem(at: activeSnapshot)
            }
            if fm.fileExists(atPath: bundleURL.path) {
                try fm.copyItem(at: bundleURL, to: activeSnapshot)
            }

            // Remove the old active and overlay the requested version.
            if fm.fileExists(atPath: bundleURL.path) {
                try fm.removeItem(at: bundleURL)
            }
            try fm.copyItem(at: version.url, to: bundleURL)

            // Drop the version we just promoted out of `.versions/` —
            // it's now the active slot, no point keeping a duplicate.
            try? fm.removeItem(at: version.url)

            // Cap to 3 versions.
            LibraryStore.evictOldVersions(in: versionsDir, cap: 3)
        }.value
        await reloadLocalInventory()
    }

    // MARK: - 9b implementation helpers

    /// Validate-then-stage-then-commit install pipeline. Static so tests
    /// can drive it without booting the full @Observable surface, and so
    /// the heavy IO runs off-main.
    nonisolated private static func installImpl(
        remoteEntry: RemoteEntry,
        libraryRoot: URL,
        session: URLSession
    ) async throws {
        guard isAllowedFeedScheme(remoteEntry.downloadURL) else {
            throw LibraryError.insecureFeedURL(remoteEntry.downloadURL)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        // 1. Download.
        let data: Data
        do {
            let (rawData, response) = try await session.data(from: remoteEntry.downloadURL)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw LibraryError.downloadFailed(
                    remoteEntry.downloadURL,
                    message: "HTTP \(http.statusCode)"
                )
            }
            data = rawData
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.downloadFailed(
                remoteEntry.downloadURL,
                message: error.localizedDescription
            )
        }

        if Int64(data.count) > maxDownloadBytes {
            throw LibraryError.downloadTooLarge(
                remoteEntry.downloadURL,
                byteLength: Int64(data.count)
            )
        }

        // 2. Hash verification.
        let actualHash = sha256Hex(data)
        let expectedHash = remoteEntry.sha256.lowercased()
        guard actualHash == expectedHash else {
            throw LibraryError.hashMismatch(
                expected: expectedHash,
                actual: actualHash
            )
        }

        // 3. Stage in a tmp dir; if anything fails, the library is untouched.
        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("macRo-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let zipPath = stagingRoot.appendingPathComponent("download.zip")
        try data.write(to: zipPath)

        let unzipDir = stagingRoot.appendingPathComponent("unzipped", isDirectory: true)
        try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try runUnzip(zip: zipPath, to: unzipDir)
        try assertNoPathTraversal(in: unzipDir)

        // The archive can either contain the .macro folder at root, or
        // contain the bundle's contents at root. Detect both shapes.
        let stagedBundle = try locateStagedBundle(in: unzipDir, bundleId: remoteEntry.id)

        // 4. Compute the canonical install hash before the bundle moves to
        // its final destination — this snapshot is what drift compares
        // against later.
        let installHash = try canonicalBundleHash(at: stagedBundle)

        // 5. Place into the library tree.
        let gameDir = libraryRoot.appendingPathComponent(remoteEntry.game, isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let bundleURL = gameDir.appendingPathComponent("\(remoteEntry.id).macro", isDirectory: true)

        if fm.fileExists(atPath: bundleURL.path) {
            // Caller is responsible for rotation; install over an existing
            // bundle is allowed but never auto-rotates. `rotateAndInstall`
            // handles that path.
            try fm.removeItem(at: bundleURL)
        }
        try fm.copyItem(at: stagedBundle, to: bundleURL)

        // 6. Sidecar.
        let sidecarURL = installHashSidecarURL(forBundle: bundleURL)
        try installHash.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }

    /// Rotate the active bundle into `.versions/`, then install the remote.
    /// If `savingLocalCopyAsNewID` is non-nil, copy the active bundle to
    /// `<game>/<derivedId>.macro` BEFORE rotation so the user keeps their
    /// edits as a separate macro.
    private func rotateAndInstall(
        update: AvailableUpdate,
        savingLocalCopyAsNewID derivedId: String?
    ) async throws {
        let libraryRoot = self.libraryRootURL
        let local = update.local
        let remote = update.remote
        let session = Self.urlSessionForTesting ?? URLSession.shared

        try await Task.detached(priority: .utility) {
            let fm = FileManager.default

            // a. Save-as-new (if requested) — sits as a sibling under the
            // same game dir with the derived id.
            if let derivedId {
                let gameDir = libraryRoot.appendingPathComponent(local.game, isDirectory: true)
                let copyURL = gameDir.appendingPathComponent("\(derivedId).macro", isDirectory: true)
                try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: copyURL.path) {
                    try fm.removeItem(at: copyURL)
                }
                if fm.fileExists(atPath: local.bundleURL.path) {
                    try fm.copyItem(at: local.bundleURL, to: copyURL)
                    // Rewrite the copy's manifest id so the editor / library
                    // reads it as a distinct macro and the install below
                    // doesn't fight over the slot.
                    LibraryStore.rewriteManifestId(at: copyURL, newId: derivedId)
                }
            }

            // b. Rotate active into versions/v<localVersion>/.
            let versionsDir = libraryRoot
                .appendingPathComponent(LibraryStore.versionsDirectoryName, isDirectory: true)
                .appendingPathComponent(local.game, isDirectory: true)
                .appendingPathComponent(local.id, isDirectory: true)
            try fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)

            let snapshot = versionsDir.appendingPathComponent("v\(local.version)", isDirectory: true)
            if fm.fileExists(atPath: snapshot.path) {
                try? fm.removeItem(at: snapshot)
            }
            if fm.fileExists(atPath: local.bundleURL.path) {
                try fm.copyItem(at: local.bundleURL, to: snapshot)
            }
            LibraryStore.evictOldVersions(in: versionsDir, cap: 3)

            // c. Install the remote (overwrites the active slot).
            try await LibraryStore.installImpl(
                remoteEntry: remote,
                libraryRoot: libraryRoot,
                session: session
            )
        }.value
    }

    // MARK: - 9b static helpers (file IO + hashing — nonisolated)

    /// Hex-encode a SHA-256 digest of `data`, lowercased.
    nonisolated public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical drift-detection hash of a `.macro` bundle on disk.
    /// Concatenates manifest.yaml + timeline.yaml + each gates/*.png
    /// ordered by filename, then SHA-256. Returns the lowercase hex.
    nonisolated public static func canonicalBundleHash(at bundleURL: URL) throws -> String {
        let fm = FileManager.default
        var hasher = SHA256()

        let manifestURL = bundleURL.appendingPathComponent("manifest.yaml")
        if fm.fileExists(atPath: manifestURL.path) {
            hasher.update(data: try Data(contentsOf: manifestURL))
        }
        let timelineURL = bundleURL.appendingPathComponent("timeline.yaml")
        if fm.fileExists(atPath: timelineURL.path) {
            hasher.update(data: try Data(contentsOf: timelineURL))
        }

        let gatesDir = bundleURL.appendingPathComponent("gates", isDirectory: true)
        if fm.fileExists(atPath: gatesDir.path) {
            let gates = (try? fm.contentsOfDirectory(
                at: gatesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let pngs = gates
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for png in pngs {
                hasher.update(data: try Data(contentsOf: png))
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns true iff the on-disk bundle's canonical hash differs from
    /// the `.installhash` sidecar. Missing sidecar → not drifted (the
    /// bundle is locally-recorded, not factory-managed).
    nonisolated private static func detectDrift(forBundleAt bundleURL: URL) -> Bool {
        let sidecar = installHashSidecarURL(forBundle: bundleURL)
        guard let sidecarData = try? Data(contentsOf: sidecar),
              let sidecarHash = String(data: sidecarData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !sidecarHash.isEmpty else {
            return false
        }
        guard let actual = try? canonicalBundleHash(at: bundleURL) else {
            return false
        }
        return actual != sidecarHash
    }

    /// Strict semver-ish comparison. We only need "is rhs strictly newer
    /// than lhs" — non-numeric components compare lexicographically as a
    /// tiebreaker. Empty string is treated as 0.0.0.
    nonisolated public static func isVersion(_ rhs: String, newerThan lhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhsParts.count, rhsParts.count)
        for i in 0..<count {
            let l = i < lhsParts.count ? lhsParts[i] : 0
            let r = i < rhsParts.count ? rhsParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    /// Allowed schemes for the feed URL + every remote download URL.
    /// `https://` for production, `file://` for local-test feeds.
    nonisolated public static func isAllowedFeedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "file"
    }

    /// Shell out to /usr/bin/unzip. Refuses to use any other binary so the
    /// host can't shim something unexpected into `$PATH`.
    nonisolated private static func runUnzip(zip: URL, to destination: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -o overwrite without prompting; -qq quiet + non-verbose; -d
        // destination dir.
        task.arguments = ["-oqq", zip.path, "-d", destination.path]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            throw LibraryError.unzipFailed(zip, message: error.localizedDescription)
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let stderr = (try? pipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw LibraryError.unzipFailed(
                zip,
                message: "unzip exit \(task.terminationStatus): \(stderr.isEmpty ? "no stderr" : stderr)"
            )
        }
    }

    /// Walk the unzipped staging dir; refuse if any entry escapes via
    /// path-traversal (`..`) or absolute paths. macOS unzip already
    /// rejects most of these, but defense-in-depth — the install path
    /// runs against arbitrary feeds.
    nonisolated private static func assertNoPathTraversal(in dir: URL) throws {
        let standardizedRoot = dir.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            let standardized = url.standardizedFileURL.path
            if !standardized.hasPrefix(standardizedRoot) {
                throw LibraryError.unzipFailed(
                    dir,
                    message: "path-traversal entry detected: \(url.path)"
                )
            }
        }
    }

    /// Locate the `.macro` bundle inside the unzipped staging dir.
    /// Two valid shapes:
    ///   1. `<unzipDir>/<id>.macro/manifest.yaml` (folder in archive)
    ///   2. `<unzipDir>/manifest.yaml`            (contents in archive)
    nonisolated private static func locateStagedBundle(in unzipDir: URL, bundleId: String) throws -> URL {
        let fm = FileManager.default

        // Shape 2: contents at root.
        let directManifest = unzipDir.appendingPathComponent("manifest.yaml")
        if fm.fileExists(atPath: directManifest.path) {
            return unzipDir
        }

        // Shape 1: nested .macro folder. Prefer one matching the id, fall
        // back to the first .macro folder we find.
        let entries = (try? fm.contentsOfDirectory(
            at: unzipDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let macroDirs = entries.filter { $0.pathExtension.lowercased() == "macro" }

        if let exact = macroDirs.first(where: {
            $0.deletingPathExtension().lastPathComponent == bundleId
        }) {
            return exact
        }
        if let first = macroDirs.first { return first }

        throw LibraryError.unzipFailed(
            unzipDir,
            message: "archive contained no manifest.yaml at root and no .macro folder"
        )
    }

    /// FIFO eviction inside `.versions/<game>/<id>/`. Sort by mtime,
    /// newest first; remove anything past `cap`.
    nonisolated private static func evictOldVersions(in versionsDir: URL, cap: Int) {
        let versions = listRollbackVersions(in: versionsDir)
        guard versions.count > cap else { return }
        let toEvict = versions.dropFirst(cap)
        let fm = FileManager.default
        for version in toEvict {
            try? fm.removeItem(at: version.url)
        }
    }

    /// List rollback versions in a `.versions/<game>/<id>/` directory,
    /// sorted newest → oldest by mtime. Caps at 3 entries even if more
    /// exist on disk (eviction will run on the next install).
    nonisolated private static func listRollbackVersions(in versionsDir: URL) -> [RollbackVersion] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: versionsDir.path, isDirectory: &isDir),
              isDir.boolValue else { return [] }

        let contents = (try? fm.contentsOfDirectory(
            at: versionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var versions: [RollbackVersion] = []
        for url in contents {
            let name = url.lastPathComponent
            // Only `v<...>` entries count as versions.
            guard name.hasPrefix("v"), name.count > 1 else { continue }
            let raw = String(name.dropFirst())
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            versions.append(RollbackVersion(version: raw, url: url, storedAt: mtime))
        }
        versions.sort { $0.storedAt > $1.storedAt }
        return Array(versions.prefix(3))
    }

    /// Stamp used by `saveLocalAsNew` — second-resolution timestamp is
    /// fine for derived ids (collisions inside the same second are
    /// vanishingly rare in practice).
    nonisolated private static func savedAsNewStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    /// Best-effort manifest id rewrite for `saveLocalAsNew`. Pure string
    /// substitution on the `id:` line — avoids re-encoding the YAML and
    /// keeps the rest of the file (formatting, comments) intact. Failure
    /// is non-fatal: a stale id in the saved-as-new copy degrades to
    /// "two macros share an id," which the inventory walker handles by
    /// taking the last one it sees.
    nonisolated private static func rewriteManifestId(at bundleURL: URL, newId: String) {
        let manifestURL = bundleURL.appendingPathComponent("manifest.yaml")
        guard let raw = try? String(contentsOf: manifestURL, encoding: .utf8) else { return }
        var lines = raw.components(separatedBy: "\n")
        for i in 0..<lines.count {
            // Match "id: ..." at the very start of a line (no leading space —
            // top-level field). YAML allows quoting; we match the unquoted
            // form because that's how the codegen + Yams emit it.
            let trimmed = lines[i].drop(while: { $0 == " " })
            if lines[i].hasPrefix("id:") || trimmed.hasPrefix("id:") && lines[i] == String(trimmed) {
                lines[i] = "id: \(newId)"
                break
            }
        }
        let rewritten = lines.joined(separator: "\n")
        try? rewritten.write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    /// Load a single bundle into a `LibraryEntry`. Returns nil + logs to
    /// stderr on any failure — the inventory walker keeps going.
    nonisolated private static func loadEntry(bundleDir: URL, gameSlug: String) -> LibraryEntry? {
        do {
            let bundle = try MacroBundle.load(at: bundleDir)
            let mtime = (try? bundleDir.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            return LibraryEntry(
                id: bundle.manifest.id,
                name: bundle.manifest.name,
                game: gameSlug,
                version: bundle.manifest.version,
                source: .local,
                factoryPatchable: bundle.manifest.factoryPatchable,
                lastUpdated: mtime,
                bundleURL: bundleDir
            )
        } catch {
            FileHandle.standardError.write(Data(
                "LibraryStore: skipped \(bundleDir.lastPathComponent) — \(error.localizedDescription)\n".utf8
            ))
            return nil
        }
    }
}

// MARK: - Remote feed value types (9b)

/// One entry in the remote feed JSON. Decoded directly from the
/// `feed.json` shape; no remapping. `lastUpdated` arrives as ISO-8601.
public struct RemoteEntry: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let game: String
    public let version: String
    public let downloadURL: URL
    public let sha256: String
    public let factoryPatchable: Bool
    public let lastUpdated: Date

    public init(
        id: String,
        name: String,
        game: String,
        version: String,
        downloadURL: URL,
        sha256: String,
        factoryPatchable: Bool,
        lastUpdated: Date
    ) {
        self.id = id
        self.name = name
        self.game = game
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.factoryPatchable = factoryPatchable
        self.lastUpdated = lastUpdated
    }
}

/// Top-level shape of the remote feed JSON.
public struct RemoteFeed: Decodable, Sendable {
    public let entries: [RemoteEntry]

    public init(entries: [RemoteEntry]) {
        self.entries = entries
    }
}

/// A pending update filed by `checkForUpdates()`. `drifted == true` means
/// the user has hand-edited the local bundle since install — the warn-
/// then-decide modal (UpdateDriftPrompt) is the correct UX response.
public struct AvailableUpdate: Identifiable, Hashable, Sendable {
    public var id: String { local.id }
    public let local: LibraryEntry
    public let remote: RemoteEntry
    public let drifted: Bool

    public init(local: LibraryEntry, remote: RemoteEntry, drifted: Bool) {
        self.local = local
        self.remote = remote
        self.drifted = drifted
    }
}

/// One stored prior version under `.versions/<game>/<id>/v<version>/`.
public struct RollbackVersion: Identifiable, Hashable, Sendable {
    public var id: String { version }
    /// e.g., `"1.0.0"` — the segment after the `v` directory prefix.
    public let version: String
    /// Absolute URL of the `.versions/<game>/<id>/v<version>/` dir.
    public let url: URL
    /// Directory mtime — used for FIFO eviction ordering.
    public let storedAt: Date

    public init(version: String, url: URL, storedAt: Date) {
        self.version = version
        self.url = url
        self.storedAt = storedAt
    }
}
