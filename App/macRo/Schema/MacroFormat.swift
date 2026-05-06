// GENERATED FROM schema/macro.schema.yaml — DO NOT EDIT BY HAND. Re-run `bun run codegen` after schema changes.
//
// MacroFormat — Swift Codable types for the macRo .macro bundle format (v1).
//
// This module is the lockstep contract between the Mac app and the (later)
// TS factory pipeline. Spec ref: docs/spec.md > Schema source of truth +
// docs/spec.md > MacroFormat. The generator lives at tools/codegen/.
//
// Threading note (carry from Swift conventions): MacroFormat types are pure
// data with zero UI dependencies. Safe to pass across queues.

import Foundation

/// macRo .macro bundle (v1)
/// The `.macro` bundle is the contract that holds the three macRo subsystems
/// together (Mac app, factory pipeline, library). schemaVersion is the
/// load-bearing forward/back-compat axis — bump it via a logged decision in the
/// 626Labs Dashboard.
/// Top-level logical bundle: `manifest.yaml` + `timeline.yaml` paired.
/// On disk these are two files; this struct represents them as a single
/// Codable value for tests and in-memory round-trips.
public struct MacroBundleData: Codable, Sendable, Equatable, Hashable {
    public let manifest: Manifest
    public let timeline: Timeline

    public init(manifest: Manifest, timeline: Timeline) {
        self.manifest = manifest
        self.timeline = timeline
    }
}

/// Metadata for the macro: identity, the game it targets, runtime knobs, the
/// factory's opt-in flag, and the audit trail of factory patches.
public struct Manifest: Codable, Sendable, Equatable, Hashable {
    /// Stable, slug-form identifier. Convention: `<game-slug>-<purpose>-v<n>`
    /// (e.g., `ps99-auto-hatch-v1`). Used as the file system name and the
    /// factory's addressing key.
    public let id: String
    /// Human-readable display name shown in the Library panel.
    public let name: String
    /// One-paragraph human-readable summary.
    public let description: String?
    /// Author handle or display name. Free-form.
    public let author: String?
    /// SemVer string (`MAJOR.MINOR.PATCH`).
    public let version: String
    /// Schema version this bundle was authored against. Engine refuses to
    /// play unknown schemaVersions (forward-compat is the factory's job;
    /// back-compat is the engine's promise).
    public let schemaVersion: Int
    /// Opt-in flag — if true, the factory may auto-patch this macro when the
    /// target game updates. If false, the factory ignores it entirely. v1
    /// contract; do not break.
    public let factoryPatchable: Bool
    /// Either `"indefinite"` for long-running grinds or an `HH:MM:SS`
    /// duration string for finite macros.
    public let estimatedRuntime: String?
    /// Roblox frame rate observed at recording time (used for scaling).
    public let recordedFrameRate: Double?
    /// Optional cap on continuous run time. Engine aborts after this many
    /// hours. Default: unlimited.
    public let maxRuntimeHours: Double?
    public let game: GameTag?
    public let target: Target?
    public let requires: Requires?
    /// Time windows during which the engine is allowed to run.
    public let schedule: [ScheduleWindow]?
    /// Audit trail. The factory appends entries when it patches this macro;
    /// users see "last patched by the factory on …" in the Library panel.
    public let patchHistory: [PatchHistoryEntry]?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        author: String? = nil,
        version: String,
        schemaVersion: Int,
        factoryPatchable: Bool,
        estimatedRuntime: String? = nil,
        recordedFrameRate: Double? = nil,
        maxRuntimeHours: Double? = nil,
        game: GameTag? = nil,
        target: Target? = nil,
        requires: Requires? = nil,
        schedule: [ScheduleWindow]? = nil,
        patchHistory: [PatchHistoryEntry]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.schemaVersion = schemaVersion
        self.factoryPatchable = factoryPatchable
        self.estimatedRuntime = estimatedRuntime
        self.recordedFrameRate = recordedFrameRate
        self.maxRuntimeHours = maxRuntimeHours
        self.game = game
        self.target = target
        self.requires = requires
        self.schedule = schedule
        self.patchHistory = patchHistory
    }
}

/// The ordered event stream + interrupt-driven control flow. Engine walks
/// `events` linearly, polling `stopOn` triggers in parallel. Sub-macros under
/// `subs` are reachable via `invokeSub` events or `sub:<name>` actions.
public struct Timeline: Codable, Sendable, Equatable, Hashable {
    /// Timeline events. `t` is absolute time in seconds from start (NOT delta
    /// from previous event) — easier diffs, easier scrubbing, easier loop
    /// targeting per design spec § 4.
    public let events: [TimelineEvent]
    /// Interrupt triggers. Polled every 500ms in parallel with the run loop.
    /// When any matches, the engine takes the configured action.
    public let stopOn: [StopOnTrigger]?
    /// Named sub-macros. Keys are sub identifiers (e.g., `cleanup-inventory`,
    /// `reconnect`); values are sub bodies. Subs are not directly invocable
    /// from outside this file — they're called via `invokeSub` events or
    /// `stopOn` actions of the form `sub:<name>`.
    public let subs: [String: SubMacro]?

    public init(
        events: [TimelineEvent],
        stopOn: [StopOnTrigger]? = nil,
        subs: [String: SubMacro]? = nil
    ) {
        self.events = events
        self.stopOn = stopOn
        self.subs = subs
    }
}

/// Game identity tag. `placeId` is the Roblox place ID; `versionFingerprint`
/// is the factory's signal for "what game state was this recorded against."
public struct GameTag: Codable, Sendable, Equatable, Hashable {
    /// Roblox place ID. Optional — untagged macros omit this.
    public let placeId: Int?
    /// Display name (e.g., "Pet Simulator 99").
    public let name: String?
    /// ISO-8601 timestamp of when the version was detected.
    public let versionDetectedAt: String?
    /// Free-form factory-readable signal (a hash of UI screenshots, a
    /// recognized HTML banner, etc.). Engine doesn't read it; factory does.
    public let versionFingerprint: String?

    public init(
        placeId: Int? = nil,
        name: String? = nil,
        versionDetectedAt: String? = nil,
        versionFingerprint: String? = nil
    ) {
        self.placeId = placeId
        self.name = name
        self.versionDetectedAt = versionDetectedAt
        self.versionFingerprint = versionFingerprint
    }
}

/// Where input synthesis lands. The window-targeting fields populate from
/// the chosen game plugin at recording time — users never type selectors.
public struct Target: Codable, Sendable, Equatable, Hashable {
    /// v1: `window` is the only supported value (window-relative coords).
    /// `screen` is reserved for v2.
    public enum TargetCoordinateSpace: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case window
        case screen
    }

    /// The Roblox window's resolution at recording time.
    public struct TargetRecordedResolution: Codable, Sendable, Equatable, Hashable {
        public let width: Int
        public let height: Int

        public init(
            width: Int,
            height: Int
        ) {
            self.width = width
            self.height = height
        }
    }

    /// How the engine handles resolution mismatches at playback time.
    /// - `scale` — proportional scaling of click coords (default; safe).
    /// - `anchor-to-window` — coords used as-is, window-relative
    ///   (only safe at recordedResolution).
    /// - `image-anchored` — coords recomputed from the most recent gate's
    ///   image-search result.
    public enum TargetResolutionPolicy: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case scale
        case anchorToWindow = "anchor-to-window"
        case imageAnchored = "image-anchored"
    }

    /// Fallback NSAccessibility class array. Spec § 11 risk mitigation:
    /// Roblox can change classes; an array means we can fall back without
    /// re-recording every macro.
    public let windowClass: [String]?
    /// Regex matched against the target window's title.
    public let windowTitleMatch: String?
    /// v1: `window` is the only supported value (window-relative coords).
    /// `screen` is reserved for v2.
    public let coordinateSpace: TargetCoordinateSpace?
    /// The Roblox window's resolution at recording time.
    public let recordedResolution: TargetRecordedResolution?
    /// How the engine handles resolution mismatches at playback time.
    /// - `scale` — proportional scaling of click coords (default; safe).
    /// - `anchor-to-window` — coords used as-is, window-relative
    ///   (only safe at recordedResolution).
    /// - `image-anchored` — coords recomputed from the most recent gate's
    ///   image-search result.
    public let resolutionPolicy: TargetResolutionPolicy?

    public init(
        windowClass: [String]? = nil,
        windowTitleMatch: String? = nil,
        coordinateSpace: TargetCoordinateSpace? = nil,
        recordedResolution: TargetRecordedResolution? = nil,
        resolutionPolicy: TargetResolutionPolicy? = nil
    ) {
        self.windowClass = windowClass
        self.windowTitleMatch = windowTitleMatch
        self.coordinateSpace = coordinateSpace
        self.recordedResolution = recordedResolution
        self.resolutionPolicy = resolutionPolicy
    }
}

/// User-binding expectations (Roblox keybind sanity check).
public struct Requires: Codable, Sendable, Equatable, Hashable {
    public struct RequiresBindingsItem: Codable, Sendable, Equatable, Hashable {
        /// Action label (e.g., "interact", "menu").
        public let action: String
        /// Expected key (e.g., "E", "Tab").
        public let expected: String

        public init(
            action: String,
            expected: String
        ) {
            self.action = action
            self.expected = expected
        }
    }

    /// List of (action, expected-key) pairs. Pre-flight prompts the user
    /// once per macro to confirm bindings match.
    public let bindings: [RequiresBindingsItem]?

    public init(
        bindings: [RequiresBindingsItem]? = nil
    ) {
        self.bindings = bindings
    }
}

/// A single time window during which the macro may run.
public struct ScheduleWindow: Codable, Sendable, Equatable, Hashable {
    public struct ScheduleWindowBetween: Codable, Sendable, Equatable, Hashable {
        /// 24-hour HH:MM start time.
        public let from: String
        /// 24-hour HH:MM end time.
        public let to: String
        /// `local` (the user's local zone) or an IANA timezone name
        /// (e.g., `America/Chicago`). Defaults to `local`.
        public let timezone: String?

        public init(
            from: String,
            to: String,
            timezone: String? = nil
        ) {
            self.from = from
            self.to = to
            self.timezone = timezone
        }
    }

    public let between: ScheduleWindowBetween

    public init(
        between: ScheduleWindowBetween
    ) {
        self.between = between
    }
}

/// One factory-patch event in the audit trail.
public struct PatchHistoryEntry: Codable, Sendable, Equatable, Hashable {
    public let date: String
    public let fromVersion: String
    public let toVersion: String
    /// Identifier for the patcher (e.g., `factory@626labs.com` or a human
    /// author handle for manual patches).
    public let patchedBy: String
    public let notes: String?

    public init(
        date: String,
        fromVersion: String,
        toVersion: String,
        patchedBy: String,
        notes: String? = nil
    ) {
        self.date = date
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.patchedBy = patchedBy
        self.notes = notes
    }
}

/// Discriminated on `kind`. Each kind has its own required-field set
/// enforced via `oneOf` below.
public enum TimelineEvent: Codable, Sendable, Equatable, Hashable {
    public struct TimelineEventKeyDownPayload: Codable, Sendable, Equatable, Hashable {
        /// Absolute time in seconds from macro start.
        public let t: Double
        public let key: String

        public init(
            t: Double,
            key: String
        ) {
            self.t = t
            self.key = key
        }
    }

    public struct TimelineEventKeyUpPayload: Codable, Sendable, Equatable, Hashable {
        /// Absolute time in seconds from macro start.
        public let t: Double
        public let key: String

        public init(
            t: Double,
            key: String
        ) {
            self.t = t
            self.key = key
        }
    }

    public struct TimelineEventKeyPressPayload: Codable, Sendable, Equatable, Hashable {
        /// Absolute time in seconds from macro start.
        public let t: Double
        public let key: String

        public init(
            t: Double,
            key: String
        ) {
            self.t = t
            self.key = key
        }
    }

    public struct TimelineEventClickPayload: Codable, Sendable, Equatable, Hashable {
        /// Absolute time in seconds from macro start.
        public let t: Double
        /// Window-relative x (per target.coordinateSpace)
        public let x: Double
        /// Window-relative y
        public let y: Double
        public let button: TimelineEventButton
        /// Optional ±ms randomization for humanized timing.
        public let jitterMs: Double?

        public init(
            t: Double,
            x: Double,
            y: Double,
            button: TimelineEventButton,
            jitterMs: Double? = nil
        ) {
            self.t = t
            self.x = x
            self.y = y
            self.button = button
            self.jitterMs = jitterMs
        }
    }

    public struct TimelineEventCameraDeltaPayload: Codable, Sendable, Equatable, Hashable {
        /// Absolute time in seconds from macro start.
        public let t: Double
        public let dx: Double
        public let dy: Double
        /// Seconds over which to apply the delta.
        public let duration: Double

        public init(
            t: Double,
            dx: Double,
            dy: Double,
            duration: Double
        ) {
            self.t = t
            self.dx = dx
            self.dy = dy
            self.duration = duration
        }
    }

    public struct TimelineEventGatePayload: Codable, Sendable, Equatable, Hashable {
        /// Absolute time in seconds from macro start.
        public let t: Double
        /// `pos` — verify position via image-of-environment (looser ~85%
        /// similarity). `img` — verify UI state via image-of-UI (tighter
        /// ~95% similarity).
        public let gateKind: TimelineEventGateKind
        /// Image reference ID (e.g., `pos-fishing-spot`). Resolves to
        /// `gates/<gateKind>-<ref>.png` on disk. Spec § 4 — refs by ID,
        /// not path, so the factory can swap PNGs without touching
        /// timeline.yaml.
        public let ref: String
        /// How many times to retry before taking onFail.
        public let retries: Int?
        /// Seconds to wait per retry attempt.
        public let timeout: Double?
        /// Action on retries-exhausted. Either a literal `abort` /
        /// `continue`, or `sub:<name>` to invoke a named sub-macro.
        public let onFail: TimelineEventOnFail?

        public init(
            t: Double,
            gateKind: TimelineEventGateKind,
            ref: String,
            retries: Int? = nil,
            timeout: Double? = nil,
            onFail: TimelineEventOnFail? = nil
        ) {
            self.t = t
            self.gateKind = gateKind
            self.ref = ref
            self.retries = retries
            self.timeout = timeout
            self.onFail = onFail
        }
    }

    public struct TimelineEventLoopPayload: Codable, Sendable, Equatable, Hashable {
        /// Absolute time in seconds from macro start.
        public let t: Double
        /// Label for runaway-detection accounting. Engine aborts when any
        /// label's visit count exceeds the runaway threshold.
        public let label: String
        /// Absolute time (seconds) to jump the playhead to. Typically
        /// points at an earlier event's `t`.
        public let target: Double
        /// Optional delay in milliseconds to wait BEFORE jumping the
        /// playhead to `target`. Backward-compatible — when absent or
        /// zero, the jump is immediate (matching v1 pre-7.5 behavior).
        /// The wait is abortable: the engine's cancel-aware sleep polls
        /// the abort flag every 50ms and exits cleanly without resuming
        /// the loop. Used by the quick-loop save flow (item 7.5) to put
        /// a user-set pause between iterations of a record-and-loop
        /// macro without forcing the user through the editor.
        public let delayMs: Int?

        public init(
            t: Double,
            label: String,
            target: Double,
            delayMs: Int? = nil
        ) {
            self.t = t
            self.label = label
            self.target = target
            self.delayMs = delayMs
        }
    }

    public struct TimelineEventInvokeSubPayload: Codable, Sendable, Equatable, Hashable {
        /// Absolute time in seconds from macro start.
        public let t: Double
        /// Sub-macro name (must exist as a key under timeline.subs).
        public let name: String

        public init(
            t: Double,
            name: String
        ) {
            self.t = t
            self.name = name
        }
    }

    public enum TimelineEventButton: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case left
        case right
        case middle
    }

    /// `pos` — verify position via image-of-environment (looser ~85%
    /// similarity). `img` — verify UI state via image-of-UI (tighter
    /// ~95% similarity).
    public enum TimelineEventGateKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case pos
        case img
    }

    /// Action on retries-exhausted. Either a literal `abort` /
    /// `continue`, or `sub:<name>` to invoke a named sub-macro.
    public enum TimelineEventOnFail: Codable, Sendable, Equatable, Hashable {

        public enum Literal: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
            case abort
            case `continue` = "continue"
        }

        case literal(Literal)
        /// Sub-macro invocation — `sub:<name>` form. `name` is the bare identifier.
        case subInvocation(name: String)

        public init(from decoder: Swift.Decoder) throws {
            let single = try decoder.singleValueContainer()
            let raw = try single.decode(String.self)
            if raw.hasPrefix("sub:") {
                let name = String(raw.dropFirst(4))
                self = .subInvocation(name: name)
                return
            }
            if let lit = Literal(rawValue: raw) {
                self = .literal(lit)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Unrecognized TimelineEventOnFail value: \(raw)"
            )
        }

        public func encode(to encoder: Swift.Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .literal(let lit):
                try single.encode(lit.rawValue)
            case .subInvocation(let name):
                try single.encode("sub:\(name)")
            }
        }
    }

    case keyDown(TimelineEventKeyDownPayload)
    case keyUp(TimelineEventKeyUpPayload)
    case keyPress(TimelineEventKeyPressPayload)
    case click(TimelineEventClickPayload)
    case cameraDelta(TimelineEventCameraDeltaPayload)
    case gate(TimelineEventGatePayload)
    case loop(TimelineEventLoopPayload)
    case invokeSub(TimelineEventInvokeSubPayload)

    private enum DiscriminatorKey: String, CodingKey {
        case kind
    }

    private enum KindValue: String, Codable {
        case keyDown = "keyDown"
        case keyUp = "keyUp"
        case keyPress = "keyPress"
        case click = "click"
        case cameraDelta = "cameraDelta"
        case gate = "gate"
        case loop = "loop"
        case invokeSub = "invokeSub"
    }

    public init(from decoder: Swift.Decoder) throws {
        let disc = try decoder.container(keyedBy: DiscriminatorKey.self)
        let kind = try disc.decode(KindValue.self, forKey: .kind)
        switch kind {
        case .keyDown:
            self = .keyDown(try TimelineEventKeyDownPayload(from: decoder))
        case .keyUp:
            self = .keyUp(try TimelineEventKeyUpPayload(from: decoder))
        case .keyPress:
            self = .keyPress(try TimelineEventKeyPressPayload(from: decoder))
        case .click:
            self = .click(try TimelineEventClickPayload(from: decoder))
        case .cameraDelta:
            self = .cameraDelta(try TimelineEventCameraDeltaPayload(from: decoder))
        case .gate:
            self = .gate(try TimelineEventGatePayload(from: decoder))
        case .loop:
            self = .loop(try TimelineEventLoopPayload(from: decoder))
        case .invokeSub:
            self = .invokeSub(try TimelineEventInvokeSubPayload(from: decoder))
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        switch self {
        case .keyDown(let payload):
            try payload.encode(to: encoder)
            var disc = encoder.container(keyedBy: DiscriminatorKey.self)
            try disc.encode(KindValue.keyDown, forKey: .kind)
        case .keyUp(let payload):
            try payload.encode(to: encoder)
            var disc = encoder.container(keyedBy: DiscriminatorKey.self)
            try disc.encode(KindValue.keyUp, forKey: .kind)
        case .keyPress(let payload):
            try payload.encode(to: encoder)
            var disc = encoder.container(keyedBy: DiscriminatorKey.self)
            try disc.encode(KindValue.keyPress, forKey: .kind)
        case .click(let payload):
            try payload.encode(to: encoder)
            var disc = encoder.container(keyedBy: DiscriminatorKey.self)
            try disc.encode(KindValue.click, forKey: .kind)
        case .cameraDelta(let payload):
            try payload.encode(to: encoder)
            var disc = encoder.container(keyedBy: DiscriminatorKey.self)
            try disc.encode(KindValue.cameraDelta, forKey: .kind)
        case .gate(let payload):
            try payload.encode(to: encoder)
            var disc = encoder.container(keyedBy: DiscriminatorKey.self)
            try disc.encode(KindValue.gate, forKey: .kind)
        case .loop(let payload):
            try payload.encode(to: encoder)
            var disc = encoder.container(keyedBy: DiscriminatorKey.self)
            try disc.encode(KindValue.loop, forKey: .kind)
        case .invokeSub(let payload):
            try payload.encode(to: encoder)
            var disc = encoder.container(keyedBy: DiscriminatorKey.self)
            try disc.encode(KindValue.invokeSub, forKey: .kind)
        }
    }
}

/// An interrupt trigger polled every 500ms in parallel with the run loop.
/// When `when` matches, the engine takes `action`.
public struct StopOnTrigger: Codable, Sendable, Equatable, Hashable {
    /// Match condition. v1: gate-image-detection only.
    public struct StopOnTriggerWhen: Codable, Sendable, Equatable, Hashable {
        public enum StopOnTriggerWhenGateKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
            case pos
            case img
        }

        public let gateKind: StopOnTriggerWhenGateKind
        public let ref: String

        public init(
            gateKind: StopOnTriggerWhenGateKind,
            ref: String
        ) {
            self.gateKind = gateKind
            self.ref = ref
        }
    }

    /// Either a literal `pause` / `exit`, or `sub:<name>` to run a sub
    /// and resume main.
    public enum StopOnTriggerAction: Codable, Sendable, Equatable, Hashable {

        public enum Literal: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
            case pause
            case exit
        }

        case literal(Literal)
        /// Sub-macro invocation — `sub:<name>` form. `name` is the bare identifier.
        case subInvocation(name: String)

        public init(from decoder: Swift.Decoder) throws {
            let single = try decoder.singleValueContainer()
            let raw = try single.decode(String.self)
            if raw.hasPrefix("sub:") {
                let name = String(raw.dropFirst(4))
                self = .subInvocation(name: name)
                return
            }
            if let lit = Literal(rawValue: raw) {
                self = .literal(lit)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Unrecognized StopOnTriggerAction value: \(raw)"
            )
        }

        public func encode(to encoder: Swift.Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .literal(let lit):
                try single.encode(lit.rawValue)
            case .subInvocation(let name):
                try single.encode("sub:\(name)")
            }
        }
    }

    /// Match condition. v1: gate-image-detection only.
    public let when: StopOnTriggerWhen
    /// Either a literal `pause` / `exit`, or `sub:<name>` to run a sub
    /// and resume main.
    public let action: StopOnTriggerAction
    /// Optional message shown in the Mac notification on `pause`.
    public let message: String?

    public init(
        when: StopOnTriggerWhen,
        action: StopOnTriggerAction,
        message: String? = nil
    ) {
        self.when = when
        self.action = action
        self.message = message
    }
}

/// A named sub-macro body. `events` follows the same shape as the top-level
/// timeline `events`, but cannot directly self-invoke. Indirect cycles are
/// allowed (the engine has a runaway-loop guard) but are wasteful.
public struct SubMacro: Codable, Sendable, Equatable, Hashable {
    public let events: [TimelineEvent]

    public init(
        events: [TimelineEvent]
    ) {
        self.events = events
    }
}
