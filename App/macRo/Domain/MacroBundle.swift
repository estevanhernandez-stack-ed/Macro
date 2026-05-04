// MacroBundle.swift
// Domain — load / save / validate `.macro` folder bundles.
//
// The `.macro` bundle is the contract that holds the three macRo subsystems
// together. On disk it is a folder:
//
//   <name>.macro/
//     manifest.yaml      → Manifest (codegen Codable)
//     timeline.yaml      → Timeline (codegen Codable)
//     gates/<id>.png     → cross-referenced by gate.ref + stopOn.when.ref
//     preview.mp4        → optional, ignored at load time
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 4
// + docs/spec.md > MacroBundle. Threading: synchronous IO; callers wrap in
// Task if they need async (per item 3 architectural choice).
//
// Validation is two-layered:
//   1. Codable parse — Yams + JSONDecoder catch shape errors at load time
//      (missing required fields, wrong types, unrecognized enum values).
//   2. Cross-reference validation — `validate(_:)` non-throwing structural
//      pass over the in-memory bundle (gate refs resolve to PNG files,
//      invokeSub names resolve to a subs entry, loop targets land on a
//      known event time).

import Foundation
import Yams

/// Namespace for `.macro` bundle IO. Static-only; not instantiable.
public enum MacroBundle {

    // MARK: - Errors

    /// Typed errors thrown by `load(at:)` and `save(_:to:)`. Each case
    /// produces a one-line user-facing `errorDescription` so the editor
    /// can surface "this bundle won't open because…" without unwrapping.
    public enum MacroBundleError: LocalizedError, Equatable {
        /// `manifest.yaml` not found at the expected path inside the bundle.
        case missingManifest(bundlePath: String)
        /// `timeline.yaml` not found at the expected path inside the bundle.
        case missingTimeline(bundlePath: String)
        /// Bundle root does not exist or is not a directory.
        case notABundle(path: String)
        /// YAML in `file` failed to parse or decode against `MacroFormat`.
        /// The underlying error is captured as a string so the case stays
        /// `Equatable` for tests.
        case invalidYaml(file: String, message: String)
        /// A cross-reference inside the bundle could not be resolved
        /// (e.g., `gate.ref` points to a missing PNG, `invokeSub.name`
        /// points to a sub that does not exist).
        case crossRef(field: String, missing: String)
        /// IO error during save — wraps the underlying `Error.localizedDescription`.
        case ioFailure(message: String)

        public var errorDescription: String? {
            switch self {
            case .missingManifest(let path):
                return "Bundle is missing manifest.yaml (looked in \(path))."
            case .missingTimeline(let path):
                return "Bundle is missing timeline.yaml (looked in \(path))."
            case .notABundle(let path):
                return "Path is not a .macro bundle: \(path)."
            case .invalidYaml(let file, let message):
                return "Could not parse \(file): \(message)"
            case .crossRef(let field, let missing):
                return "Bundle cross-reference broken — \(field) points to \(missing) which does not exist."
            case .ioFailure(let message):
                return "Bundle IO failed: \(message)"
            }
        }
    }

    // MARK: - Validation findings

    /// A single structural finding produced by `validate(_:)`. The editor
    /// uses these to surface issues before save without throwing.
    public struct ValidationFinding: Equatable, Hashable, Sendable {
        public enum Level: String, Sendable, Equatable, Hashable {
            case error
            case warning
        }

        public let level: Level
        /// Dotted path into the bundle (e.g., `timeline.events[3].ref`).
        public let path: String
        public let message: String

        public init(level: Level, path: String, message: String) {
            self.level = level
            self.path = path
            self.message = message
        }
    }

    // MARK: - Constants

    /// Filenames inside a `.macro` folder.
    public enum FileName {
        public static let manifest = "manifest.yaml"
        public static let timeline = "timeline.yaml"
        public static let gates = "gates"
    }

    // MARK: - Load

    /// Load a `.macro` bundle from disk. Synchronous IO.
    ///
    /// Steps:
    ///   1. Confirm `url` is a directory.
    ///   2. Read + decode `manifest.yaml` and `timeline.yaml`.
    ///   3. Run `validate(_:)` against the gate-PNG layout on disk;
    ///      cross-ref findings at error level promote to a thrown
    ///      `MacroBundleError.crossRef` so callers can fail fast.
    public static func load(at url: URL) throws -> MacroBundleData {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw MacroBundleError.notABundle(path: url.path)
        }

        let manifestURL = url.appendingPathComponent(FileName.manifest)
        let timelineURL = url.appendingPathComponent(FileName.timeline)

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MacroBundleError.missingManifest(bundlePath: url.path)
        }
        guard FileManager.default.fileExists(atPath: timelineURL.path) else {
            throw MacroBundleError.missingTimeline(bundlePath: url.path)
        }

        let manifest: Manifest = try decodeYaml(at: manifestURL, fileLabel: FileName.manifest)
        let timeline: Timeline = try decodeYaml(at: timelineURL, fileLabel: FileName.timeline)

        let bundle = MacroBundleData(manifest: manifest, timeline: timeline)

        // Cross-ref validation against on-disk gate PNGs.
        let gatesDir = url.appendingPathComponent(FileName.gates, isDirectory: true)
        let onDiskGates = Self.gateImageRefs(in: gatesDir)
        let findings = validate(bundle, availableGateRefs: onDiskGates)

        // Promote cross-ref errors to thrown errors (so callers do not
        // accidentally use a broken bundle with the engine).
        if let firstError = findings.first(where: { $0.level == .error }) {
            throw MacroBundleError.crossRef(field: firstError.path, missing: firstError.message)
        }

        return bundle
    }

    // MARK: - Save

    /// Save a bundle to disk under `url`. Creates the folder if needed,
    /// writes both yaml files, and ensures the `gates/` directory exists.
    /// Does NOT copy gate PNGs from anywhere — callers are responsible for
    /// placing PNGs at the expected refs (the editor manages the working
    /// dir; PluginLoader copies seeded PNGs in directly). v1 contract.
    public static func save(_ bundle: MacroBundleData, to url: URL) throws {
        let fm = FileManager.default
        do {
            // Bundle folder.
            try fm.createDirectory(at: url, withIntermediateDirectories: true)

            // Gates dir (always created so the layout is consistent
            // even when the bundle has zero gate refs today).
            let gatesDir = url.appendingPathComponent(FileName.gates, isDirectory: true)
            try fm.createDirectory(at: gatesDir, withIntermediateDirectories: true)

            // Write manifest + timeline.
            let manifestData = try encodeYaml(bundle.manifest)
            try manifestData.write(to: url.appendingPathComponent(FileName.manifest))

            let timelineData = try encodeYaml(bundle.timeline)
            try timelineData.write(to: url.appendingPathComponent(FileName.timeline))
        } catch let error as MacroBundleError {
            throw error
        } catch {
            throw MacroBundleError.ioFailure(message: error.localizedDescription)
        }
    }

    // MARK: - Validate

    /// Non-throwing structural validator. Returns every finding (errors +
    /// warnings) the editor wants to surface before save.
    ///
    /// Pass `availableGateRefs` from the on-disk `gates/` listing
    /// (`load(at:)` does this). Pass `nil` to skip the gate-PNG cross-ref
    /// pass (e.g., the editor before the first save, when the working dir
    /// is not yet aligned with the model). Pass `[]` to assert that NO
    /// gate refs are present on disk — every gate event is then a
    /// missing-PNG error.
    public static func validate(
        _ bundle: MacroBundleData,
        availableGateRefs: Set<String>? = nil
    ) -> [ValidationFinding] {
        var findings: [ValidationFinding] = []

        // --- Manifest sanity ---
        if bundle.manifest.id.isEmpty {
            findings.append(.init(
                level: .error,
                path: "manifest.id",
                message: "manifest.id must not be empty"
            ))
        }
        if bundle.manifest.version.isEmpty {
            findings.append(.init(
                level: .warning,
                path: "manifest.version",
                message: "manifest.version is empty (semver string expected)"
            ))
        }
        if bundle.manifest.schemaVersion < 1 {
            findings.append(.init(
                level: .error,
                path: "manifest.schemaVersion",
                message: "manifest.schemaVersion must be ≥ 1"
            ))
        }

        // --- Sub names + event-time index for cross-ref checks ---
        let subNames: Set<String> = Set((bundle.timeline.subs ?? [:]).keys)
        let topLevelTimes: Set<Double> = Set(bundle.timeline.events.map { $0.time })

        // --- Top-level timeline events ---
        for (index, event) in bundle.timeline.events.enumerated() {
            findings.append(contentsOf: Self.findings(
                forEvent: event,
                pathPrefix: "timeline.events[\(index)]",
                subNames: subNames,
                eventTimes: topLevelTimes,
                availableGateRefs: availableGateRefs
            ))
        }

        // --- stopOn[] gate refs ---
        for (index, trigger) in (bundle.timeline.stopOn ?? []).enumerated() {
            if let refs = availableGateRefs {
                let expected = "\(trigger.when.gateKind.rawValue)-\(trigger.when.ref)"
                if !refs.contains(expected) {
                    findings.append(.init(
                        level: .error,
                        path: "timeline.stopOn[\(index)].when.ref",
                        message: "gates/\(expected).png"
                    ))
                }
            }
            if case .subInvocation(let name) = trigger.action,
               !subNames.contains(name) {
                findings.append(.init(
                    level: .error,
                    path: "timeline.stopOn[\(index)].action",
                    message: "sub:\(name) (no matching subs entry)"
                ))
            }
        }

        // --- Sub bodies ---
        for (subName, sub) in (bundle.timeline.subs ?? [:]) {
            let subTimes: Set<Double> = Set(sub.events.map { $0.time })
            for (index, event) in sub.events.enumerated() {
                findings.append(contentsOf: Self.findings(
                    forEvent: event,
                    pathPrefix: "timeline.subs.\(subName).events[\(index)]",
                    subNames: subNames,
                    eventTimes: subTimes,
                    availableGateRefs: availableGateRefs
                ))
            }
        }

        return findings
    }

    // MARK: - Private helpers

    /// Per-event findings used both for top-level events and sub bodies.
    private static func findings(
        forEvent event: TimelineEvent,
        pathPrefix: String,
        subNames: Set<String>,
        eventTimes: Set<Double>,
        availableGateRefs: Set<String>?
    ) -> [ValidationFinding] {
        var out: [ValidationFinding] = []
        switch event {
        case .gate(let payload):
            if let refs = availableGateRefs {
                let expected = "\(payload.gateKind.rawValue)-\(payload.ref)"
                if !refs.contains(expected) {
                    out.append(.init(
                        level: .error,
                        path: "\(pathPrefix).ref",
                        message: "gates/\(expected).png"
                    ))
                }
            }
            if case .subInvocation(let name) = (payload.onFail ?? .literal(.continue)),
               !subNames.contains(name) {
                out.append(.init(
                    level: .error,
                    path: "\(pathPrefix).onFail",
                    message: "sub:\(name) (no matching subs entry)"
                ))
            }
        case .invokeSub(let payload):
            if !subNames.contains(payload.name) {
                out.append(.init(
                    level: .error,
                    path: "\(pathPrefix).name",
                    message: "sub:\(payload.name) (no matching subs entry)"
                ))
            }
        case .loop(let payload):
            if !eventTimes.contains(payload.target) {
                out.append(.init(
                    level: .warning,
                    path: "\(pathPrefix).target",
                    message: "loop target t=\(payload.target) does not match any event time in this scope"
                ))
            }
        default:
            break
        }
        return out
    }

    /// List the gate refs present on disk (without `.png` extension and
    /// without the `gates/` prefix). Returns an empty set if the dir
    /// does not exist — caller treats that as "no PNGs yet."
    private static func gateImageRefs(in gatesDir: URL) -> Set<String> {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: gatesDir.path,
            isDirectory: &isDir
        )
        guard exists, isDir.boolValue else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: gatesDir,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(
            contents
                .filter { $0.pathExtension.lowercased() == "png" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    /// Decode a YAML file into a Codable target via Yams.
    private static func decodeYaml<T: Decodable>(at url: URL, fileLabel: String) throws -> T {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MacroBundleError.invalidYaml(file: fileLabel, message: error.localizedDescription)
        }
        do {
            let decoder = YAMLDecoder()
            return try decoder.decode(T.self, from: raw)
        } catch {
            throw MacroBundleError.invalidYaml(file: fileLabel, message: String(describing: error))
        }
    }

    /// Encode a Codable value as YAML bytes.
    private static func encodeYaml<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = YAMLEncoder()
            let yaml = try encoder.encode(value)
            guard let data = yaml.data(using: .utf8) else {
                throw MacroBundleError.ioFailure(message: "yaml encoder returned non-utf8 string")
            }
            return data
        } catch let error as MacroBundleError {
            throw error
        } catch {
            throw MacroBundleError.ioFailure(message: "yaml encode failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - TimelineEvent.time

private extension TimelineEvent {
    /// Every payload variant carries `t`; surface a uniform accessor for
    /// validation (loop-target and subs-time-index lookups).
    var time: Double {
        switch self {
        case .keyDown(let p):     return p.t
        case .keyUp(let p):       return p.t
        case .keyPress(let p):    return p.t
        case .click(let p):       return p.t
        case .cameraDelta(let p): return p.t
        case .gate(let p):        return p.t
        case .loop(let p):        return p.t
        case .invokeSub(let p):   return p.t
        }
    }
}

