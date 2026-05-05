// AppShortcutMonitor.swift
// Domain — global keyboard shortcut monitor for the abort hotkey.
//
// Registers `⌃⌥⌘.` (Control+Option+Command+Period) as a global
// NSEvent monitor at app launch. Fires Engine.shared.abort(reason:
// .userHotkey) regardless of which app has focus — even if Roblox is
// frontmost and capturing every other keystroke.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 6
// (abort surfaces) + docs/spec.md > Engine + docs/prd.md > Epic D.
//
// HARD RULE: this monitor must remain registered for the entire app
// lifetime — no engine state, no UI flow, nothing may invalidate it.
// The monitor is the user's blast-shield against a runaway macro.
//
// Threading: NSEvent monitor callbacks fire on main. The engine's
// `abort(reason:)` method is documented safe-from-any-thread, so the
// hop is implicit.

import AppKit
import Foundation

/// Owner of the global abort-hotkey NSEventMonitor. Construct exactly
/// once, at app launch. Hold the reference for the app lifetime.
public final class AppShortcutMonitor {

    // MARK: - Constants

    /// Virtual key code for `.` (period). Stable across keyboard
    /// layouts: this is the physical key in the lower-right of the QWERTY
    /// alphanumeric block. Apple's HIToolbox header is the source of
    /// truth (`kVK_ANSI_Period == 0x2F`).
    private static let periodVirtualKey: UInt16 = 0x2F

    /// Modifier mask for ⌃⌥⌘. We compare against the masked event flags
    /// rather than equality to allow incidental modifiers (e.g., caps
    /// lock state) to vary without breaking the hotkey.
    private static let abortModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    // MARK: - State

    /// Pinned monitor token. Released only at deinit. The monitor stays
    /// alive for the entire app lifetime by contract.
    private var monitor: Any?

    /// Local monitor token — fires when macRo itself has focus. We
    /// install both global (other-app focus) and local (own-app focus)
    /// monitors so the hotkey works even when the user is interacting
    /// with the RunHUD overlay.
    private var localMonitor: Any?

    /// Callback fired on hotkey match. Set at init; engine wiring
    /// passes `Engine.shared.abort(reason: .userHotkey)`.
    private let onAbort: () -> Void

    // MARK: - Init

    /// Construct + immediately install. Throws nothing — NSEvent monitor
    /// installation does not surface errors at the API layer; if
    /// Accessibility was revoked the global monitor silently no-ops, but
    /// the local monitor still works.
    public init(onAbort: @escaping () -> Void) {
        self.onAbort = onAbort
        installGlobalMonitor()
        installLocalMonitor()
    }

    deinit {
        // Unreachable in v1 (monitor is registered for the app lifetime),
        // but if a future code path retires the monitor we want a clean
        // teardown rather than a leak.
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
        }
    }

    // MARK: - Private

    private func installGlobalMonitor() {
        // Global monitor receives events bound for OTHER applications.
        // Required so the hotkey works while Roblox (or any other app) is
        // frontmost. Returns Void (no opportunity to consume the event,
        // which is fine — period is rarely game-bound).
        let token = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        self.monitor = token
    }

    private func installLocalMonitor() {
        // Local monitor receives events bound for macRo itself. Returns
        // the (possibly modified) event back to the system; we return it
        // unchanged because we don't want to swallow the keystroke from
        // any text field that happens to have focus.
        let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
        self.localMonitor = token
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.periodVirtualKey else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(Self.abortModifiers) else { return }
        onAbort()
    }
}
