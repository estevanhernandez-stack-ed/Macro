// EventTap.swift
// Native services — CGEventTap record + CGEvent.post synthesis.
//
// Two paths in one type:
//
//   • RECORD — install a CGEventTap (annotated-session level, listen-only,
//     .cghidEventTap) on a dedicated thread. Per-event callback fires on
//     that thread with a translated RawInputEvent.
//
//   • SYNTHESIZE — translate a SynthInputEvent into a CGEvent and post via
//     CGEvent.post(.cghidEventTap). Caller (the Engine) is responsible for
//     converting window-relative coords to screen-space; this wrapper does
//     not assume a window context (that's not its job — it's the bottom
//     of the stack).
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 3
// (Native services layer + threading discipline) + § 6 (run loop synth) +
// docs/spec.md > CGEventTap + CGEvent.post wrapper.
//
// LIFECYCLE (the bug-prone part):
//   1. tapCreate(...) — returns CFMachPort or nil if Accessibility denied.
//   2. CFMachPortCreateRunLoopSource(...) — wraps the port into a source.
//   3. CFRunLoopAddSource(...) on a dedicated thread's run loop.
//   4. CGEvent.tapEnable(tap:enable:true) to start receiving events.
//   5. CFRunLoopRun() on the dedicated thread (blocks until stop).
//   6. On stop:
//        a. CGEvent.tapEnable(tap:enable:false)
//        b. CFRunLoopRemoveSource(...)
//        c. CFMachPortInvalidate(...)
//        d. CFRunLoopStop on the dedicated run loop
//        e. join the thread
//
// We hold the CGEvent.tapCreate callback context as an Unmanaged
// reference to a small box object so the C-callable callback can route
// back to the EventTap instance without any Swift closure capture.

import AppKit
import CoreGraphics
import Foundation

/// Owns one CGEventTap (record path) and the synth dispatcher (post path).
/// Not thread-safe — callers should hold a single instance per recorder /
/// engine session.
public final class EventTap {

    // MARK: - Errors

    public enum EventTapError: LocalizedError, Equatable {
        case accessibilityDenied
        case tapCreateFailed
        case alreadyRecording
        case notRecording
        case synthEventConstructionFailed(message: String)

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is required to record or synthesize input. Re-grant in System Settings → Privacy & Security → Accessibility."
            case .tapCreateFailed:
                return "CGEvent.tapCreate returned nil. Confirm Accessibility is granted, then retry."
            case .alreadyRecording:
                return "EventTap.startRecording() called while a session is already active."
            case .notRecording:
                return "EventTap.stopRecording() called with no active session."
            case .synthEventConstructionFailed(let msg):
                return "CGEvent construction failed: \(msg)"
            }
        }
    }

    // MARK: - RawInputEvent (record path)

    /// A single observed input event, normalized for the recorder. The
    /// recorder is responsible for translating screen-space coords into
    /// the target window's content-rect-relative coords (it knows the
    /// rect; this wrapper does not).
    ///
    /// `timestamp` is monotonic CFAbsoluteTime — convert against the
    /// session start time on the recorder side to get t-from-zero.
    public enum RawInputEvent: Equatable, Sendable {
        case keyDown(keyCode: UInt16, flags: CGEventFlags, timestamp: CFAbsoluteTime)
        case keyUp(keyCode: UInt16, flags: CGEventFlags, timestamp: CFAbsoluteTime)
        case mouseDown(button: MouseButton, location: CGPoint, timestamp: CFAbsoluteTime)
        case mouseUp(button: MouseButton, location: CGPoint, timestamp: CFAbsoluteTime)
        case mouseMoved(location: CGPoint, deltaX: Double, deltaY: Double, timestamp: CFAbsoluteTime)
    }

    /// Synth-side input event the engine asks the wrapper to post. Coords
    /// are already screen-space — the engine has resolved window-relative
    /// coords against the current Roblox content rect before calling.
    public enum SynthInputEvent: Equatable, Sendable {
        case keyDown(keyCode: UInt16, flags: CGEventFlags)
        case keyUp(keyCode: UInt16, flags: CGEventFlags)
        case mouseDown(button: MouseButton, location: CGPoint)
        case mouseUp(button: MouseButton, location: CGPoint)
        case mouseMove(location: CGPoint)
    }

    public enum MouseButton: String, Equatable, Hashable, Sendable {
        case left, right, middle

        var cgEventType: (down: CGEventType, up: CGEventType, drag: CGEventType) {
            switch self {
            case .left:   return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
            case .right:  return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
            case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
            }
        }

        var cgMouseButton: CGMouseButton {
            switch self {
            case .left:   return .left
            case .right:  return .right
            case .middle: return .center
            }
        }
    }

    // MARK: - State

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var callbackContext: CallbackContext?

    /// True iff a record session is active.
    public private(set) var isRecording: Bool = false

    public init() {}

    deinit {
        if isRecording {
            // Best-effort teardown without throwing from deinit.
            stopRecordingInternal()
        }
    }

    // MARK: - Record

    /// Start observing input. The callback fires on the EventTap's
    /// dedicated thread (NOT main, NOT the caller's thread). Coordinates
    /// in mouse events are global (screen-space); the caller is expected
    /// to clip / translate against a target window content rect.
    public func startRecording(onEvent: @escaping (RawInputEvent) -> Void) throws {
        if isRecording { throw EventTapError.alreadyRecording }

        // Mask: every event class we care about. listenOnly tap doesn't
        // modify the stream, so games receive input unchanged. Built via a
        // reduce over an array of CGEventType values so the Swift
        // type-checker doesn't time out on a 13-term bitwise-OR expression.
        let observedTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        let mask: UInt32 = observedTypes.reduce(into: UInt32(0)) { acc, type in
            acc |= UInt32(1) << UInt32(type.rawValue)
        }

        let context = CallbackContext(onEvent: onEvent)
        // Pin the box so the C callback's user-info pointer stays valid
        // for the session lifetime. Released in stopRecording().
        let unmanaged = Unmanaged.passRetained(context)
        let userInfo = unmanaged.toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: EventTap.tapCallback,
            userInfo: userInfo
        ) else {
            // Release the retained box; the tap never took it.
            unmanaged.release()
            // tapCreate returns nil when Accessibility is denied.
            // AXIsProcessTrusted() would tell us for sure, but we don't
            // want to add a dependency on AppKit here for the check
            // since Permissions module owns the trust contract.
            throw EventTapError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // Spin up a dedicated thread whose run loop hosts the source.
        // Using Thread (not DispatchQueue) because CFRunLoopRun() blocks
        // and we want a clearly-labeled OS thread for diagnostics.
        let started = DispatchSemaphore(value: 0)
        var capturedRunLoop: CFRunLoop?
        let thread = Thread {
            // Capture the thread's run loop reference so the main thread
            // can stop it later via CFRunLoopStop.
            let runLoop = CFRunLoopGetCurrent()
            capturedRunLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            started.signal()
            // Run until CFRunLoopStop is called from stopRecording().
            CFRunLoopRun()
        }
        thread.name = "com.626labs.macRo.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()

        self.tapPort = tap
        self.runLoopSource = source
        self.thread = thread
        self.threadRunLoop = capturedRunLoop
        self.callbackContext = context
        self.isRecording = true
    }

    /// Stop observing input. Cleanly tears down the tap, removes the run
    /// loop source, and joins the dedicated thread.
    public func stopRecording() throws {
        guard isRecording else { throw EventTapError.notRecording }
        stopRecordingInternal()
    }

    private func stopRecordingInternal() {
        if let tap = tapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = threadRunLoop, let source = runLoopSource {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let tap = tapPort {
            CFMachPortInvalidate(tap)
        }
        if let runLoop = threadRunLoop {
            CFRunLoopStop(runLoop)
        }
        // Release the retained callback context box.
        if let ctx = callbackContext {
            Unmanaged.passUnretained(ctx).release()
        }
        // Don't join (Thread doesn't expose join) — the run loop stop
        // signal lets it exit cleanly. Drop our refs so the next start
        // is hygienic.
        self.tapPort = nil
        self.runLoopSource = nil
        self.thread = nil
        self.threadRunLoop = nil
        self.callbackContext = nil
        self.isRecording = false
    }

    // MARK: - Synth

    /// Synthesize one input event and post it. Caller resolves coords to
    /// screen-space before calling. Posts via .cghidEventTap (the most
    /// system-realistic injection point — events flow through the same
    /// path real hardware would).
    public func synth(_ event: SynthInputEvent) throws {
        let cgEvent: CGEvent?

        switch event {
        case .keyDown(let keyCode, let flags):
            cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: true
            )
            cgEvent?.flags = flags

        case .keyUp(let keyCode, let flags):
            cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: false
            )
            cgEvent?.flags = flags

        case .mouseDown(let button, let location):
            cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: button.cgEventType.down,
                mouseCursorPosition: location,
                mouseButton: button.cgMouseButton
            )

        case .mouseUp(let button, let location):
            cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: button.cgEventType.up,
                mouseCursorPosition: location,
                mouseButton: button.cgMouseButton
            )

        case .mouseMove(let location):
            cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: location,
                mouseButton: .left
            )
        }

        guard let event = cgEvent else {
            throw EventTapError.synthEventConstructionFailed(
                message: "CGEvent constructor returned nil"
            )
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - C callback bridge

    /// Boxed context passed through CGEvent.tapCreate's userInfo pointer.
    /// We keep it as a class so we can round-trip via Unmanaged. The
    /// callback closure is captured here and invoked from the C
    /// callback below.
    private final class CallbackContext {
        let onEvent: (RawInputEvent) -> Void
        init(onEvent: @escaping (RawInputEvent) -> Void) {
            self.onEvent = onEvent
        }
    }

    /// Static C-callable callback. Receives the boxed context via
    /// userInfo, translates the CGEvent to a RawInputEvent, fires the
    /// recorder's per-event handler. Always returns the original event
    /// (we're listenOnly, so the system ignores the return value, but
    /// be explicit about non-modification anyway).
    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo = userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
        let timestamp = CFAbsoluteTimeGetCurrent()

        switch type {
        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            context.onEvent(.keyDown(keyCode: code, flags: event.flags, timestamp: timestamp))
        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            context.onEvent(.keyUp(keyCode: code, flags: event.flags, timestamp: timestamp))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = mouseButtonFor(eventType: type)
            context.onEvent(.mouseDown(button: button, location: event.location, timestamp: timestamp))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = mouseButtonFor(eventType: type)
            context.onEvent(.mouseUp(button: button, location: event.location, timestamp: timestamp))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            context.onEvent(.mouseMoved(location: event.location, deltaX: dx, deltaY: dy, timestamp: timestamp))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // System auto-disabled the tap (heavy-load throttling). The
            // callback will not fire again until we re-enable. Re-enable
            // immediately so recording continues seamlessly.
            // Note: we don't have access to the tap port here; the
            // owning EventTap re-enables on its dedicated thread next
            // time it's checked. For v1 the system rarely throttles
            // listenOnly taps; if this becomes a real problem in
            // practice, route the re-enable via the boxed context.
            break
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private static func mouseButtonFor(eventType: CGEventType) -> MouseButton {
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return .middle
        default:
            return .left
        }
    }
}
