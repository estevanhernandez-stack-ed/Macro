// AppShortcutMonitor.swift
// Domain — global keyboard shortcut monitor for abort + engage hotkeys.
//
// Registers two global NSEvent monitors at app launch:
//   • ⌃⌥⌘. (period) — abort. Fires onAbort regardless of focus.
//   • ⌃⌥⌘, (comma)  — engage / cancel-arm. Fires onEngage. The hotkey
//     is intentionally a single key that doubles as start (when an
//     entry is armed) and cancel-arm (when no engine is running yet).
//     The engine's chokepoint refuses synthesis while macRo is
//     frontmost, so an armed-then-engage handoff lets the user click
//     Run from the Library, switch to Roblox at their own pace, and
//     fire the engine from inside Roblox without needing a countdown.
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

    /// Virtual key code for `,` (comma). `kVK_ANSI_Comma == 0x2B`.
    private static let commaVirtualKey: UInt16 = 0x2B

    /// Shared modifier mask for both hotkeys. We compare against the
    /// masked event flags rather than equality to allow incidental
    /// modifiers (e.g., caps lock state) to vary without breaking the
    /// hotkey match.
    private static let hotkeyModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    // MARK: - State

    /// Pinned monitor token. Released only at deinit. The monitor stays
    /// alive for the entire app lifetime by contract.
    private var monitor: Any?

    /// Local monitor token — fires when macRo itself has focus. We
    /// install both global (other-app focus) and local (own-app focus)
    /// monitors so the hotkey works even when the user is interacting
    /// with the RunHUD overlay.
    private var localMonitor: Any?

    /// Callback fired on `⌃⌥⌘.`. Engine wiring passes
    /// `Engine.shared.abort(reason: .userHotkey)`.
    private let onAbort: () -> Void

    /// Callback fired on `⌃⌥⌘,`. Engine wiring posts a notification
    /// that ContentView observes to fire the armed bundle (or cancel
    /// the arm if no bundle is queued).
    private let onEngage: () -> Void

    // MARK: - Init

    /// Construct + immediately install. Throws nothing — NSEvent monitor
    /// installation does not surface errors at the API layer; if
    /// Accessibility was revoked the global monitor silently no-ops, but
    /// the local monitor still works.
    public init(
        onAbort: @escaping () -> Void,
        onEngage: @escaping () -> Void = {}
    ) {
        self.onAbort = onAbort
        self.onEngage = onEngage
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
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(Self.hotkeyModifiers) else { return }
        switch event.keyCode {
        case Self.periodVirtualKey: onAbort()
        case Self.commaVirtualKey:  onEngage()
        default: return
        }
    }
}
