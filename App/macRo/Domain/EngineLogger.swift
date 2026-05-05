// EngineLogger.swift
// Domain — append-only per-run log writer for the engine's chokepoint.
//
// One log file per run, named `<run-id>.log`, written under
// `~/Library/Application Support/macRo/Logs/`. Format is one JSON object
// per line — easy to grep, easy to diff, easy to feed back through any
// JSON tool. Local only. Never sent anywhere. Spec § 6 hard safety: every
// synthesis event MUST log; the user can audit (or delete) the log dir
// without consequence.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 6
// (state machine + hard safety rules) + docs/spec.md > Engine + CLAUDE.md
// (no telemetry, ever).
//
// Threading: a serial DispatchQueue serializes writes. Callers may invoke
// `log(_:)` from any thread; entries land in submission order.

import Foundation

/// Append-only JSON-lines writer. Engine instantiates one per run.
public final class EngineLogger {

    // MARK: - Entry

    /// One log line. Free-form `kind` keeps the JSON shape stable as the
    /// engine grows new event types — readers parse defensively.
    public struct Entry: Encodable, Equatable {
        public let t: TimeInterval
        public let kind: String
        public let detail: [String: String]

        public init(t: TimeInterval, kind: String, detail: [String: String] = [:]) {
            self.t = t
            self.kind = kind
            self.detail = detail
        }
    }

    // MARK: - State

    /// Resolved log file URL. Lazily created on first write.
    public let url: URL

    /// Wall-clock origin (CFAbsoluteTime) for the run. Every entry's `t`
    /// is relative to this so log lines line up with the user's mental
    /// model ("at t=12.3s the engine clicked here").
    private let originAbsoluteTime: CFAbsoluteTime

    /// All file IO serializes through this queue. Engine callers may
    /// invoke `log(_:)` from any thread.
    private let writeQueue = DispatchQueue(
        label: "com.626labs.macRo.engine.logger",
        qos: .utility
    )

    private var didCreateFile = false

    // MARK: - Init

    /// Construct a logger for `runID`. Does not touch the filesystem
    /// until the first `log(_:)` call.
    public init(runID: UUID) {
        self.url = Self.logURL(for: runID)
        self.originAbsoluteTime = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Writes

    /// Append one entry. `kind` is free-form (e.g., `"synth.click"`,
    /// `"gate.evaluate"`, `"state.transition"`); `detail` is an
    /// untyped string map for everything else. `t` is computed on the
    /// caller's thread before the write hops queues so log timestamps
    /// reflect when the event happened, not when the disk write landed.
    public func log(kind: String, detail: [String: String] = [:]) {
        let elapsed = CFAbsoluteTimeGetCurrent() - originAbsoluteTime
        let entry = Entry(t: elapsed, kind: kind, detail: detail)
        writeQueue.async { [weak self] in
            self?.append(entry)
        }
    }

    /// Synchronous append used by tests + by the destructor path. Safe
    /// to call from any thread.
    public func appendSync(_ entry: Entry) {
        writeQueue.sync { [weak self] in
            self?.append(entry)
        }
    }

    // MARK: - Private

    private func append(_ entry: Entry) {
        ensureFileExists()
        do {
            let encoder = JSONEncoder()
            // Stable key order so diffs read cleanly; sortedKeys keeps
            // the JSON deterministic across Swift releases.
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(entry)
            guard let line = String(data: data, encoding: .utf8) else { return }
            let bytes = (line + "\n").data(using: .utf8) ?? Data()

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: bytes)
            } else {
                // Fallback path: file disappeared between create and
                // open. Recreate, then retry once. If this still fails
                // we silently drop the entry — logging must not crash
                // the engine.
                try? bytes.write(to: url)
            }
        } catch {
            // No-op on encoder failure. Entry shape is fully fixed; an
            // encode error here would be a Swift bug, not a user issue.
        }
    }

    private func ensureFileExists() {
        if didCreateFile { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        didCreateFile = true
    }

    // MARK: - Path resolution

    /// Default log directory: `~/Library/Application Support/macRo/Logs/`.
    /// Public so tests + a future log-viewer UI can list files without
    /// recomputing the path.
    public static var logDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("macRo", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    /// Resolved log URL for a given run ID.
    public static func logURL(for runID: UUID) -> URL {
        return logDirectory.appendingPathComponent("\(runID.uuidString).log")
    }
}
