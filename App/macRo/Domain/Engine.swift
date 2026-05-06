// Engine.swift
// Domain — playback engine. Run loop, state machine, single chokepoint,
// gate evaluator, schedule, stopOn, sub-stack, frame-rate and resolution
// scaling.
//
// The engine is the riskiest surface in macRo: every byte of Roblox-
// directed input flows through here. Spec § 6 pins five hard constraints:
//
//   1. The engine NEVER synthesizes input while macRo is frontmost.
//   2. The engine NEVER synthesizes outside the target window's content
//      rect (clicks can't land on the menu bar, Dock, or other apps).
//   3. Every synthesized event passes through ONE chokepoint that logs
//      the event — easier to audit, easier to test.
//   4. The global abort hotkey (⌃⌥⌘.) is always available — no engine
//      state, no UI flow may block it.
//   5. State transitions write a line to ~/Library/Application Support/
//      macRo/Logs/<run-id>.log. Local only; user can delete the dir.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 6
// + docs/spec.md > Engine + docs/prd.md > Epic D.
//
// Threading discipline (spec § 3): the engine owns ONE dedicated serial
// DispatchQueue. The run loop, state transitions, gate evaluation and
// chokepoint synthesis all execute there. SCK frames arrive on SCK's own
// queue; we route the latest frame back to the engine queue when gates
// evaluate. UI signaling hops to MainActor explicitly. abort(reason:) is
// safe-from-any-thread — it async-hops to the engine queue.
//
// 5a scope: this file is the run loop + chokepoint + gates + schedule +
// stopOn + sub-stack + scaling. RunHUD, BindingMismatchPrompt and the
// App.swift hotkey wiring land in 5b. Tests + xcodebuild verify in 5c.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

// MARK: - Public state surface

/// Engine state machine. The `idle → preflight → running ↔ gating →
/// finished | aborted | failed` arc maps directly onto spec § 6's diagram.
/// `paused` is a side-state reachable from preflight (outside-schedule)
/// or from running (window-lost / stopOn pause); the engine resumes
/// automatically when the trigger clears.
public enum EngineState: Equatable {
    case idle
    case preflight
    case paused(reason: EnginePauseReason)
    case running
    case gating
    case finished
    case aborted(reason: EngineAbortReason)
    case failed(error: EngineError)

    /// Convenience for tests + RunHUD: terminal states do not transition
    /// further on their own. The engine queues no work after entering one.
    public var isTerminal: Bool {
        switch self {
        case .finished, .aborted, .failed: return true
        default: return false
        }
    }
}

// MARK: - Engine

/// Singleton-style playback engine. Constructed once at app launch and
/// held for the app lifetime. Concurrent calls into `run(_:)` are
/// rejected — only one macro plays at a time.
///
/// `Engine.shared` is the only sanctioned access path. The class is
/// `final` and the initializer is private; no accidental second instances.
public final class Engine {

    // MARK: - Schema policy

    /// Maximum schema version this engine knows how to play. Bumping this
    /// requires the codegen pipeline to have shipped the matching Swift
    /// types — refuse forward-compat per spec § 6 pre-flight.
    public static let supportedSchemaVersion: Int = 1

    /// Cap on visits to a single `loop.label` before the engine refuses.
    /// Spec § 6 default; per-macro override deferred to schemaVersion bump.
    public static let loopRunawayThreshold: Int = 100_000

    /// Frame-rate scaling clamp. Spec § 6: "cap at 0.5x–2x to avoid
    /// silliness." Applied to held-key durations only.
    public static let frameScaleMin: Double = 0.5
    public static let frameScaleMax: Double = 2.0

    /// Window-discovery timeout for pre-flight (spec § 6 step 2).
    public static let windowMatchTimeout: TimeInterval = 10.0

    /// Polling cadence for stopOn triggers and window-lost detection.
    public static let stopOnPollInterval: TimeInterval = 0.5

    /// Gate similarity thresholds (spec § 6: ~0.95 IMG, ~0.85 POS). The
    /// underlying signal is `1 - VNFeaturePrintObservation.distance`,
    /// clamped to [0, 1]. Threshold tuning is an Open Issue (see
    /// `evaluateGate` for the algorithm-choice comment).
    public static let imgGateThreshold: Double = 0.95
    public static let posGateThreshold: Double = 0.85

    /// Linear backoff schedule (seconds) per gate retry. The engine reads
    /// `gate.retries` and walks this array; if `retries` exceeds the
    /// schedule length, the last value repeats.
    public static let gateRetryBackoff: [TimeInterval] = [0.2, 0.6, 1.2]

    // MARK: - Singleton

    public static let shared = Engine()
    private init() {}

    // MARK: - Queue + state

    /// THE engine queue. Single dedicated serial. Every state mutation,
    /// every chokepoint call, every gate evaluation runs here. Labelled
    /// per CLAUDE.md convention.
    private let queue = DispatchQueue(
        label: "com.626labs.macRo.engine",
        qos: .userInteractive
    )

    /// Authoritative state. Mutated only on the engine queue. Read from
    /// any thread via `state` — atomic by virtue of the lock; readers see
    /// a consistent snapshot, never a torn enum.
    private var _state: EngineState = .idle
    private let stateLock = NSLock()

    /// Public read-only view. Snapshots under the lock; do not call from
    /// the engine queue itself (use `_state` directly via `setState`).
    public var state: EngineState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    /// Optional state-change observer (RunHUD wires this in 5b). Called on
    /// MainActor — UI consumers don't need to bounce queues themselves.
    @MainActor public var onStateChange: ((EngineState) -> Void)?

    /// Read-only accessor for the active run's manifest. Returns nil when
    /// the engine is idle or in a terminal state. Snapshot-style — safe
    /// from any thread (the underlying `active` reference is mutated only
    /// on the engine queue, but the value-type Manifest copy is a
    /// thread-safe snapshot).
    ///
    /// Added at 5b for RunHUD's "current macro name" display. Additive
    /// only — no engine logic touches this; it's a window onto the
    /// internal `active.bundle.manifest` that the UI needs without
    /// breaking encapsulation of the run's mutable state.
    public var currentManifest: Manifest? {
        // The engine queue is the only mutator of `active`. Reading
        // `active?.bundle.manifest` from a non-engine thread is a benign
        // race (worst case: nil one tick after run started, or stale
        // manifest one tick after stopActive). RunHUD redraws on state
        // changes, so any staleness is corrected within ~1 frame.
        return active?.bundle.manifest
    }

    /// Read-only accessor for the active run's start timestamp
    /// (`CFAbsoluteTimeGetCurrent()` at the moment pre-flight completed
    /// and the engine entered `.running`). Returns nil when idle. Used by
    /// RunHUD to render the elapsed-time pill.
    public var runStartedAt: CFAbsoluteTime? {
        return active?.startedAt
    }

    // MARK: - Pre-flight callback hooks

    /// 5b's BindingMismatchPrompt registers here. Returning `true`
    /// proceeds; `false` aborts pre-flight with `.bindingsNotConfirmed`.
    /// 5a contract: nil callback = "all bindings match" (fail-open).
    public var pendingBindingsCheck: ((Manifest) async -> Bool)?

    // MARK: - Active-run state (engine queue only)

    /// All run-scoped state. Reset to nil at terminal transition. Held
    /// as a class so:
    ///   • Mutations from helper methods don't need inout ceremony.
    ///   • The SCK frame sink can write `latestFrame` atomically under
    ///     `frameLock` while the engine queue reads it without copy-and-
    ///     reassign cross-queue races.
    /// Engine-queue-only fields (cursor, loopVisits, subStack) need no
    /// extra locking; the queue serializes their access.
    private final class ActiveRun {
        let bundle: MacroBundleData
        let runID: UUID
        let logger: EngineLogger
        let startedAt: CFAbsoluteTime

        var window: WindowDetector.WindowInfo
        let recordedResolution: Target.TargetRecordedResolution?
        let resolutionPolicy: Target.TargetResolutionPolicy
        var runtimeFrameRate: Double
        var loopVisits: [String: Int] = [:]

        /// Sub-stack: each entry is "where to resume in the parent" — the
        /// timeline events array AND the index after the invokeSub event.
        var subStack: [(events: [TimelineEvent], cursor: Int)] = []
        /// Active scope's events (top-level or current sub body).
        var activeEvents: [TimelineEvent]
        var cursor: Int = 0

        /// SCK live capture for gate frames. Kept alive for the duration
        /// of the run so the first gate doesn't pay startup latency.
        var capture: SCKCapture?
        /// Latest delivered SCK frame — gate evaluator reads this.
        /// Written on SCK's queue, read on the engine queue.
        private var _latestFrame: CGImage?
        private let frameLock = NSLock()

        var latestFrame: CGImage? {
            frameLock.lock(); defer { frameLock.unlock() }
            return _latestFrame
        }

        func setLatestFrame(_ image: CGImage) {
            frameLock.lock(); _latestFrame = image; frameLock.unlock()
        }

        /// Cooperative-cancellation flag. Mutated only on the engine
        /// queue (abort hops onto it; the run loop reads under the same
        /// queue). No lock needed.
        var cancelled: Bool = false
        var cancelReason: EngineAbortReason?

        init(
            bundle: MacroBundleData,
            runID: UUID,
            logger: EngineLogger,
            startedAt: CFAbsoluteTime,
            window: WindowDetector.WindowInfo,
            recordedResolution: Target.TargetRecordedResolution?,
            resolutionPolicy: Target.TargetResolutionPolicy,
            runtimeFrameRate: Double,
            activeEvents: [TimelineEvent],
            capture: SCKCapture?
        ) {
            self.bundle = bundle
            self.runID = runID
            self.logger = logger
            self.startedAt = startedAt
            self.window = window
            self.recordedResolution = recordedResolution
            self.resolutionPolicy = resolutionPolicy
            self.runtimeFrameRate = runtimeFrameRate
            self.activeEvents = activeEvents
            self.capture = capture
        }
    }

    private var active: ActiveRun?

    // MARK: - Public API

    /// Run a macro to completion. Throws on pre-flight failure or
    /// runtime error (`.failed`); returns normally on `.finished`. Each
    /// pre-flight step throws its own typed `EngineError` case (e.g.,
    /// `.unsupportedSchemaVersion`, `.windowNotFound`,
    /// `.bindingsNotConfirmed`); generic conditions (concurrent run, mid-
    /// preflight abort) wrap as `.captureFailed(message:)` because the
    /// existing error surface doesn't carry a dedicated case for them.
    /// Concurrent calls fail with `.captureFailed` (state is not idle).
    public func run(_ bundle: MacroBundleData) async throws {
        // Hop into the engine queue for the entire run. Doing this with
        // `withCheckedThrowingContinuation` keeps the run loop on the
        // dedicated serial queue (per spec § 3 threading discipline)
        // while letting callers `await` completion from any actor.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: EngineError.captureFailed(
                        message: "Engine deallocated before run could start."
                    ))
                    return
                }
                self.runOnQueue(bundle, continuation: cont)
            }
        }
    }

    /// Abort the active run. Safe to call from any thread. The hop to the
    /// engine queue is async — abort returns immediately; the state
    /// transition lands on the next queue tick.
    ///
    /// Spec § 6: this surface MUST remain available regardless of engine
    /// state. Calling abort on an idle engine is a no-op (logged for the
    /// audit trail; no error). The hotkey monitor's contract — "fires
    /// regardless of which app has focus" — flows through this method.
    public func abort(reason: EngineAbortReason) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.active != nil else {
                // Nothing to abort. Don't error — the user may have hit
                // the hotkey reflexively after a clean finish.
                return
            }
            self.active?.cancelled = true
            self.active?.cancelReason = reason
            self.active?.logger.log(kind: "abort.requested", detail: [
                "reason": String(describing: reason)
            ])
        }
    }

    // MARK: - Run-loop entry (engine queue)

    private func runOnQueue(
        _ bundle: MacroBundleData,
        continuation cont: CheckedContinuation<Void, Error>
    ) {
        // Reject re-entry. Single-macro-at-a-time is a hard contract —
        // overlapping runs would race for the synth chokepoint.
        guard case .idle = _state else {
            cont.resume(throwing: EngineError.captureFailed(
                message: "Engine is already running another macro — single-run contract."
            ))
            return
        }

        let runID = UUID()
        let logger = EngineLogger(runID: runID)
        logger.log(kind: "run.start", detail: [
            "macro": bundle.manifest.id,
            "version": bundle.manifest.version,
            "schemaVersion": String(bundle.manifest.schemaVersion)
        ])

        setState(.preflight, logger: logger)

        // --- Pre-flight (spec § 6 steps 1–6). Each step throws on its
        //     own failure mode; we catch once at the bottom and route to
        //     .failed / .aborted with a clear logged transition.
        do {
            try preflightSchema(bundle.manifest, logger: logger)
            let window = try preflightWindow(bundle.manifest, logger: logger)

            // Required-bindings hook. Async because the modal in 5b
            // may take an arbitrary amount of user time. We block the
            // engine queue on the await — that's fine; the engine has
            // no other work pending until pre-flight completes.
            try preflightBindings(bundle.manifest, logger: logger)

            // Schedule check — may park the engine in `paused` until the
            // next window opens. Implemented as a synchronous wait on
            // the engine queue; the run does not advance past this beat
            // until the schedule says yes (or abort is called).
            try preflightSchedule(bundle.manifest, logger: logger)

            // SCK live capture for gate frames + FPS sample. Spec § 6
            // step 5: ~1s of frames → observed FPS. If SCK isn't
            // available (no Screen Recording grant; tests; CI) we fall
            // back to manifest.recordedFrameRate, logged as a warning.
            let capture = try preflightStartCapture(window: window, logger: logger)
            let runtimeFPS = preflightSampleFPS(
                manifest: bundle.manifest,
                capture: capture,
                logger: logger
            )

            // Resolution scale calc. Spec § 6 step 6 — store the policy
            // on `active` so per-event scaling reads it without
            // re-resolving every time.
            let policy = bundle.manifest.target?.resolutionPolicy ?? .scale
            let recordedRes = bundle.manifest.target?.recordedResolution
            if let rec = recordedRes,
               (Int(window.contentRect.width) != rec.width
                || Int(window.contentRect.height) != rec.height) {
                logger.log(kind: "preflight.resolution.warn", detail: [
                    "recorded": "\(rec.width)x\(rec.height)",
                    "runtime": "\(Int(window.contentRect.width))x\(Int(window.contentRect.height))",
                    "policy": String(describing: policy)
                ])
            }

            self.active = ActiveRun(
                bundle: bundle,
                runID: runID,
                logger: logger,
                startedAt: CFAbsoluteTimeGetCurrent(),
                window: window,
                recordedResolution: recordedRes,
                resolutionPolicy: policy,
                runtimeFrameRate: runtimeFPS,
                activeEvents: bundle.timeline.events,
                capture: capture
            )

            // Wire the SCK frame callback now that `active` exists. The
            // callback fires on SCK's queue; we copy the latest CGImage
            // under a lock so the engine queue can read it during gate
            // evaluation without bouncing queues per frame.
            if let capture {
                installFrameSink(on: capture)
            }

            // Stop-on poll timer. Lives on a separate utility queue so
            // the run loop's sleeps don't delay polls.
            startStopOnPolling(bundle: bundle)

            setState(.running, logger: logger)
            try executeRunLoop(bundle: bundle)

            // Fell off the end of the timeline normally.
            stopActive(transition: .finished)
            cont.resume()
        } catch let error as EngineError {
            logger.log(kind: "run.failed", detail: [
                "error": error.errorDescription ?? "unknown"
            ])
            // If abort was requested mid-pre-flight, prefer the abort
            // reason over the synthetic preflight error.
            if let abortReason = active?.cancelReason {
                stopActive(transition: .aborted(reason: abortReason))
            } else {
                stopActive(transition: .failed(error: error))
            }
            cont.resume(throwing: error)
        } catch {
            // Non-EngineError leak. Wrap so RunHUD has something typed.
            let wrapped = EngineError.captureFailed(message: error.localizedDescription)
            logger.log(kind: "run.failed.wrapped", detail: [
                "error": error.localizedDescription
            ])
            stopActive(transition: .failed(error: wrapped))
            cont.resume(throwing: wrapped)
        }
    }

    // MARK: - Pre-flight steps

    private func preflightSchema(_ manifest: Manifest, logger: EngineLogger) throws {
        let v = manifest.schemaVersion
        guard v <= Self.supportedSchemaVersion else {
            throw EngineError.unsupportedSchemaVersion(
                found: v,
                supported: Self.supportedSchemaVersion
            )
        }
        logger.log(kind: "preflight.schema.ok", detail: ["v": String(v)])
    }

    /// Wait up to 10s for a window matching `target.windowTitleMatch` /
    /// `target.windowClass`. Spec § 6 step 2.
    private func preflightWindow(
        _ manifest: Manifest,
        logger: EngineLogger
    ) throws -> WindowDetector.WindowInfo {
        let match = WindowDetector.Match(
            windowClass: manifest.target?.windowClass,
            titleMatch: manifest.target?.windowTitleMatch
        )
        let matcherDesc = manifest.target?.windowTitleMatch
            ?? manifest.target?.windowClass?.joined(separator: ",")
            ?? "(no matchers)"

        let deadline = Date().addingTimeInterval(Self.windowMatchTimeout)
        var lastError: Error?

        // Poll every 250ms until the window appears or we hit the
        // deadline. The 250ms grain is fast enough that "I just opened
        // Roblox" feels instant and slow enough to avoid AX traversal
        // thrash on a busy machine.
        while Date() < deadline {
            // Cooperative cancel check — the user can hotkey out of the
            // wait without forcing them to wait the full 10s. The abort
            // reason is surfaced via the active-run cancelReason that
            // stopActive will read when routing the terminal transition.
            if active?.cancelReason != nil {
                // Bail out of pre-flight cleanly — the catch block in
                // runOnQueue routes to .aborted via active.cancelReason.
                throw EngineError.captureFailed(
                    message: "Pre-flight cancelled during window discovery."
                )
            }
            do {
                if let info = try WindowDetector.find(match) {
                    logger.log(kind: "preflight.window.ok", detail: [
                        "title": info.title,
                        "rect": "\(Int(info.contentRect.width))x\(Int(info.contentRect.height))"
                    ])
                    return info
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        logger.log(kind: "preflight.window.timeout", detail: [
            "matcher": matcherDesc,
            "lastError": (lastError as? LocalizedError)?.errorDescription ?? ""
        ])
        throw EngineError.windowNotFound(matcher: matcherDesc)
    }

    /// Required-bindings hook. 5a contract: if the callback is nil, treat
    /// as fail-open. 5b wires the modal that returns true/false from user
    /// confirmation. Async because the modal lives on MainActor.
    private func preflightBindings(_ manifest: Manifest, logger: EngineLogger) throws {
        guard let cb = pendingBindingsCheck else {
            logger.log(kind: "preflight.bindings.skipped", detail: [
                "reason": "no callback wired (5a fail-open)"
            ])
            return
        }
        // We're on the engine queue; bridge to the async callback via a
        // semaphore. This is the one place we deliberately block — the
        // modal owns the user's attention for as long as it takes.
        let sem = DispatchSemaphore(value: 0)
        var confirmed: Bool = false
        Task {
            confirmed = await cb(manifest)
            sem.signal()
        }
        sem.wait()
        guard confirmed else {
            logger.log(kind: "preflight.bindings.declined", detail: [:])
            throw EngineError.bindingsNotConfirmed
        }
        logger.log(kind: "preflight.bindings.ok", detail: [:])
    }

    /// Park the engine in `paused(.outsideSchedule)` until the current
    /// time falls inside one of `manifest.schedule`. Returns immediately
    /// if no schedule is set. Aborts cleanly if abort is called while
    /// parked.
    private func preflightSchedule(_ manifest: Manifest, logger: EngineLogger) throws {
        guard let schedule = manifest.schedule, !schedule.isEmpty else {
            logger.log(kind: "preflight.schedule.skipped", detail: [
                "reason": "no schedule set"
            ])
            return
        }
        if isInsideAnyWindow(schedule, now: Date()) {
            logger.log(kind: "preflight.schedule.ok", detail: [:])
            return
        }
        let nextStart = nextWindowStart(schedule, after: Date())
        setState(.paused(reason: .outsideSchedule(nextStart: nextStart)), logger: logger)
        logger.log(kind: "preflight.schedule.parked", detail: [
            "nextStart": nextStart?.description ?? "unknown"
        ])
        // Poll every 30s — a finer grain wastes CPU; a coarser grain
        // delays the resume by minutes. 30s is the same beat the OS uses
        // for many of its own time-based housekeepers.
        while !isInsideAnyWindow(schedule, now: Date()) {
            if active?.cancelled == true {
                throw EngineError.captureFailed(
                    message: "Pre-flight cancelled while parked outside schedule."
                )
            }
            Thread.sleep(forTimeInterval: 30.0)
        }
        logger.log(kind: "preflight.schedule.resumed", detail: [:])
    }

    /// Start SCK against the matched window. Returns nil-equivalent
    /// (throws) when Screen Recording isn't granted; the caller maps that
    /// to a fall-back FPS path. SCK lookup is async; we bridge via a
    /// continuation on the engine queue.
    private func preflightStartCapture(
        window: WindowDetector.WindowInfo,
        logger: EngineLogger
    ) throws -> SCKCapture? {
        // Find the SCWindow that matches our WindowDetector match. We
        // re-derive the match from the window's title rather than reusing
        // the manifest's regex — by now the window has been pinned, so an
        // exact-title match is the cheapest cross-API bridge.
        let match = WindowDetector.Match(
            windowClass: nil,
            titleMatch: NSRegularExpression.escapedPattern(for: window.title)
        )

        var resolved: SCWindow?
        var resolveError: Error?
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                resolved = try await SCKCapture.findWindow(matching: match)
            } catch {
                resolveError = error
            }
            sem.signal()
        }
        sem.wait()

        if let err = resolveError {
            logger.log(kind: "preflight.capture.skipped", detail: [
                "reason": "SCK lookup failed",
                "error": (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            ])
            return nil
        }
        guard let scwindow = resolved else {
            logger.log(kind: "preflight.capture.skipped", detail: [
                "reason": "no SCWindow matched the AXUI window"
            ])
            return nil
        }

        let capture = SCKCapture(window: scwindow, frameRate: 60)
        // Start is async; reuse the bridge pattern.
        var startError: Error?
        let startSem = DispatchSemaphore(value: 0)
        Task { [weak self] in
            do {
                try await capture.start { [weak self] sample in
                    self?.handleSCKFrame(sample)
                }
            } catch {
                startError = error
            }
            startSem.signal()
        }
        startSem.wait()

        if let err = startError {
            logger.log(kind: "preflight.capture.failed", detail: [
                "error": (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            ])
            return nil
        }
        logger.log(kind: "preflight.capture.ok", detail: [:])
        return capture
    }

    /// Sample observed FPS by counting frames over ~1s. Falls back to
    /// `manifest.recordedFrameRate` (or 60.0 as a last resort) if no SCK
    /// capture is available. Spec § 6 step 5.
    private func preflightSampleFPS(
        manifest: Manifest,
        capture: SCKCapture?,
        logger: EngineLogger
    ) -> Double {
        let recorded = manifest.recordedFrameRate ?? 60.0
        guard capture != nil else {
            logger.log(kind: "preflight.fps.fallback", detail: [
                "value": String(recorded),
                "reason": "no SCK capture"
            ])
            return recorded
        }

        // Count frames delivered to handleSCKFrame() over the next 1s.
        // We register transiently (lock-protected; SCK's queue is the
        // bumper) since `active` isn't populated yet at this point in
        // pre-flight.
        let counter = FrameCounter()
        addFrameCounter(counter)
        Thread.sleep(forTimeInterval: 1.0)
        removeFrameCounter(counter)
        let observed = Double(counter.count)
        guard observed > 0 else {
            logger.log(kind: "preflight.fps.fallback", detail: [
                "value": String(recorded),
                "reason": "no frames observed in 1s"
            ])
            return recorded
        }
        logger.log(kind: "preflight.fps.ok", detail: [
            "observed": String(observed),
            "recorded": String(recorded)
        ])
        return observed
    }

    // MARK: - SCK frame plumbing

    /// Live frame counters used during the pre-flight FPS sample. The
    /// array itself is mutated on the engine queue (append + remove
    /// during sampling) and read on SCK's queue (bumps). We hold a lock
    /// around array access so the read on SCK's queue sees a consistent
    /// snapshot — bumps never miss a counter that's still in the array.
    private var frameCounters: [FrameCounter] = []
    private let frameCountersLock = NSLock()

    private func snapshotFrameCounters() -> [FrameCounter] {
        frameCountersLock.lock(); defer { frameCountersLock.unlock() }
        return frameCounters
    }

    private func addFrameCounter(_ c: FrameCounter) {
        frameCountersLock.lock(); frameCounters.append(c); frameCountersLock.unlock()
    }

    private func removeFrameCounter(_ c: FrameCounter) {
        frameCountersLock.lock()
        if let idx = frameCounters.firstIndex(where: { $0 === c }) {
            frameCounters.remove(at: idx)
        }
        frameCountersLock.unlock()
    }

    /// Called on SCK's queue. Updates the active run's latest CGImage
    /// (under the run's frame lock) and bumps any active frame counters.
    private func handleSCKFrame(_ sample: CMSampleBuffer) {
        guard let image = Self.cgImage(from: sample) else { return }
        // Snapshot under the array lock; bump each counter via its own
        // lock. Two-level locking keeps the bump fast even when the
        // engine queue is registering / unregistering transient counters.
        for c in snapshotFrameCounters() { c.bump() }
        // Stash the latest frame. ActiveRun is a class; the setter holds
        // its frameLock so the engine queue's read sees a consistent
        // CGImage reference.
        active?.setLatestFrame(image)
    }

    private func installFrameSink(on capture: SCKCapture) {
        // SCK's onFrame is set at start; we already passed handleSCKFrame
        // when calling start. This method is a placeholder hook for any
        // post-start adjustments (cursor toggle, resolution change). Kept
        // here so the run-loop entry reads cleanly.
        _ = capture
    }

    private static func cgImage(from sample: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        return context.createCGImage(ci, from: ci.extent)
    }

    // MARK: - Stop-on polling

    private var stopOnTimerSource: DispatchSourceTimer?

    private func startStopOnPolling(bundle: MacroBundleData) {
        guard let triggers = bundle.timeline.stopOn, !triggers.isEmpty else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + Self.stopOnPollInterval,
            repeating: Self.stopOnPollInterval
        )
        source.setEventHandler { [weak self] in
            self?.evaluateStopOnTriggers(triggers)
        }
        source.resume()
        self.stopOnTimerSource = source
    }

    private func evaluateStopOnTriggers(_ triggers: [StopOnTrigger]) {
        guard let run = active, !run.cancelled else { return }
        for trigger in triggers {
            // We don't yet load gate ref images for stopOn — implementing
            // that requires reading the bundle's gates/ dir into CGImage
            // memoized refs. Logged as a deferred path; the trigger
            // poll-loop is wired so 5b/iterate can fill in evaluation
            // without restructuring the engine.
            run.logger.log(kind: "stopOn.poll.skipped", detail: [
                "ref": trigger.when.ref,
                "reason": "gate ref loading deferred to /iterate"
            ])
            _ = trigger.action
            return
        }
    }

    // MARK: - Run loop

    /// Walk the active scope's events. Each event kind dispatches to its
    /// own helper. The cursor advances forward except for `loop` (which
    /// jumps backward) and `invokeSub` (which jumps into a sub body). On
    /// scope exhaustion, we pop the sub-stack; emptying the stack ends
    /// the run cleanly.
    private func executeRunLoop(bundle: MacroBundleData) throws {
        while let run = active {
            // Cancellation check — first thing every iteration. The
            // run-loop never sleeps without a cancel-aware wait.
            if run.cancelled { return }

            // End-of-scope: pop sub-stack or finish.
            if run.cursor >= run.activeEvents.count {
                if let parent = run.subStack.popLast() {
                    run.activeEvents = parent.events
                    run.cursor = parent.cursor
                    continue
                }
                return
            }

            let event = run.activeEvents[run.cursor]
            let nowElapsed = CFAbsoluteTimeGetCurrent() - run.startedAt

            // Sleep until the event's t. Absolute t is NOT scaled — the
            // recorded timeline is the user's mental model and we honor
            // it. Held-key durations (keyPress hold, click hold,
            // cameraDelta duration) are scaled at dispatch.
            // Cancel-aware: chunked sleeps poll cancellation.
            let waitFor = max(0, eventTime(event) - nowElapsed)
            if waitFor > 0, !cancelAwareSleep(waitFor) { return }
            if run.cancelled { return }

            switch event {
            case .keyDown(let p):
                try dispatchKey(payload: p, kind: .down, run: run)
                run.cursor += 1
            case .keyUp(let p):
                try dispatchKey(payload: p, kind: .up, run: run)
                run.cursor += 1
            case .keyPress(let p):
                try dispatchKeyPress(payload: p, run: run)
                run.cursor += 1
            case .click(let p):
                try dispatchClick(payload: p, run: run)
                run.cursor += 1
            case .cameraDelta(let p):
                try dispatchCameraDelta(payload: p, run: run)
                run.cursor += 1
            case .gate(let p):
                try dispatchGate(payload: p, run: run, bundle: bundle)
                run.cursor += 1
            case .loop(let p):
                // dispatchLoop owns the cursor move (jump or advance).
                try dispatchLoop(payload: p, run: run)
            case .invokeSub(let p):
                // invokeSub repoints activeEvents/cursor.
                try dispatchInvokeSub(payload: p, run: run, bundle: bundle)
            }

            // maxRuntimeHours cap (spec § 6 hard safety).
            if let cap = bundle.manifest.maxRuntimeHours {
                let elapsedHours = (CFAbsoluteTimeGetCurrent() - run.startedAt) / 3600.0
                if elapsedHours > cap {
                    throw EngineError.runtimeCapExceeded(hours: cap)
                }
            }
        }
    }

    // MARK: - Event dispatchers

    private enum KeyKind { case down, up }

    private func dispatchKey(
        payload p: TimelineEvent.TimelineEventKeyDownPayload,
        kind: KeyKind,
        run: ActiveRun
    ) throws {
        let key = Self.virtualKey(forName: p.key)
        let synth: EventTap.SynthInputEvent = (kind == .down)
            ? .keyDown(keyCode: key, flags: [])
            : .keyUp(keyCode: key, flags: [])
        try synthesize(synth, run: run, eventKind: kind == .down ? "synth.keyDown" : "synth.keyUp", at: p.t)
    }

    /// Same payload shape as keyDown; .keyUp variant is structurally
    /// identical at this level. Swift's typed payloads are different
    /// nominal types, so we provide the small bridge.
    private func dispatchKey(
        payload p: TimelineEvent.TimelineEventKeyUpPayload,
        kind: KeyKind,
        run: ActiveRun
    ) throws {
        let key = Self.virtualKey(forName: p.key)
        let synth: EventTap.SynthInputEvent = (kind == .down)
            ? .keyDown(keyCode: key, flags: [])
            : .keyUp(keyCode: key, flags: [])
        try synthesize(synth, run: run, eventKind: kind == .down ? "synth.keyDown" : "synth.keyUp", at: p.t)
    }

    private func dispatchKeyPress(
        payload p: TimelineEvent.TimelineEventKeyPressPayload,
        run: ActiveRun
    ) throws {
        let key = Self.virtualKey(forName: p.key)
        try synthesize(.keyDown(keyCode: key, flags: []), run: run, eventKind: "synth.keyPress.down", at: p.t)
        // 30ms is the conservative tap floor — short enough to feel
        // instantaneous, long enough that low-FPS games sample the
        // down state. Held-key durations come from explicit
        // keyDown/keyUp pairs, not keyPress; this is an explicit "tap."
        let pressHold = clampedFrameScale(seconds: 0.030, run: run)
        if !cancelAwareSleep(pressHold) { return }
        try synthesize(.keyUp(keyCode: key, flags: []), run: run, eventKind: "synth.keyPress.up", at: p.t)
    }

    private func dispatchClick(
        payload p: TimelineEvent.TimelineEventClickPayload,
        run: ActiveRun
    ) throws {
        let button = Self.mouseButton(from: p.button)
        let screenPoint = translate(windowRelative: CGPoint(x: p.x, y: p.y), run: run)
        // Apply jitter (±jitterMs) to the synth pause if specified. Per
        // spec § 4 "humanized timing"; engine-level no-op when nil.
        if let jitter = p.jitterMs, jitter > 0 {
            let amount = Double.random(in: -jitter...jitter) / 1000.0
            if amount > 0, !cancelAwareSleep(amount) { return }
        }
        try synthesize(.mouseMove(location: screenPoint), run: run, eventKind: "synth.move", at: p.t)
        try synthesize(.mouseDown(button: button, location: screenPoint), run: run, eventKind: "synth.click.down", at: p.t)
        // Brief down-hold to register as a click rather than a drag. Same
        // 30ms floor as keyPress.
        let clickHold = clampedFrameScale(seconds: 0.030, run: run)
        if !cancelAwareSleep(clickHold) { return }
        try synthesize(.mouseUp(button: button, location: screenPoint), run: run, eventKind: "synth.click.up", at: p.t)
    }

    private func dispatchCameraDelta(
        payload p: TimelineEvent.TimelineEventCameraDeltaPayload,
        run: ActiveRun
    ) throws {
        // Camera deltas in Roblox-on-Mac are mouseMoved with the right
        // mouse button held (the engine's recorder side captures this as
        // a delta over duration). We approximate with a single mouseMove
        // by `dx, dy` from the current cursor position. Sub-stepping
        // across `duration` for smooth motion is deferred to /iterate —
        // 5a's contract is "dispatched correctly," not "buttery smooth."
        let current = NSEvent.mouseLocation
        let target = CGPoint(x: current.x + p.dx, y: current.y - p.dy)
        try synthesize(.mouseMove(location: target), run: run, eventKind: "synth.cameraDelta", at: p.t)
        if p.duration > 0 {
            let scaledDuration = clampedFrameScale(seconds: p.duration, run: run)
            if !cancelAwareSleep(scaledDuration) { return }
        }
    }

    /// Gate evaluation. Spec § 6: SCK frame capture → template match
    /// against gate ref → threshold → retry/backoff → onFail action.
    ///
    /// LOAD-BEARING ALGORITHM CHOICE: we use Vision's
    /// `VNFeaturePrintObservation` similarity (1 - distance, clamped to
    /// [0, 1]) as the v1 template-match algorithm. Reasons:
    ///   • Native Apple API; no third-party dep.
    ///   • Robust to lighting and minor scaling — the IMG/POS use case.
    ///   • Distance is well-bounded; thresholds map cleanly.
    /// The spec § Open Issues #1 calls out an A/B against ORB and
    /// perceptual hash; that comparison is deferred to /iterate. The gate
    /// evaluator is small enough to swap in-place without restructuring
    /// the run loop.
    private func dispatchGate(
        payload p: TimelineEvent.TimelineEventGatePayload,
        run: ActiveRun,
        bundle: MacroBundleData
    ) throws {
        setState(.gating, logger: run.logger)
        defer { setState(.running, logger: run.logger) }

        let retries = max(0, p.retries ?? 0)
        let threshold = (p.gateKind == .img) ? Self.imgGateThreshold : Self.posGateThreshold

        // Load gate ref through the override-point. 5a contract: when
        // no loader is wired, every gate fails-soft per onFail (default
        // `.continue`) — this is the test-friendly failure mode and
        // also what the runtime defaults to until a bundle-URL-aware
        // loader lands in 5b/iterate.
        let refImage = gateRefLoader?(p.ref, p.gateKind)

        var attempt = 0
        while attempt <= retries {
            if run.cancelled { return }

            // Snapshot the latest SCK frame via the run's lock-protected
            // accessor (writer is on SCK's queue).
            let observed = run.latestFrame

            let similarity = evaluateGateSimilarity(
                observed: observed,
                reference: refImage
            )
            run.logger.log(kind: "gate.evaluate", detail: [
                "ref": p.ref,
                "kind": p.gateKind.rawValue,
                "attempt": String(attempt),
                "similarity": String(format: "%.3f", similarity),
                "threshold": String(threshold)
            ])
            if similarity >= threshold {
                run.logger.log(kind: "gate.ok", detail: ["ref": p.ref])
                return
            }

            // Backoff before next attempt (spec § 6: 200ms / 600ms / 1.2s).
            if attempt < retries {
                let backoff = Self.gateRetryBackoff[
                    min(attempt, Self.gateRetryBackoff.count - 1)
                ]
                if !cancelAwareSleep(backoff) { return }
            }
            attempt += 1
        }

        // Retries exhausted. Take onFail action.
        let onFail = p.onFail ?? .literal(.continue)
        switch onFail {
        case .literal(.continue):
            run.logger.log(kind: "gate.fail.continue", detail: ["ref": p.ref])
            return
        case .literal(.abort):
            run.logger.log(kind: "gate.fail.abort", detail: ["ref": p.ref])
            throw EngineError.gateFailedFinal(ref: p.ref, kind: p.gateKind.rawValue)
        case .subInvocation(let name):
            run.logger.log(kind: "gate.fail.sub", detail: ["ref": p.ref, "sub": name])
            try jumpToSub(named: name, in: bundle, run: run)
        }
    }

    private func dispatchLoop(
        payload p: TimelineEvent.TimelineEventLoopPayload,
        run: ActiveRun
    ) throws {
        let visits = (run.loopVisits[p.label] ?? 0) + 1
        run.loopVisits[p.label] = visits
        if visits > Self.loopRunawayThreshold {
            throw EngineError.loopRunaway(label: p.label)
        }

        // Item 7.5 — optional inter-iteration delay. Sleep BEFORE the
        // jump so the user perceives "playback finished, then we waited,
        // then it started again." cancelAwareSleep polls the abort flag
        // every 50ms; if abort fires mid-wait, the helper returns false
        // and we exit dispatch without moving the cursor. The next
        // iteration of the run loop reads run.cancelled and returns
        // cleanly. Default behavior (delayMs nil or 0) is unchanged —
        // the immediate jump that matched v1 pre-7.5.
        if let delayMs = p.delayMs, delayMs > 0 {
            let seconds = Double(delayMs) / 1000.0
            run.logger.log(kind: "loop.delay.start", detail: [
                "label": p.label,
                "ms": String(delayMs)
            ])
            if !cancelAwareSleep(seconds) {
                // Abort fired during the wait. Don't advance, don't jump,
                // don't log a misleading "loop.jump" — the run loop sees
                // run.cancelled on its next iteration and exits.
                run.logger.log(kind: "loop.delay.aborted", detail: [
                    "label": p.label
                ])
                return
            }
        }

        // Find the event index whose t == target. Spec § 4: t is absolute
        // from start; loop targets typically reference an earlier event's t.
        if let idx = run.activeEvents.firstIndex(where: { eventTime($0) == p.target }) {
            run.cursor = idx
            run.logger.log(kind: "loop.jump", detail: [
                "label": p.label,
                "to": String(p.target),
                "visit": String(visits)
            ])
        } else {
            // No matching event. MacroBundle.validate flags this as a
            // warning at load time; at runtime we treat it as "no-op,
            // advance" rather than fail — runaway-loop guard still
            // protects us.
            run.cursor += 1
            run.logger.log(kind: "loop.target.miss", detail: [
                "label": p.label,
                "target": String(p.target)
            ])
        }
    }

    private func dispatchInvokeSub(
        payload p: TimelineEvent.TimelineEventInvokeSubPayload,
        run: ActiveRun,
        bundle: MacroBundleData
    ) throws {
        try jumpToSub(named: p.name, in: bundle, run: run)
    }

    private func jumpToSub(
        named name: String,
        in bundle: MacroBundleData,
        run: ActiveRun
    ) throws {
        guard let sub = bundle.timeline.subs?[name] else {
            throw EngineError.subNotFound(name: name)
        }
        // Push the parent's resume position (cursor + 1 — we want to
        // continue AFTER the invokeSub event when the sub returns).
        run.subStack.append((events: run.activeEvents, cursor: run.cursor + 1))
        run.activeEvents = sub.events
        run.cursor = 0
        run.logger.log(kind: "sub.enter", detail: [
            "name": name,
            "depth": String(run.subStack.count)
        ])
    }

    // MARK: - Chokepoint

    /// Single chokepoint for ALL synthesized input. Spec § 6 hard safety:
    ///
    ///   1. Asserts macRo is NOT frontmost. If it is, throws
    ///      `.macRoFrontmost`-shaped error (we surface as
    ///      `.preflightFailed` with a logged kind that names the
    ///      condition; EngineError doesn't yet have a dedicated case for
    ///      this, deliberately — adding it is the next schema beat. 5a
    ///      logs the violation and aborts cleanly).
    ///   2. Clamps positional events to the current window content rect
    ///      (post-scale). Logs a "clamp" event when the clamp moved the
    ///      coord — proceed with the clamped value, don't refuse.
    ///   3. Posts via EventTap.synth which uses `.cghidEventTap`.
    ///   4. Logs a JSON line via EngineLogger.
    ///
    /// `at` is the source event's t for log correlation; the logger's
    /// own `t` is wall-clock-from-run-start. Both appear in the log line
    /// so post-mortem readers can line up "macro thinks it's at t=12.3"
    /// with "engine wrote at t=12.4."
    private func synthesize(
        _ event: EventTap.SynthInputEvent,
        run: ActiveRun,
        eventKind: String,
        at sourceT: Double
    ) throws {
        // Reading run.* below is engine-queue-safe by design: synthesize
        // is only called from dispatchers that themselves run on the
        // engine queue. ActiveRun is a class so the snapshot is shared
        // by reference — no copy-back ceremony needed.
        // (1) Frontmost guard. Reads NSWorkspace on whatever thread we're
        // on; the AppKit call is documented thread-safe for the read-only
        // attribute access.
        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let myBundleID = Bundle.main.bundleIdentifier
        if let frontBundleID, let myBundleID, frontBundleID == myBundleID {
            run.logger.log(kind: "chokepoint.refuse.frontmost", detail: [
                "eventKind": eventKind,
                "sourceT": String(sourceT)
            ])
            // Hard safety: we did NOT synthesize. Cancel the run; the
            // user will see a clear log line and a `.failed` state. Using
            // captureFailed as the EngineError carrier preserves the
            // typed error surface without growing a new case mid-5a; a
            // dedicated `.macRoFrontmost` case is a deferred refinement.
            throw EngineError.captureFailed(
                message: "Refusing to synthesize while macRo is frontmost (spec § 6 hard safety)."
            )
        }

        // (2) Clamp positional events to the window content rect.
        let clamped = clampToWindow(event, rect: run.window.contentRect, logger: run.logger, at: sourceT)

        // (3) Post via EventTap. The shared EventTap instance is local to
        // the engine run — synth is stateless on the wrapper, so a fresh
        // instance is fine. Future iterate may pin one for perf.
        do {
            try synthTap.synth(clamped)
        } catch {
            run.logger.log(kind: "chokepoint.synth.failed", detail: [
                "eventKind": eventKind,
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ])
            throw error
        }

        // (4) Log the synthesis. Detail captures coordinates pre/post
        // clamp so reviewers can see the safety boundaries firing.
        var detail: [String: String] = [
            "eventKind": eventKind,
            "sourceT": String(sourceT),
            "synth": String(describing: clamped)
        ]
        if String(describing: event) != String(describing: clamped) {
            detail["original"] = String(describing: event)
        }
        run.logger.log(kind: eventKind, detail: detail)
    }

    /// Pinned EventTap instance for synthesis. Constructed lazily on
    /// first use. EventTap.synth is stateless w.r.t. the recording side,
    /// so reusing a single instance avoids per-event init cost.
    private lazy var synthTap = EventTap()

    // MARK: - Coord transforms + safety helpers

    /// Convert a window-relative point into screen coords, applying the
    /// active resolution scaling policy. Spec § 6 step 6.
    private func translate(windowRelative: CGPoint, run: ActiveRun) -> CGPoint {
        let rect = run.window.contentRect
        let (sx, sy) = scaleFactors(run: run)
        let scaledX = windowRelative.x * sx
        let scaledY = windowRelative.y * sy
        // contentRect is Cocoa coords (origin bottom-left of primary
        // screen); CGEvent.post expects the same screen coord space we
        // pass to .cghidEventTap. The window-relative origin is the
        // window's top-left from the user's perspective, so flip Y
        // against the window height before adding the rect origin.
        let screenY = rect.origin.y + (rect.height - scaledY)
        let screenX = rect.origin.x + scaledX
        return CGPoint(x: screenX, y: screenY)
    }

    private func scaleFactors(run: ActiveRun) -> (Double, Double) {
        guard run.resolutionPolicy == .scale,
              let rec = run.recordedResolution,
              rec.width > 0, rec.height > 0 else {
            return (1.0, 1.0)
        }
        let sx = Double(run.window.contentRect.width) / Double(rec.width)
        let sy = Double(run.window.contentRect.height) / Double(rec.height)
        return (sx, sy)
    }

    /// Clamp positional events to the window content rect. Logs a
    /// clamp.warn line when the clamp moved the coord — the engine
    /// proceeds with the clamped value (refusing would leave macros
    /// brittle at window-edge clicks).
    private func clampToWindow(
        _ event: EventTap.SynthInputEvent,
        rect: NSRect,
        logger: EngineLogger,
        at sourceT: Double
    ) -> EventTap.SynthInputEvent {
        switch event {
        case .keyDown, .keyUp:
            return event
        case .mouseDown(let button, let loc):
            let clamped = clamp(loc, to: rect, logger: logger, kind: "mouseDown", at: sourceT)
            return .mouseDown(button: button, location: clamped)
        case .mouseUp(let button, let loc):
            let clamped = clamp(loc, to: rect, logger: logger, kind: "mouseUp", at: sourceT)
            return .mouseUp(button: button, location: clamped)
        case .mouseMove(let loc):
            let clamped = clamp(loc, to: rect, logger: logger, kind: "mouseMove", at: sourceT)
            return .mouseMove(location: clamped)
        }
    }

    private func clamp(
        _ p: CGPoint,
        to rect: NSRect,
        logger: EngineLogger,
        kind: String,
        at sourceT: Double
    ) -> CGPoint {
        let x = min(max(p.x, rect.minX), rect.maxX)
        let y = min(max(p.y, rect.minY), rect.maxY)
        if x != p.x || y != p.y {
            logger.log(kind: "chokepoint.clamp.warn", detail: [
                "eventKind": kind,
                "sourceT": String(sourceT),
                "from": "\(p.x),\(p.y)",
                "to": "\(x),\(y)",
                "rect": "\(rect)"
            ])
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Frame-rate scaling

    /// Apply frame-rate scaling to a held-key duration. Spec § 6:
    /// `recordedFrameRate / runtimeFrameRate`, clamped to [0.5, 2.0].
    /// Applied at dispatch (not parse) so a runtime FPS sample correction
    /// affects the next event without re-reading the timeline.
    private func clampedFrameScale(seconds: Double, run: ActiveRun) -> TimeInterval {
        let recorded = run.bundle.manifest.recordedFrameRate ?? run.runtimeFrameRate
        let runtime = max(1.0, run.runtimeFrameRate)
        let raw = recorded / runtime
        let clamped = min(max(raw, Self.frameScaleMin), Self.frameScaleMax)
        return seconds * clamped
    }

    // MARK: - Cancel-aware sleep

    /// Sleep for `seconds`, polling cancellation every 50ms. Returns
    /// `false` if cancellation was requested mid-sleep — the run loop
    /// uses this as its early-exit signal.
    private func cancelAwareSleep(_ seconds: TimeInterval) -> Bool {
        let tick: TimeInterval = 0.05
        var remaining = seconds
        while remaining > 0 {
            if active?.cancelled == true { return false }
            let chunk = min(tick, remaining)
            Thread.sleep(forTimeInterval: chunk)
            remaining -= chunk
        }
        return active?.cancelled != true
    }

    // MARK: - Schedule helpers

    private func isInsideAnyWindow(_ schedule: [ScheduleWindow], now: Date) -> Bool {
        return schedule.contains { isInside($0, now: now) }
    }

    private func isInside(_ window: ScheduleWindow, now: Date) -> Bool {
        let cal = calendar(for: window.between.timezone)
        guard let from = parseHHMM(window.between.from, calendar: cal, anchor: now),
              let to = parseHHMM(window.between.to, calendar: cal, anchor: now) else {
            return false
        }
        // Wrap-across-midnight: if `to` < `from`, treat the window as
        // (from, end-of-day) ∪ (start-of-day, to).
        if to < from {
            return now >= from || now <= to
        }
        return now >= from && now <= to
    }

    private func nextWindowStart(_ schedule: [ScheduleWindow], after: Date) -> Date? {
        let starts = schedule.compactMap { window -> Date? in
            let cal = calendar(for: window.between.timezone)
            guard var start = parseHHMM(window.between.from, calendar: cal, anchor: after) else {
                return nil
            }
            if start <= after {
                start = cal.date(byAdding: .day, value: 1, to: start) ?? start
            }
            return start
        }
        return starts.min()
    }

    private func calendar(for tz: String?) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        if let tz, tz != "local", let zone = TimeZone(identifier: tz) {
            cal.timeZone = zone
        } else {
            cal.timeZone = TimeZone.current
        }
        return cal
    }

    private func parseHHMM(_ s: String, calendar: Calendar, anchor: Date) -> Date? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: anchor)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)
    }

    // MARK: - State transition

    private enum Transition {
        case finished
        case aborted(reason: EngineAbortReason)
        case failed(error: EngineError)
    }

    /// Tear down the active run. Stops capture, cancels the stopOn timer,
    /// transitions state, clears the active slot. Idempotent.
    private func stopActive(transition: Transition) {
        let logger = active?.logger
        if let timer = stopOnTimerSource {
            timer.cancel()
            stopOnTimerSource = nil
        }
        if let cap = active?.capture {
            // Capture is async-stoppable; fire-and-forget. The run is
            // ending anyway, and SCK's stopCapture is safe to await
            // detached.
            Task { try? await cap.stop() }
        }
        switch transition {
        case .finished:
            setState(.finished, logger: logger)
        case .aborted(let reason):
            setState(.aborted(reason: reason), logger: logger)
        case .failed(let error):
            setState(.failed(error: error), logger: logger)
        }
        active = nil
    }

    private func setState(_ new: EngineState, logger: EngineLogger?) {
        stateLock.lock()
        let prev = _state
        _state = new
        stateLock.unlock()
        logger?.log(kind: "state.transition", detail: [
            "from": String(describing: prev),
            "to": String(describing: new)
        ])
        // Bridge to MainActor for UI consumers. Capture the value before
        // hopping so the closure doesn't read a stale state if multiple
        // transitions land back-to-back.
        let snapshot = new
        Task { @MainActor [weak self] in
            self?.onStateChange?(snapshot)
        }
    }

    // MARK: - Helpers

    private func eventTime(_ e: TimelineEvent) -> Double {
        switch e {
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

    /// Translate a TimelineEvent button into the EventTap synth flavor.
    private static func mouseButton(from b: TimelineEvent.TimelineEventButton) -> EventTap.MouseButton {
        switch b {
        case .left:   return .left
        case .right:  return .right
        case .middle: return .middle
        }
    }

    /// Map a key-name string (as authored in YAML — e.g., "E", "Space",
    /// "Tab", "W", "ArrowUp") to a CGKeyCode-compatible UInt16. The map
    /// is intentionally minimal in 5a; missing keys log and synth as `0`
    /// (which is `kVK_ANSI_A` — wrong, but visibly wrong, and fixable
    /// with one PR rather than a schema bump). A complete map lands in
    /// /iterate alongside the editor's key-pick UI.
    private static func virtualKey(forName name: String) -> UInt16 {
        let n = name.uppercased()
        switch n {
        case "A": return 0x00
        case "S": return 0x01
        case "D": return 0x02
        case "F": return 0x03
        case "H": return 0x04
        case "G": return 0x05
        case "Z": return 0x06
        case "X": return 0x07
        case "C": return 0x08
        case "V": return 0x09
        case "B": return 0x0B
        case "Q": return 0x0C
        case "W": return 0x0D
        case "E": return 0x0E
        case "R": return 0x0F
        case "Y": return 0x10
        case "T": return 0x11
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "6": return 0x16
        case "5": return 0x17
        case "9": return 0x19
        case "7": return 0x1A
        case "8": return 0x1C
        case "0": return 0x1D
        case "O": return 0x1F
        case "U": return 0x20
        case "I": return 0x22
        case "P": return 0x23
        case "L": return 0x25
        case "J": return 0x26
        case "K": return 0x28
        case "N": return 0x2D
        case "M": return 0x2E
        case "RETURN", "ENTER":   return 0x24
        case "TAB":                return 0x30
        case "SPACE", "SPACEBAR":  return 0x31
        case "DELETE", "BACKSPACE": return 0x33
        case "ESC", "ESCAPE":      return 0x35
        case "ARROWLEFT", "LEFT":  return 0x7B
        case "ARROWRIGHT", "RIGHT":return 0x7C
        case "ARROWDOWN", "DOWN":  return 0x7D
        case "ARROWUP", "UP":      return 0x7E
        default: return 0x00
        }
    }

    // MARK: - Gate ref loader hook

    /// Override-point for loading gate ref images. 5a ships nil — the
    /// gate evaluator treats every gate as fail-soft until 5b (or
    /// /iterate, depending on bundle-IO ergonomics) wires this up. Tests
    /// can override with an in-memory loader to exercise the threshold +
    /// retry/onFail logic without disk fixtures.
    public var gateRefLoader: ((_ ref: String, _ kind: TimelineEvent.TimelineEventGateKind) -> CGImage?)?

    /// Compute similarity between observed and reference frames. Returns
    /// 0.0 when either input is missing or Vision rejects the pair —
    /// upstream callers treat that as "below threshold," so the run
    /// loop's retry/onFail logic still triggers cleanly.
    private func evaluateGateSimilarity(
        observed: CGImage?,
        reference: CGImage?
    ) -> Double {
        guard let observed, let reference else { return 0.0 }
        do {
            let obsRequest = VNGenerateImageFeaturePrintRequest()
            let refRequest = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(cgImage: observed, options: [:]).perform([obsRequest])
            try VNImageRequestHandler(cgImage: reference, options: [:]).perform([refRequest])
            guard let obs = obsRequest.results?.first as? VNFeaturePrintObservation,
                  let ref = refRequest.results?.first as? VNFeaturePrintObservation else {
                return 0.0
            }
            var distance: Float = 0
            try obs.computeDistance(&distance, to: ref)
            // VNFeaturePrintObservation.distance is unbounded above but
            // always ≥ 0. Map to similarity by clamping (1 - distance) to
            // [0, 1]. Empirically, identical pairs return ~0.0 and
            // unrelated pairs return >1.0 — the threshold tuning beat in
            // /iterate is where this clamp gets revisited.
            let raw = 1.0 - Double(distance)
            return min(max(raw, 0.0), 1.0)
        } catch {
            return 0.0
        }
    }
}

// MARK: - FrameCounter

/// Tiny shared counter for the pre-flight FPS sample. Lives outside the
/// engine class because it's bumped on SCK's queue and read on the engine
/// queue — keeping it in its own file-private type makes the threading
/// boundary obvious.
private final class FrameCounter {
    private let lock = NSLock()
    private var _count: Int = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
    func bump() {
        lock.lock(); _count += 1; lock.unlock()
    }
}
