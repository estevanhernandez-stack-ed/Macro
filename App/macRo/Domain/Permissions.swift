// Permissions.swift
// Domain — Accessibility + Screen Recording grant tracking.
//
// macRo needs two macOS runtime permissions:
//
//   • Accessibility — input recording (CGEventTap) and synthesis
//     (CGEvent.post). Macros cannot exist without it.
//   • Screen Recording — ScreenCaptureKit window capture for the
//     timeline editor video lane and gate image refs.
//
// Both must be flipped in System Settings → Privacy & Security. macOS
// gives no in-process API to grant; we can only check + prompt + deep-link
// the user to the relevant pane. This class owns that flow.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + docs/spec.md > Permissions + docs/prd.md > Epic A.
//
// Threading: read-only API; refresh() may be called from any thread but
// Observable property writes coalesce on main via SwiftUI's tracking.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

/// Live grant state for the two macOS permissions macRo requires.
/// Inject as `@Environment(Permissions.self)` in SwiftUI; instantiate
/// once at app launch.
@Observable
public final class Permissions {

    // MARK: - State

    /// Whether macRo has Accessibility (`AXIsProcessTrusted()`).
    public private(set) var accessibilityGranted: Bool = false

    /// Whether macRo has Screen Recording (`CGPreflightScreenCaptureAccess()`).
    public private(set) var screenRecordingGranted: Bool = false

    /// True iff both permissions are granted.
    public var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

    // MARK: - Lifecycle

    private var foregroundObserver: NSObjectProtocol?

    public init() {
        refresh()
        installForegroundObserver()
    }

    deinit {
        if let token = foregroundObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Refresh

    /// Re-check both grants. Called on init, on app foreground, and any
    /// time the wizard view appears (so a user who flips the toggle in
    /// Settings, then alt-tabs back, sees the live state).
    public func refresh() {
        let ax = AXIsProcessTrusted()
        let scr = CGPreflightScreenCaptureAccess()
        // SwiftUI's @Observable diff suppresses redundant writes; safe to
        // assign every refresh.
        if accessibilityGranted != ax { accessibilityGranted = ax }
        if screenRecordingGranted != scr { screenRecordingGranted = scr }
    }

    // MARK: - Request

    /// Request Accessibility. macOS shows a system dialog with an "Open
    /// System Settings" button the first time; subsequent calls are
    /// no-ops if already granted. The user always finishes the grant by
    /// flipping the toggle in System Settings — there is no in-process
    /// path to grant. Refresh fires when the app foregrounds again.
    public func requestAccessibility() {
        // The trust prompt key is `kAXTrustedCheckOptionPrompt` — this
        // is the canonical CFString. The literal-key form below avoids
        // pulling in a deprecation warning on the constant when it
        // surfaces in newer SDKs.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Also open the pane directly — the prompt button is one click
        // and the pane gives the on/off toggle.
        openSystemSettingsAccessibility()
    }

    /// Request Screen Recording. Returns the immediate trust state — but
    /// in practice the user has to flip the toggle in System Settings
    /// after the first prompt, so callers should refresh on next
    /// foreground rather than rely on the return value.
    @discardableResult
    public func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            openSystemSettingsScreenRecording()
        }
        return granted
    }

    // MARK: - Deep links

    /// Open `System Settings → Privacy & Security → Accessibility`.
    public func openSystemSettingsAccessibility() {
        openSettings(pane: "Privacy_Accessibility")
    }

    /// Open `System Settings → Privacy & Security → Screen Recording`.
    /// The pane id matches the macOS 13+ name (`Privacy_ScreenCapture`).
    public func openSystemSettingsScreenRecording() {
        openSettings(pane: "Privacy_ScreenCapture")
    }

    private func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Foreground observer

    private func installForegroundObserver() {
        let center = NSWorkspace.shared.notificationCenter
        foregroundObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // Filter: re-check only when macRo itself becomes frontmost.
            // Other-app foregrounds do not change our trust state and would
            // otherwise spam refresh() during normal multi-app use.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Bundle.main.bundleIdentifier {
                self.refresh()
            }
        }
    }
}
