// Recorder.swift
// Domain — capture-flow orchestrator.
//
// Drives SCKCapture + EventTap + Encoder in parallel, writes three
// synchronized streams to a working dir, and finalizes the working dir
// into a `.macro` bundle on stop. The `.macro` bundle is what hands off
// to EditorView (item 8); the editor authors gates from snapshots, the
// recorder produces a raw timeline only.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// (Capture → edit) + docs/spec.md > Recorder + docs/prd.md > Epic B.
//
// Threading discipline (per CLAUDE.md):
//   • SCK frame callback fires on SCKCapture's own queue; we forward
//     CMSampleBuffers to the Encoder there and stash the latest CGImage
//     under a lock for the snapshot writer.
//   • EventTap callback fires on its own dedicated thread; we hop onto
//     the recorder's serial queue before doing anything stateful.
//   • Recorder orchestration runs on `com.626labs.macRo.recorder` (a
//     dedicated serial queue).
//   • JSONL writes serialize on `…recorder.jsonl`.
//   • Snapshot PNG writes serialize on `…recorder.snapshots`.
//   • UI never touches recorder internals — `state` reads under a lock,
//     `onStateChange` fires on MainActor.
//
// Working dir layout (in-flight recording):
//   ~/Library/Application Support/macRo/Recordings/<UUID>/
//     raw-video.mov
//     raw-input.jsonl
//     snapshots/
//       <elapsed-ms>.png
//
// Finalize moves into the .macro bundle:
//   <bundle>/
//     manifest.yaml
//     timeline.yaml
//     gates/
//       snap-<elapsed-ms>.png      (every snapshot, available to editor)
//     raw-video.mov                (preserved alongside; the editor's
//                                   trim/cut will produce preview.mp4 in
//                                   /iterate)
//
// HUD-CLICK FILTER:
//   The HUD is a macRo NSWindow on top of the screen. EventTap's tap
//   doesn't know about it. Solution: the UI layer (RecorderHUD in 7b)
//   calls `setOwnWindowFrames([NSRect])` whenever its frame changes.
//   Every input event whose location falls inside any of those frames
//   is dropped from the JSONL before it reaches disk. Mouse-only filter
//   is sufficient — the HUD doesn't capture keys.

import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox
import Yams

// MARK: - GameSelection

/// What game the user is recording for. Drives the manifest's `game.name`,
/// `target.windowClass`, and `target.windowTitleMatch`. The PluginLoader
/// (item 10) will replace this enum with a richer plugin-driven type;
/// for v1 the two known cases are inlined here.
public enum GameSelection: Equatable, Sendable {
    /// Pet Simulator 99 — placeId 8737899170. v1 anchor game.
    case ps99
    /// Generic Roblox window — no game-specific selectors.
    case untagged

    /// Canonical Roblox window matchers. Both selections target the
    /// Roblox client; PS99 narrows the title regex once the user is in
    /// the place.
    public var windowClass: [String] {
        return ["Roblox", "com.Roblox.client"]
    }

    /// Title regex passed to WindowDetector. **Both PS99 and untagged
    /// match on "Roblox"** — the macOS Roblox client window title is
    /// always just "Roblox" regardless of which place is loaded; the
    /// game name is rendered INSIDE the Roblox window content area,
    /// never in the title bar. The `placeId` field is what identifies
    /// PS99 specifically (8737899170); window matching is the same for
    /// every Roblox game on Mac. Pre-2026-05-05 this returned
    /// "Pet Simulator 99" for `.ps99` and never matched in practice.
    public var windowTitleMatch: String {
        return "Roblox"
    }

    /// Display name for `manifest.game.name`.
    public var displayName: String {
        switch self {
        case .ps99:    return "Pet Simulator 99"
        case .untagged: return "Roblox"
        }
    }

    /// Optional Roblox placeId. PS99's is canonical; untagged omits it.
    public var placeId: Int? {
        switch self {
        case .ps99:    return 8737899170
        case .untagged: return nil
        }
    }

    /// Game-slug used in bundle paths and library directories.
    public var slug: String {
        switch self {
        case .ps99:    return "pet-sim-99"
        case .untagged: return "untagged"
        }
    }
}

// MARK: - RecorderState

/// Recorder lifecycle. Mirrors Engine.State's terminal-aware shape.
public enum RecorderState: Equatable {
    case idle
    case preflight
    case recording
    case finalizing
    case finished(bundleURL: URL)
    case failed(error: RecorderError)

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed: return true
        default: return false
        }
    }
}

// MARK: - RecorderError

/// Typed errors thrown / surfaced by the recorder. Cases carry the
/// minimum context to render a human-readable message at the failure
/// site.
public enum RecorderError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case accessibilityDenied
    case screenRecordingDenied
    case windowNotFound(matcher: String)
    case workingDirSetupFailed(message: String)
    case captureStartFailed(message: String)
    case eventTapStartFailed(message: String)
    case encoderStartFailed(message: String)
    case finalizeFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recorder.startRecording() called while a session is already active."
        case .notRecording:
            return "Recorder.stopRecording() called with no active session."
        case .accessibilityDenied:
            return "Accessibility permission is required to record input. Re-grant in System Settings → Privacy & Security → Accessibility."
        case .screenRecordingDenied:
            return "Screen Recording permission is required to record video. Re-grant in System Settings → Privacy & Security → Screen Recording."
        case .windowNotFound(let matcher):
            return "Could not find a Roblox window matching \(matcher). Open the game and try again."
        case .workingDirSetupFailed(let msg):
            return "Could not set up the recording working directory: \(msg)"
        case .captureStartFailed(let msg):
            return "Screen capture failed to start: \(msg)"
        case .eventTapStartFailed(let msg):
            return "Input event tap failed to start: \(msg)"
        case .encoderStartFailed(let msg):
            return "Video encoder failed to start: \(msg)"
        case .finalizeFailed(let msg):
            return "Recording finalize failed: \(msg)"
        }
    }
}

// MARK: - WorkingDirArtifacts

/// Names + URLs of the three synchronized stream files inside a working
/// directory. Public so the editor can read the working dir directly when
/// a draft handoff lands.
public struct WorkingDirArtifacts: Equatable, Sendable {
    public let root: URL
    public let videoURL: URL
    public let inputJSONLURL: URL
    public let snapshotsDir: URL

    public init(root: URL) {
        self.root = root
        self.videoURL = root.appendingPathComponent("raw-video.mov")
        self.inputJSONLURL = root.appendingPathComponent("raw-input.jsonl")
        self.snapshotsDir = root.appendingPathComponent("snapshots", isDirectory: true)
    }
}

// MARK: - Input log line shape

/// One line of `raw-input.jsonl`. Every line has `t` (seconds from
/// recording start) and `kind`; kind-specific fields mirror EventTap's
/// RawInputEvent surface. Coordinates are window-relative (translated
/// from screen-space at record time using the captured Roblox window
/// content rect).
struct RawInputLine: Encodable {
    let t: Double
    let kind: String
    /// keyDown / keyUp / flagsChanged — virtual keycode (UInt16).
    let keyCode: UInt16?
    /// keyDown / keyUp — modifier flag bitmask snapshot.
    let flags: UInt64?
    /// click — "left" | "right" | "middle".
    let button: String?
    /// click — "down" | "up" — paired-event marker.
    let phase: String?
    /// click — window-relative x/y in points.
    let x: Double?
    let y: Double?
    /// cameraDelta — relative dx/dy in points.
    let dx: Double?
    let dy: Double?
}

// MARK: - Recorder

/// THE recorder. Singleton-style to mirror Engine.shared and because a
/// recording-in-progress is a unique app-wide state.
public final class Recorder {

    // MARK: - Singleton

    public static let shared = Recorder()
    private init() {}

    // MARK: - Constants

    /// Snapshot cadence: every input event AND every 1 second.
    public static let snapshotIntervalSeconds: TimeInterval = 1.0

    /// Target capture frame rate. Matches SCK default.
    public static let captureFrameRate: Int = 60

    // MARK: - Queues

    /// THE recorder queue. Single dedicated serial — every state mutation
    /// runs here, every fan-in from SCK / EventTap callbacks hops here
    /// first. Labelled per CLAUDE.md convention.
    private let queue = DispatchQueue(
        label: "com.626labs.macRo.recorder",
        qos: .userInteractive
    )

    /// JSONL writes serialize on this queue so input lines land in
    /// submission order regardless of which thread wrote them.
    private let jsonlQueue = DispatchQueue(
        label: "com.626labs.macRo.recorder.jsonl",
        qos: .utility
    )

    /// Snapshot PNG writes serialize here. Separate from JSONL so a slow
    /// PNG encode doesn't stall the input log.
    private let snapshotQueue = DispatchQueue(
        label: "com.626labs.macRo.recorder.snapshots",
        qos: .utility
    )

    // MARK: - State

    private var _state: RecorderState = .idle
    private let stateLock = NSLock()

    /// Public read-only state. Snapshots under the lock.
    public var state: RecorderState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    /// Optional state-change observer. RecorderHUD wires this in 7b.
    /// Called on MainActor so UI consumers don't bounce queues.
    @MainActor public var onStateChange: ((RecorderState) -> Void)?

    // MARK: - HUD-click filter — own-window frames

    /// Set of NSRects (screen-space, Cocoa coords) covering macRo's own
    /// windows during recording. The EventTap callback consults this
    /// list before writing an input event to the JSONL — any event whose
    /// screen-space location falls inside any frame is dropped.
    ///
    /// Caller (RecorderHUD in 7b) updates this whenever the HUD's frame
    /// changes (drag, resize, NSWorkspace activation). Multiple frames
    /// supported because future overlays (countdown sheet, etc.) may
    /// stack with the HUD.
    private var ownWindowFrames: [NSRect] = []
    private let ownWindowFramesLock = NSLock()

    /// Update the set of frames to filter against. Pass an empty array to
    /// clear (e.g., when the HUD closes). Safe to call from any thread.
    public func setOwnWindowFrames(_ frames: [NSRect]) {
        ownWindowFramesLock.lock()
        ownWindowFrames = frames
        ownWindowFramesLock.unlock()
    }

    private func screenLocationIsOwnWindow(_ loc: CGPoint) -> Bool {
        ownWindowFramesLock.lock()
        let frames = ownWindowFrames
        ownWindowFramesLock.unlock()
        for frame in frames {
            if frame.contains(loc) { return true }
        }
        return false
    }

    // MARK: - Active-run state (recorder queue only)

    /// Per-recording state. Held as a class so helpers don't need inout
    /// ceremony and so the SCK frame callback can mutate `latestFrame`
    /// under its own lock without copy-and-reassign across threads.
    private final class ActiveSession {
        let recordingID: UUID
        let game: GameSelection
        let workingDir: URL
        let artifacts: WorkingDirArtifacts
        let startedAt: CFAbsoluteTime
        var window: WindowDetector.WindowInfo
        let captureSize: CGSize

        let capture: SCKCapture
        let eventTap: EventTap
        let encoder: Encoder

        let jsonlHandle: FileHandle
        var snapshotTimer: DispatchSourceTimer?

        /// Frame counter for FPS measurement (used to fill
        /// `manifest.recordedFrameRate` at finalize time).
        var frameCount: Int = 0
        let frameCountLock = NSLock()

        /// Latest CGImage delivered by SCK. Read by the snapshot writer
        /// and the per-input-event snapshot path. Mutation on SCK queue,
        /// reads on snapshot queue.
        private var _latestFrame: CGImage?
        private let frameLock = NSLock()

        var latestFrame: CGImage? {
            frameLock.lock(); defer { frameLock.unlock() }
            return _latestFrame
        }

        func setLatestFrame(_ image: CGImage) {
            frameLock.lock(); _latestFrame = image; frameLock.unlock()
        }

        /// Set of snapshot filenames already written this session, so
        /// duplicate-timestamp writes (input + 1s tick on the same ms)
        /// don't race the file system. Mutated only on snapshotQueue.
        var snapshotsWritten = Set<String>()

        init(
            recordingID: UUID,
            game: GameSelection,
            workingDir: URL,
            artifacts: WorkingDirArtifacts,
            startedAt: CFAbsoluteTime,
            window: WindowDetector.WindowInfo,
            captureSize: CGSize,
            capture: SCKCapture,
            eventTap: EventTap,
            encoder: Encoder,
            jsonlHandle: FileHandle
        ) {
            self.recordingID = recordingID
            self.game = game
            self.workingDir = workingDir
            self.artifacts = artifacts
            self.startedAt = startedAt
            self.window = window
            self.captureSize = captureSize
            self.capture = capture
            self.eventTap = eventTap
            self.encoder = encoder
            self.jsonlHandle = jsonlHandle
        }
    }

    private var active: ActiveSession?

    // MARK: - Public API — start

    /// Begin a recording. Pre-flight checks Accessibility + Screen
    /// Recording grants, finds the target window, sets up the working
    /// dir, and starts SCK + EventTap + Encoder in parallel. Returns
    /// when all three streams are flowing.
    ///
    /// Concurrent calls fail with `.alreadyRecording`.
    public func startRecording(game: GameSelection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: RecorderError.captureStartFailed(
                        message: "Recorder deallocated before start could complete."
                    ))
                    return
                }
                Task { [self] in
                    do {
                        try await self.startOnQueueAsync(game: game)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Start path running on the recorder queue. Async because SCK's
    /// shareable-content enumeration is async; we keep all state writes
    /// either on the recorder queue (via `queue.sync`) or on this
    /// task — the singleton already serializes via `_state` guards.
    private func startOnQueueAsync(game: GameSelection) async throws {
        // Idempotency / state guard.
        let currentState = self.state
        if case .recording = currentState {
            throw RecorderError.alreadyRecording
        }
        if case .preflight = currentState {
            throw RecorderError.alreadyRecording
        }
        if case .finalizing = currentState {
            throw RecorderError.alreadyRecording
        }

        await setStateAsync(.preflight)

        // Pre-flight 1 — permissions. Use Permissions' read-only AX trust
        // check; SCK enumerates and surfaces .screenRecordingDenied as
        // its own error.
        if !AXIsProcessTrusted() {
            await setStateAsync(.failed(error: .accessibilityDenied))
            throw RecorderError.accessibilityDenied
        }

        // Pre-flight 2 — find the Roblox window.
        let match = WindowDetector.Match(
            windowClass: game.windowClass,
            titleMatch: game.windowTitleMatch
        )
        let windowInfo: WindowDetector.WindowInfo
        do {
            guard let info = try WindowDetector.find(match) else {
                let err = RecorderError.windowNotFound(matcher: game.windowTitleMatch)
                await setStateAsync(.failed(error: err))
                throw err
            }
            windowInfo = info
        } catch WindowDetector.WindowDetectorError.accessibilityDenied {
            await setStateAsync(.failed(error: .accessibilityDenied))
            throw RecorderError.accessibilityDenied
        } catch {
            let err = RecorderError.windowNotFound(matcher: game.windowTitleMatch)
            await setStateAsync(.failed(error: err))
            throw err
        }

        // Pre-flight 3 — SCK shareable window. SCK's enumeration is the
        // canonical Screen Recording check; if the grant is missing this
        // throws `.screenRecordingDenied`.
        let sckWindow: SCWindow
        do {
            guard let win = try await SCKCapture.findWindow(matching: match) else {
                let err = RecorderError.windowNotFound(matcher: game.windowTitleMatch)
                await setStateAsync(.failed(error: err))
                throw err
            }
            sckWindow = win
        } catch SCKCapture.SCKCaptureError.screenRecordingDenied {
            await setStateAsync(.failed(error: .screenRecordingDenied))
            throw RecorderError.screenRecordingDenied
        } catch {
            let err = RecorderError.captureStartFailed(message: error.localizedDescription)
            await setStateAsync(.failed(error: err))
            throw err
        }

        // Pre-flight 4 — working dir.
        let recordingID = UUID()
        let workingDir = Recorder.recordingsDirectory.appendingPathComponent(
            recordingID.uuidString,
            isDirectory: true
        )
        let artifacts = WorkingDirArtifacts(root: workingDir)
        do {
            try FileManager.default.createDirectory(
                at: workingDir,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: artifacts.snapshotsDir,
                withIntermediateDirectories: true
            )
            // Touch the JSONL file so we can hold an append-only handle.
            FileManager.default.createFile(
                atPath: artifacts.inputJSONLURL.path,
                contents: nil
            )
        } catch {
            let err = RecorderError.workingDirSetupFailed(message: error.localizedDescription)
            await setStateAsync(.failed(error: err))
            throw err
        }

        let jsonlHandle: FileHandle
        do {
            jsonlHandle = try FileHandle(forWritingTo: artifacts.inputJSONLURL)
        } catch {
            let err = RecorderError.workingDirSetupFailed(message: error.localizedDescription)
            await setStateAsync(.failed(error: err))
            throw err
        }

        // Pre-flight 5 — encoder.
        let captureSize = CGSize(
            width: sckWindow.frame.width,
            height: sckWindow.frame.height
        )
        let encoder = Encoder(
            outputURL: artifacts.videoURL,
            size: captureSize,
            frameRate: Recorder.captureFrameRate
        )
        do {
            try encoder.start()
        } catch {
            try? jsonlHandle.close()
            let err = RecorderError.encoderStartFailed(message: error.localizedDescription)
            await setStateAsync(.failed(error: err))
            throw err
        }

        // Pre-flight 6 — SCK capture.
        let capture = SCKCapture(window: sckWindow, frameRate: Recorder.captureFrameRate)

        // Pre-flight 7 — EventTap.
        let eventTap = EventTap()

        // Build active session up-front so callbacks can address it via
        // `self.active`. The session takes effect once SCK + EventTap
        // both succeed.
        let session = ActiveSession(
            recordingID: recordingID,
            game: game,
            workingDir: workingDir,
            artifacts: artifacts,
            startedAt: CFAbsoluteTimeGetCurrent(),
            window: windowInfo,
            captureSize: captureSize,
            capture: capture,
            eventTap: eventTap,
            encoder: encoder,
            jsonlHandle: jsonlHandle
        )

        // Wire SCK → encoder + latest-frame stash. Fires on SCK's queue.
        do {
            try await capture.start { [weak session] sample in
                guard let session else { return }
                // Encoder back-pressure handled inside Encoder.append.
                try? session.encoder.append(sample)
                // Bump frame counter for FPS.
                session.frameCountLock.lock()
                session.frameCount += 1
                session.frameCountLock.unlock()
                // Stash latest CGImage for snapshots.
                if let image = Self.cgImage(from: sample) {
                    session.setLatestFrame(image)
                }
            }
        } catch SCKCapture.SCKCaptureError.screenRecordingDenied {
            try? await encoder.finish()  // best-effort teardown
            try? jsonlHandle.close()
            await setStateAsync(.failed(error: .screenRecordingDenied))
            throw RecorderError.screenRecordingDenied
        } catch {
            try? jsonlHandle.close()
            let err = RecorderError.captureStartFailed(message: error.localizedDescription)
            await setStateAsync(.failed(error: err))
            throw err
        }

        // Wire EventTap → JSONL. Fires on EventTap's dedicated thread.
        // Hop onto jsonlQueue to serialize writes; HUD-frame filter runs
        // on the EventTap thread (cheap, lock-protected read).
        do {
            try eventTap.startRecording { [weak self, weak session] event in
                guard let self, let session else { return }
                self.handleRawInputEvent(event, session: session)
            }
        } catch EventTap.EventTapError.accessibilityDenied {
            try? await capture.stop()
            try? await encoder.finish()
            try? jsonlHandle.close()
            await setStateAsync(.failed(error: .accessibilityDenied))
            throw RecorderError.accessibilityDenied
        } catch {
            try? await capture.stop()
            try? await encoder.finish()
            try? jsonlHandle.close()
            let err = RecorderError.eventTapStartFailed(message: error.localizedDescription)
            await setStateAsync(.failed(error: err))
            throw err
        }

        // Install on the recorder queue.
        queue.sync {
            self.active = session
        }

        // Start the 1-second snapshot timer.
        startSnapshotTimer(session: session)

        await setStateAsync(.recording)
    }

    // MARK: - Public API — stop

    /// Finalize the recording. Stops SCK + EventTap + Encoder, drains
    /// pending writes, packages the working dir into a `.macro` bundle,
    /// returns the bundle URL.
    ///
    /// preview.mp4 is intentionally deferred to /iterate — the bundle's
    /// `raw-video.mov` is preserved alongside so the editor can produce
    /// the preview when the user trims the timeline.
    @discardableResult
    public func stopRecording() async throws -> URL {
        // Snapshot the active session under the recorder queue.
        let session: ActiveSession? = queue.sync { self.active }
        guard let session else {
            throw RecorderError.notRecording
        }

        await setStateAsync(.finalizing)

        // 1. Stop the snapshot timer immediately so no further snapshots
        //    queue.
        if let timer = session.snapshotTimer {
            timer.cancel()
            session.snapshotTimer = nil
        }

        // 2. Stop EventTap before SCK so any in-flight input events have
        //    a chance to land in the JSONL. EventTap stop is synchronous.
        do {
            try session.eventTap.stopRecording()
        } catch {
            // Non-fatal: tap may already be torn down. Log via stderr
            // would be ideal but we don't have a logger here; fall
            // through and continue finalize.
        }

        // 3. Stop SCK. SCK's stop is async.
        do {
            try await session.capture.stop()
        } catch {
            // Same as above — best-effort.
        }

        // 4. Finalize the encoder.
        do {
            try await session.encoder.finish()
        } catch {
            let err = RecorderError.finalizeFailed(message: error.localizedDescription)
            await setStateAsync(.failed(error: err))
            throw err
        }

        // 5. Drain pending JSONL writes by hopping a sync barrier through
        //    the JSONL queue. Anything submitted before this point will
        //    have run; nothing new can submit because the EventTap is
        //    stopped.
        jsonlQueue.sync { /* drain barrier */ }
        // Same for snapshots — flush before reading the snapshots dir.
        snapshotQueue.sync { /* drain barrier */ }

        // 6. Close the JSONL handle.
        try? session.jsonlHandle.close()

        // 7. Compute observed FPS for the manifest.
        let elapsed = CFAbsoluteTimeGetCurrent() - session.startedAt
        let observedFrames: Int = {
            session.frameCountLock.lock(); defer { session.frameCountLock.unlock() }
            return session.frameCount
        }()
        let recordedFrameRate: Double = elapsed > 0
            ? Double(observedFrames) / elapsed
            : Double(Recorder.captureFrameRate)

        // 8. Package working dir → .macro bundle.
        let bundleURL: URL
        do {
            bundleURL = try finalizeWorkingDir(
                session: session,
                recordedFrameRate: recordedFrameRate
            )
        } catch {
            let err = RecorderError.finalizeFailed(message: error.localizedDescription)
            await setStateAsync(.failed(error: err))
            throw err
        }

        // 9. Drop the active session reference.
        queue.sync {
            self.active = nil
        }

        await setStateAsync(.finished(bundleURL: bundleURL))
        return bundleURL
    }

    // MARK: - Public API — abort

    /// Tear down everything quickly and delete the working dir. Used
    /// when the user cancels recording or when a pre-flight failure
    /// leaves a partial working dir behind. Idempotent — safe to call
    /// from any state.
    public func abort() async throws {
        let session: ActiveSession? = queue.sync { self.active }

        if let session {
            if let timer = session.snapshotTimer {
                timer.cancel()
                session.snapshotTimer = nil
            }
            try? session.eventTap.stopRecording()
            try? await session.capture.stop()
            try? await session.encoder.finish()
            try? session.jsonlHandle.close()
            try? FileManager.default.removeItem(at: session.workingDir)
            queue.sync {
                self.active = nil
            }
        }

        await setStateAsync(.idle)
    }

    // MARK: - Input event handling

    /// Translate a RawInputEvent into a JSONL line, applying the HUD-
    /// click filter and window-relative coord translation. Fires on
    /// EventTap's dedicated thread; the actual disk write hops onto
    /// jsonlQueue so writes serialize in submission order.
    ///
    /// Also schedules an on-event snapshot via snapshotQueue.
    private func handleRawInputEvent(_ event: EventTap.RawInputEvent, session: ActiveSession) {
        let now = CFAbsoluteTimeGetCurrent()
        let t = now - session.startedAt
        let elapsedMs = Int(t * 1000.0)

        // HUD-click filter: drop any mouse event whose screen-space
        // location lands inside one of macRo's own window frames.
        switch event {
        case .mouseDown(_, let loc, _),
             .mouseUp(_, let loc, _),
             .mouseMoved(let loc, _, _, _):
            if screenLocationIsOwnWindow(loc) {
                return
            }
        case .keyDown, .keyUp:
            break
        }

        // Translate screen-space mouse coords to window-relative. AX
        // returns Cocoa origin (bottom-left); EventTap's CGEvent.location
        // is global screen-space (top-left origin per CGEvent docs). We
        // store window-relative coords in the recorder's own convention:
        // (0,0) at the window's top-left, +x right, +y down — matches
        // MacroFormat.click's "window-relative" contract and the engine's
        // synthesis-time expectation.
        let line: RawInputLine
        let windowRect = session.window.contentRect

        switch event {
        case .keyDown(let keyCode, let flags, _):
            line = RawInputLine(
                t: t, kind: "keyDown",
                keyCode: keyCode, flags: flags.rawValue,
                button: nil, phase: nil,
                x: nil, y: nil, dx: nil, dy: nil
            )

        case .keyUp(let keyCode, let flags, _):
            line = RawInputLine(
                t: t, kind: "keyUp",
                keyCode: keyCode, flags: flags.rawValue,
                button: nil, phase: nil,
                x: nil, y: nil, dx: nil, dy: nil
            )

        case .mouseDown(let button, let loc, _):
            let rel = Self.windowRelative(loc, windowRect: windowRect)
            line = RawInputLine(
                t: t, kind: "click",
                keyCode: nil, flags: nil,
                button: button.rawValue, phase: "down",
                x: rel.x, y: rel.y, dx: nil, dy: nil
            )

        case .mouseUp(let button, let loc, _):
            let rel = Self.windowRelative(loc, windowRect: windowRect)
            line = RawInputLine(
                t: t, kind: "click",
                keyCode: nil, flags: nil,
                button: button.rawValue, phase: "up",
                x: rel.x, y: rel.y, dx: nil, dy: nil
            )

        case .mouseMoved(_, let dx, let dy, _):
            line = RawInputLine(
                t: t, kind: "cameraDelta",
                keyCode: nil, flags: nil,
                button: nil, phase: nil,
                x: nil, y: nil, dx: dx, dy: dy
            )
        }

        // Hop to JSONL queue for write.
        let handle = session.jsonlHandle
        jsonlQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(line)
                guard let str = String(data: data, encoding: .utf8) else { return }
                let bytes = (str + "\n").data(using: .utf8) ?? Data()
                try? handle.seekToEnd()
                try? handle.write(contentsOf: bytes)
            } catch {
                // Encoder failure here would be a Swift-level bug — drop
                // the line silently, preserve the recording.
            }
        }

        // On every input event, also write a snapshot (per spec § 5).
        scheduleSnapshot(session: session, elapsedMs: elapsedMs)
    }

    // MARK: - Snapshots

    /// Start the 1-second snapshot tick. Fires on snapshotQueue.
    private func startSnapshotTimer(session: ActiveSession) {
        let timer = DispatchSource.makeTimerSource(queue: snapshotQueue)
        timer.schedule(
            deadline: .now() + Recorder.snapshotIntervalSeconds,
            repeating: Recorder.snapshotIntervalSeconds
        )
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let elapsedMs = Int((now - session.startedAt) * 1000.0)
            self.writeSnapshot(session: session, elapsedMs: elapsedMs)
        }
        timer.resume()
        session.snapshotTimer = timer
    }

    /// Hop onto snapshotQueue and write the latest frame as a PNG named
    /// `<elapsed-ms>.png` (zero-padded to 8 digits for stable sort
    /// order). De-duplicated by filename so an input-event snapshot
    /// landing on the same ms as a 1s tick doesn't double-write.
    private func scheduleSnapshot(session: ActiveSession, elapsedMs: Int) {
        snapshotQueue.async { [weak self, weak session] in
            guard let self, let session else { return }
            self.writeSnapshot(session: session, elapsedMs: elapsedMs)
        }
    }

    /// Write the latest CGImage to disk as a PNG. Called only from
    /// snapshotQueue.
    private func writeSnapshot(session: ActiveSession, elapsedMs: Int) {
        let filename = String(format: "%08d.png", max(0, elapsedMs))
        if session.snapshotsWritten.contains(filename) { return }
        guard let image = session.latestFrame else { return }
        let url = session.artifacts.snapshotsDir.appendingPathComponent(filename)
        if Self.writePNG(image: image, to: url) {
            session.snapshotsWritten.insert(filename)
        }
    }

    // MARK: - Finalize

    /// Move the working dir into a final `.macro` bundle and write the
    /// manifest + timeline yaml files. Snapshots are copied (renamed
    /// `snap-<ms>.png`) into the bundle's `gates/` directory so the
    /// editor (item 8) can pick from them when authoring image gates.
    /// raw-video.mov is preserved alongside so the editor can trim into
    /// preview.mp4 in /iterate.
    private func finalizeWorkingDir(
        session: ActiveSession,
        recordedFrameRate: Double
    ) throws -> URL {
        let fm = FileManager.default

        // Generate the bundle's final URL. Convention:
        //   ~/Library/Application Support/macRo/Library/<game-slug>/<macro-id>.macro
        // For 7a we deposit into Library/<slug>/; the editor (item 8)
        // can move it on save if the user renames.
        let macroID = "rec-\(session.recordingID.uuidString.lowercased().prefix(8))"
        let displayName = "Recording \(Self.iso8601MinuteFormatter.string(from: Date()))"
        let bundleName = "\(macroID).macro"
        let libraryRoot = Recorder.libraryDirectory
            .appendingPathComponent(session.game.slug, isDirectory: true)
        let bundleURL = libraryRoot.appendingPathComponent(bundleName, isDirectory: true)

        try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        // If a stale bundle exists under the same name (collision is
        // unlikely with UUID prefix but possible), remove it.
        if fm.fileExists(atPath: bundleURL.path) {
            try fm.removeItem(at: bundleURL)
        }
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let gatesDir = bundleURL.appendingPathComponent(MacroBundle.FileName.gates, isDirectory: true)
        try fm.createDirectory(at: gatesDir, withIntermediateDirectories: true)

        // 1. Build the Manifest.
        let manifest = Manifest(
            id: macroID,
            name: displayName,
            description: nil,
            author: nil,
            version: "1.0.0",
            schemaVersion: 1,
            factoryPatchable: false,
            estimatedRuntime: nil,
            recordedFrameRate: recordedFrameRate,
            maxRuntimeHours: nil,
            game: GameTag(
                placeId: session.game.placeId,
                name: session.game.displayName,
                versionDetectedAt: nil,
                versionFingerprint: nil
            ),
            target: Target(
                windowClass: session.game.windowClass,
                windowTitleMatch: session.game.windowTitleMatch,
                coordinateSpace: .window,
                recordedResolution: Target.TargetRecordedResolution(
                    width: Int(session.captureSize.width),
                    height: Int(session.captureSize.height)
                ),
                resolutionPolicy: .scale
            ),
            requires: nil,
            schedule: nil,
            patchHistory: nil
        )

        // 2. Build the Timeline by replaying the JSONL.
        let timelineEvents = try replayJSONL(at: session.artifacts.inputJSONLURL)
        let timeline = Timeline(
            events: timelineEvents,
            stopOn: nil,
            subs: nil
        )

        let bundle = MacroBundleData(manifest: manifest, timeline: timeline)

        // 3. Save manifest + timeline yaml. Skip MacroBundle.save's
        //    cross-ref pass — we have no gates yet, but `validate(_:)`
        //    runs with availableGateRefs=nil at load time so this is
        //    safe.
        try MacroBundle.save(bundle, to: bundleURL)

        // 4. Copy raw-video.mov into the bundle alongside the yaml files.
        //    Editor can trim to preview.mp4 in /iterate.
        let bundleVideoURL = bundleURL.appendingPathComponent("raw-video.mov")
        if fm.fileExists(atPath: session.artifacts.videoURL.path) {
            try? fm.copyItem(at: session.artifacts.videoURL, to: bundleVideoURL)
        }

        // 5. Copy every snapshot into gates/ as snap-<ms>.png. Editor
        //    surfaces these for image-gate authoring; the snap- prefix
        //    keeps them clearly distinct from real img-/pos- gate refs.
        let snapshotURLs = (try? fm.contentsOfDirectory(
            at: session.artifacts.snapshotsDir,
            includingPropertiesForKeys: nil
        )) ?? []
        for src in snapshotURLs where src.pathExtension.lowercased() == "png" {
            let basename = src.deletingPathExtension().lastPathComponent
            let dest = gatesDir.appendingPathComponent("snap-\(basename).png")
            try? fm.copyItem(at: src, to: dest)
        }

        // 6. Remove the working dir now that everything is preserved in
        //    the bundle.
        try? fm.removeItem(at: session.workingDir)

        return bundleURL
    }

    // MARK: - JSONL replay

    /// Parse the JSONL produced during recording into a list of
    /// TimelineEvent values. Coalesces phase=down/up `click` lines into
    /// a single `click` (timeline) at the down-phase time; bare `keyUp`
    /// lines pair to keyDown lines via keyCode equality. Ungainly but
    /// straightforward; happy path for v1.
    ///
    /// Errors during replay throw; the caller treats this as a finalize
    /// failure (working dir is preserved on the disk for triage).
    private func replayJSONL(at url: URL) throws -> [TimelineEvent] {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw RecorderError.finalizeFailed(message: "Could not read raw-input.jsonl: \(error.localizedDescription)")
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        var events: [TimelineEvent] = []
        let decoder = JSONDecoder()

        for line in lines {
            let data = Data(line.utf8)
            let parsed: RawInputLineDecodable
            do {
                parsed = try decoder.decode(RawInputLineDecodable.self, from: data)
            } catch {
                // Skip malformed lines — preserve the rest of the
                // recording. A finalize-time hard fail on a single bad
                // line would lose the user's work.
                continue
            }

            switch parsed.kind {
            case "keyDown":
                if let code = parsed.keyCode {
                    let key = Self.keyName(forCode: code)
                    events.append(.keyDown(.init(t: parsed.t, key: key)))
                }
            case "keyUp":
                if let code = parsed.keyCode {
                    let key = Self.keyName(forCode: code)
                    events.append(.keyUp(.init(t: parsed.t, key: key)))
                }
            case "click":
                // Emit click only on the down-phase line; up-phase is
                // implicit in the engine's run loop (which clicks
                // mouse-down + immediately mouse-up at the same coord
                // for v1). The full down/up round-trip belongs in the
                // editor's inspector when "hold" semantics are needed.
                if parsed.phase == "down",
                   let x = parsed.x,
                   let y = parsed.y,
                   let buttonStr = parsed.button,
                   let button = TimelineEvent.TimelineEventButton(rawValue: buttonStr) {
                    events.append(.click(.init(
                        t: parsed.t,
                        x: x, y: y,
                        button: button,
                        jitterMs: nil
                    )))
                }
            case "cameraDelta":
                if let dx = parsed.dx, let dy = parsed.dy {
                    events.append(.cameraDelta(.init(
                        t: parsed.t,
                        dx: dx, dy: dy,
                        duration: 0.0
                    )))
                }
            default:
                continue
            }
        }
        return events
    }

    /// Decodable mirror of RawInputLine. Separate type so we can decode
    /// without exposing RawInputLine's encode-only conformance.
    private struct RawInputLineDecodable: Decodable {
        let t: Double
        let kind: String
        let keyCode: UInt16?
        let flags: UInt64?
        let button: String?
        let phase: String?
        let x: Double?
        let y: Double?
        let dx: Double?
        let dy: Double?
    }

    // MARK: - State helpers

    /// Mutate _state under the lock and fire onStateChange on MainActor.
    @MainActor private func setState(_ new: RecorderState) {
        stateLock.lock()
        _state = new
        stateLock.unlock()
        onStateChange?(new)
    }

    /// Async-friendly setState. Hops onto MainActor before mutating so
    /// the @MainActor onStateChange callback runs on main.
    private func setStateAsync(_ new: RecorderState) async {
        await MainActor.run {
            self.setState(new)
        }
    }

    // MARK: - Path helpers

    /// In-flight recordings live here. Each recording is a UUID
    /// subdirectory.
    public static var recordingsDirectory: URL {
        return appSupportRoot
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Final library root. Bundles land at
    /// `<libraryDirectory>/<game-slug>/<macro-id>.macro/`.
    public static var libraryDirectory: URL {
        return appSupportRoot
            .appendingPathComponent("Library", isDirectory: true)
    }

    private static var appSupportRoot: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("macRo", isDirectory: true)
    }

    // MARK: - Coord translation

    /// Translate a screen-space CGPoint (top-left origin per CGEvent
    /// docs) to window-relative coords (top-left origin of the window's
    /// content rect, +x right, +y down). The window's contentRect is in
    /// Cocoa coords (bottom-left origin) — flip Y against the primary
    /// screen height.
    private static func windowRelative(_ screenPoint: CGPoint, windowRect: NSRect) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Convert window's bottom-left origin to a top-left origin frame.
        let windowTopLeftY = primaryHeight - windowRect.origin.y - windowRect.height
        let windowTopLeft = CGPoint(x: windowRect.origin.x, y: windowTopLeftY)
        return CGPoint(
            x: screenPoint.x - windowTopLeft.x,
            y: screenPoint.y - windowTopLeft.y
        )
    }

    // MARK: - PNG writer

    /// Encode a CGImage as PNG and write to `url`. Returns true on
    /// success. Failures are silent (snapshots are best-effort).
    private static func writePNG(image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - CMSampleBuffer → CGImage

    /// Convert one SCK sample buffer to a CGImage for snapshot writing.
    /// Returns nil if the conversion fails (rare; back-pressure or
    /// unusable buffers).
    private static func cgImage(from buffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }

    // MARK: - Key code → key name

    /// Reverse of Engine.virtualKey(forName:). Recording captures
    /// keycodes (UInt16); MacroFormat's keyDown/keyUp payload uses the
    /// human-readable key string. Unknown codes round-trip as `?<code>`
    /// so the editor can spot them and offer a remapping. Mirror of
    /// Engine.swift's table — the editor's key-pick UI in /iterate is
    /// where this gets a complete map. v1 covers the ASCII letters,
    /// digits, and common control keys.
    private static func keyName(forCode code: UInt16) -> String {
        switch code {
        case 0x00: return "A"
        case 0x01: return "S"
        case 0x02: return "D"
        case 0x03: return "F"
        case 0x04: return "H"
        case 0x05: return "G"
        case 0x06: return "Z"
        case 0x07: return "X"
        case 0x08: return "C"
        case 0x09: return "V"
        case 0x0B: return "B"
        case 0x0C: return "Q"
        case 0x0D: return "W"
        case 0x0E: return "E"
        case 0x0F: return "R"
        case 0x10: return "Y"
        case 0x11: return "T"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x16: return "6"
        case 0x17: return "5"
        case 0x19: return "9"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x1D: return "0"
        case 0x1F: return "O"
        case 0x20: return "U"
        case 0x22: return "I"
        case 0x23: return "P"
        case 0x25: return "L"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x2D: return "N"
        case 0x2E: return "M"
        case 0x24: return "Return"
        case 0x30: return "Tab"
        case 0x31: return "Space"
        case 0x33: return "Delete"
        case 0x35: return "Escape"
        case 0x7B: return "ArrowLeft"
        case 0x7C: return "ArrowRight"
        case 0x7D: return "ArrowDown"
        case 0x7E: return "ArrowUp"
        default:   return "?\(code)"
        }
    }

    // MARK: - Date formatter

    /// Cached formatter for `manifest.name` ("Recording 2026-05-05 14:32").
    private static let iso8601MinuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
