// EngineErrors.swift
// Domain — typed errors thrown / surfaced by the playback engine.
//
// Split from Engine.swift for readability: the error surface is part of
// the engine's public contract (RunHUD reads it, BindingMismatchPrompt
// references one case, future LibraryView may render others). Keeping it
// in its own file makes the contract auditable without scrolling past
// the run loop.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 6
// (engine pre-flight + safety rules) + docs/spec.md > Engine + docs/prd.md
// > Epic D.

import Foundation

/// Typed errors produced by the playback engine. Every case carries the
/// minimum context needed to render a human-readable message at the
/// failure site — the user should never have to crack a stack trace to
/// understand why a macro refused to play.
public enum EngineError: LocalizedError, Equatable {

    /// Bundle's `schemaVersion` is newer than what this build of the
    /// engine knows how to play. (Forward compat is the factory's job;
    /// back compat is the engine's promise — but new majors require a
    /// new engine.)
    case unsupportedSchemaVersion(found: Int, supported: Int)

    /// 10s window-discovery timeout exhausted without finding a window
    /// matching the manifest's `target` selectors.
    case windowNotFound(matcher: String)

    /// User cancelled the binding-mismatch confirmation modal.
    case bindingsNotConfirmed

    /// `loop` event tripped the runaway-detection threshold (default
    /// 100,000 visits per label). Either the macro has a real cycle bug
    /// or the threshold is too low for this workload — both deserve a
    /// human read.
    case loopRunaway(label: String)

    /// `gate.retries` exhausted with `onFail: abort`.
    case gateFailedFinal(ref: String, kind: String)

    /// `invokeSub` event named a sub that does not exist under
    /// `timeline.subs`. MacroBundle.validate normally catches this at
    /// load time; this case is the runtime safety net.
    case subNotFound(name: String)

    /// SCK frame-grab failed during pre-flight or gate evaluation. Wraps
    /// the underlying error's `localizedDescription` as a string so the
    /// case stays `Equatable` for tests.
    case captureFailed(message: String)

    /// `manifest.maxRuntimeHours` cap exceeded mid-run.
    case runtimeCapExceeded(hours: Double)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return "This macro was authored against schemaVersion \(found); this build of macRo supports up to \(supported). Update macRo to play it."
        case .windowNotFound(let matcher):
            return "Could not find a window matching \(matcher) within 10 seconds. Open the target game and try again."
        case .bindingsNotConfirmed:
            return "Binding confirmation was cancelled — macro will not play."
        case .loopRunaway(let label):
            return "Loop \(label) ran past the runaway-detection threshold. The macro likely has a cycle bug."
        case .gateFailedFinal(let ref, let kind):
            return "Gate \(kind):\(ref) did not match after all retries — macro aborted per onFail policy."
        case .subNotFound(let name):
            return "Sub-macro \(name) was invoked but does not exist in this bundle."
        case .captureFailed(let message):
            return "Frame capture failed: \(message)"
        case .runtimeCapExceeded(let hours):
            return "Macro exceeded its maxRuntimeHours cap of \(hours)h — engine stopped."
        }
    }
}

/// Discriminator for engine pause states. `outsideSchedule` is the only
/// non-error reason a macro sits idle pre-run; the others happen mid-run
/// in response to environment changes.
public enum EnginePauseReason: Equatable, Sendable {
    /// Current time is outside any `manifest.schedule[]` window. Engine
    /// will resume automatically when the time enters a window.
    case outsideSchedule(nextStart: Date?)
    /// `stopOn` trigger with `action: pause` fired. `message` echoes the
    /// trigger's optional message field (for the Mac notification).
    case stopOnPause(message: String?)
    /// Target window went background or closed mid-run. Spec § 6 hard
    /// safety: engine pauses (not aborts) and shows "bring window back."
    case windowLost
    /// User explicitly paused via RunHUD (reserved for future use; not
    /// wired in v1).
    case userPaused
}

/// Discriminator for engine abort reasons. Distinct from pause because
/// abort is terminal — the run does not resume from an aborted state.
public enum EngineAbortReason: Equatable, Sendable {
    /// User pressed the global `⌃⌥⌘.` abort hotkey.
    case userHotkey
    /// User clicked the RunHUD stop button.
    case userStopButton
    /// Stop-on trigger fired with `action: exit` (clean stop).
    case stopOnExit
    /// Gate failed with `onFail: abort`.
    case gateAbort(ref: String)
    /// Loop runaway threshold exceeded.
    case loopRunaway(label: String)
    /// Engine's own pre-flight or invariant check refused to proceed.
    case preflightFailed
}
