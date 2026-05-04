// SCKCapture.swift
// Native services — ScreenCaptureKit window capture wrapper.
//
// Wraps an SCStream against a single SCWindow target. Frame callbacks
// fire on SCK's own queue (NEVER main, per spec § 3 threading
// discipline). Designed to feed both Encoder (for raw-video.mov during
// recording) and Engine (for live frame-snapshot gate evaluation).
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 3
// (Native services layer) + § 5 (capture flow) + § 6 (engine pre-flight).
//
// Threading: SCStream owns its own queue. The onFrame callback fires on
// that queue. Callers must NOT touch UI from the callback; bounce to
// MainActor explicitly.
//
// Permissions assumption: Screen Recording is checked by Permissions
// upstream. SCK calls themselves throw if the grant is missing; we map
// to .screenRecordingDenied so engine pre-flight produces a clear error.

import CoreMedia
import Foundation
import ScreenCaptureKit

/// Static-discovery + instance-driven wrapper around SCStream.
public final class SCKCapture: NSObject {

    // MARK: - Errors

    /// Typed errors thrown by `start()` and the static helpers.
    public enum SCKCaptureError: LocalizedError {
        case screenRecordingDenied
        case noShareableContent(message: String)
        case streamSetupFailed(message: String)
        case alreadyRunning
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .screenRecordingDenied:
                return "Screen Recording permission is required. Re-grant in System Settings → Privacy & Security → Screen Recording."
            case .noShareableContent(let msg):
                return "ScreenCaptureKit could not enumerate shareable content: \(msg)"
            case .streamSetupFailed(let msg):
                return "Capture session could not be configured: \(msg)"
            case .alreadyRunning:
                return "SCKCapture.start() called while a session is already running."
            case .notRunning:
                return "SCKCapture.stop() called with no active session."
            }
        }
    }

    // MARK: - Public state

    /// True iff `start()` succeeded and `stop()` has not yet run.
    public private(set) var isRunning: Bool = false

    /// The window this capture targets. Captured at init time; SCK
    /// re-queries shareable content under the hood per frame, but the
    /// SCWindow object stays valid for the session lifetime.
    public let window: SCWindow

    /// Target frame rate (Hz). Passed to SCStreamConfiguration. SCK
    /// honors this as a maximum; observed FPS may be lower under load.
    public let frameRate: Int

    // MARK: - Internals

    private var stream: SCStream?
    private var output: FrameOutput?

    /// Dedicated serial queue for SCStream output delivery. SCK requires
    /// adding the output with a queue; this queue is the "SCK queue" the
    /// spec refers to in the threading discipline.
    private let outputQueue = DispatchQueue(
        label: "com.626labs.macRo.sck.frames",
        qos: .userInteractive
    )

    // MARK: - Init

    /// Construct a capture session targeting `window` at up to
    /// `frameRate` Hz. `start()` must be called to begin frame delivery.
    public init(window: SCWindow, frameRate: Int = 60) {
        self.window = window
        self.frameRate = frameRate
        super.init()
    }

    // MARK: - Window discovery

    /// Bridge a WindowDetector.Match to an SCWindow by enumerating
    /// SCShareableContent and filtering for window title + owning app
    /// match. Returns nil when nothing matches. Throws
    /// `.screenRecordingDenied` when SCK refuses to enumerate (the
    /// runtime indicator that Screen Recording was revoked).
    public static func findWindow(matching match: WindowDetector.Match) async throws -> SCWindow? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // SCK does not vend a stable error code for "permission
            // denied"; the message contains "TCC" or "screen recording"
            // when the grant is missing. Be conservative: route as
            // .screenRecordingDenied if the system call failed at all,
            // since enumeration is supposed to be near-infallible
            // otherwise.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("tcc") || msg.contains("screen recording") || msg.contains("permission") {
                throw SCKCaptureError.screenRecordingDenied
            }
            throw SCKCaptureError.noShareableContent(message: error.localizedDescription)
        }

        let titleRegex: NSRegularExpression?
        if let pattern = match.titleMatch {
            titleRegex = try? NSRegularExpression(pattern: pattern, options: [])
        } else {
            titleRegex = nil
        }

        for window in content.windows {
            let title = window.title ?? ""
            let appName = window.owningApplication?.applicationName ?? ""
            let bundleID = window.owningApplication?.bundleIdentifier ?? ""

            if let classes = match.windowClass, !classes.isEmpty {
                let hit = classes.contains { needle in
                    [appName, bundleID].contains { hay in
                        hay == needle || hay.localizedCaseInsensitiveContains(needle)
                    }
                }
                if !hit { continue }
            }

            if let regex = titleRegex {
                let range = NSRange(title.startIndex..., in: title)
                if regex.firstMatch(in: title, options: [], range: range) == nil {
                    continue
                }
            }

            return window
        }
        return nil
    }

    // MARK: - Start / stop

    /// Begin capture. `onFrame` fires on the dedicated SCK queue once per
    /// delivered frame as long as the stream is running. Throws if the
    /// session is already running, the configuration is rejected, or the
    /// system denies screen recording at start time.
    public func start(onFrame: @escaping (CMSampleBuffer) -> Void) async throws {
        if isRunning { throw SCKCaptureError.alreadyRunning }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8                  // small ring buffer
        config.showsCursor = false             // v1: no cursor in the recording
        config.scalesToFit = false             // capture at native res

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = FrameOutput(onFrame: onFrame)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
        } catch {
            throw SCKCaptureError.streamSetupFailed(message: error.localizedDescription)
        }

        do {
            try await stream.startCapture()
        } catch {
            // SCK's start error path bundles permission failures here.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("tcc") || msg.contains("screen recording") || msg.contains("permission") {
                throw SCKCaptureError.screenRecordingDenied
            }
            throw SCKCaptureError.streamSetupFailed(message: error.localizedDescription)
        }

        self.stream = stream
        self.output = output
        self.isRunning = true
    }

    /// Stop capture cleanly. Idempotent enough to be safe to call from
    /// teardown paths — but throws .notRunning if the caller is asserting
    /// state and wants to know.
    public func stop() async throws {
        guard isRunning, let stream = stream else { throw SCKCaptureError.notRunning }
        do {
            try await stream.stopCapture()
        } catch {
            // Surface but don't fail teardown — the stream is dead either
            // way.
            throw SCKCaptureError.streamSetupFailed(message: error.localizedDescription)
        }
        self.stream = nil
        self.output = nil
        self.isRunning = false
    }
}

// MARK: - SCStreamOutput delegate

/// Delegate-style frame sink. SCK requires an object conforming to
/// SCStreamOutput for `addStreamOutput`; using a closure-capturing
/// helper keeps SCKCapture free of @objc protocol noise on its public
/// surface.
private final class FrameOutput: NSObject, SCStreamOutput {
    let onFrame: (CMSampleBuffer) -> Void

    init(onFrame: @escaping (CMSampleBuffer) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // SCK can deliver buffers that aren't ready (e.g., status frames
        // when nothing changed). Filter to .screen + valid + complete.
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        onFrame(sampleBuffer)
    }
}
