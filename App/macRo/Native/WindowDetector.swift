// WindowDetector.swift
// Native services — window discovery via NSWorkspace + AXUIElement.
//
// macRo needs to:
//   • Find a target window (the Roblox client) before recording or playback.
//   • Read its content rect (origin + size in screen coordinates) so the
//     engine can translate window-relative coords to screen coords.
//   • Refresh on every call — windows move, resize, foreground/background.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 3
// (Native services layer) + § 6 (engine pre-flight: window match) +
// docs/spec.md > NSAccessibility / NSWorkspace window detection.
//
// Threading: every call is synchronous and re-discovers state from scratch.
// Do NOT cache AXUIElement references — they go stale when apps
// foreground/background. Callers may invoke from any thread; AXUI is
// thread-safe for the read-only attribute access we do here.
//
// Permissions assumption: Accessibility grant is required for AXUI
// traversal. Permissions module checks this upstream; if missing, AXUI
// returns kAXErrorAPIDisabled and we surface that as
// .accessibilityDenied.

import AppKit
import ApplicationServices
import Foundation

/// Static-only namespace for window detection. Not instantiable.
public enum WindowDetector {

    // MARK: - Errors

    /// Typed errors thrown by `find(_:)` and `current()`. Most paths
    /// return nil (no match) rather than throwing; throws are reserved for
    /// genuine permission / state issues.
    public enum WindowDetectorError: LocalizedError, Equatable {
        /// AXUI traversal failed because Accessibility is not granted.
        /// Permissions module gates this upstream; if we still see it,
        /// the user revoked grant mid-session.
        case accessibilityDenied
        /// `target.windowTitleMatch` regex failed to compile.
        case invalidTitleRegex(pattern: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is required to find windows. Re-grant in System Settings → Privacy & Security → Accessibility."
            case .invalidTitleRegex(let pattern, let message):
                return "windowTitleMatch is not a valid regex (\(pattern)): \(message)"
            }
        }
    }

    // MARK: - Match

    /// Match criteria derived from `MacroFormat.Target`. Both arms are
    /// optional — supplying only `windowClass` matches by NSAccessibility
    /// role / subrole / app name; supplying only `titleMatch` matches by
    /// window title regex; supplying both is an AND.
    public struct Match: Equatable, Hashable, Sendable {
        /// Fallback NSAccessibility class array (per spec § 11 risk
        /// mitigation: Roblox can change classes; an array means we can
        /// fall back without re-recording every macro). We treat each
        /// element as a candidate `kAXSubroleAttribute`,
        /// `kAXRoleAttribute`, or app-name string. Match is OR over the
        /// array.
        public let windowClass: [String]?
        /// Regex matched against the window title (NSRegularExpression
        /// dialect). Compiled lazily during `find`.
        public let titleMatch: String?

        public init(windowClass: [String]? = nil, titleMatch: String? = nil) {
            self.windowClass = windowClass
            self.titleMatch = titleMatch
        }
    }

    // MARK: - Result

    /// Information about a matched window. `contentRect` is in screen
    /// coordinates (Cocoa origin: bottom-left of the primary screen).
    /// AXUI returns top-left coords; we convert to Cocoa to keep the
    /// caller's life simple.
    public struct WindowInfo: Equatable, Hashable, Sendable {
        public let pid: pid_t
        public let title: String
        public let contentRect: NSRect
        public let bundleID: String?

        public init(pid: pid_t, title: String, contentRect: NSRect, bundleID: String? = nil) {
            self.pid = pid
            self.title = title
            self.contentRect = contentRect
            self.bundleID = bundleID
        }
    }

    // MARK: - Public API

    /// Find the first window matching the given criteria. Returns nil
    /// when no application or window matches. Throws only when
    /// Accessibility is denied or the title regex is invalid.
    ///
    /// Search shape:
    ///   1. Compile the title regex once if present.
    ///   2. Walk every running .regular application via NSWorkspace.
    ///   3. For each app, build an AXUIElement, list its windows.
    ///   4. For each window, evaluate windowClass + title against the
    ///      Match. First hit wins.
    public static func find(_ match: Match) throws -> WindowInfo? {
        let titleRegex: NSRegularExpression?
        if let pattern = match.titleMatch {
            do {
                titleRegex = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw WindowDetectorError.invalidTitleRegex(
                    pattern: pattern,
                    message: error.localizedDescription
                )
            }
        } else {
            titleRegex = nil
        }

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsRef
            )
            // Per-app failures (apiDisabled, attributeUnsupported, error)
            // are silently skipped — many apps don't expose AXUI to
            // foreign processes, and that's not a global permission
            // problem. The Permissions module owns the "AX granted /
            // denied" contract; here we just collect what we can see.
            guard err == .success, let windows = windowsRef as? [AXUIElement] else {
                continue
            }

            for window in windows {
                let title = stringAttribute(window, kAXTitleAttribute as CFString) ?? ""

                // windowClass match: OR over candidates against role,
                // subrole, app localizedName, app bundleID.
                let classCandidates: [String] = [
                    stringAttribute(window, kAXRoleAttribute as CFString),
                    stringAttribute(window, kAXSubroleAttribute as CFString),
                    app.localizedName,
                    app.bundleIdentifier
                ].compactMap { $0 }

                if let classes = match.windowClass, !classes.isEmpty {
                    let hit = classes.contains { needle in
                        classCandidates.contains { hay in
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

                // Match. Read position + size.
                guard let rect = readRect(window) else { continue }

                return WindowInfo(
                    pid: pid,
                    title: title,
                    contentRect: rect,
                    bundleID: app.bundleIdentifier
                )
            }
        }
        return nil
    }

    /// Return the frontmost window of any regular application, or nil if
    /// nothing fits. Useful for the recorder's "you forgot to choose a
    /// game, here's the frontmost window" fallback and for tests that
    /// don't have a known target app to match against.
    public static func current() throws -> WindowInfo? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.activationPolicy == .regular,
              frontApp.processIdentifier > 0 else {
            return nil
        }
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        )

        // Some apps don't expose AXFocusedWindow; fall back to the first
        // entry in AXWindows. `apiDisabled` from a single app is not a
        // global denial — silently fall through and return nil.
        var window: AXUIElement?
        if err == .success, let focused = focusedRef {
            // CFTypeRef → AXUIElement (both are CFType under the hood).
            window = (focused as! AXUIElement) // swiftlint:disable:this force_cast
        } else {
            var windowsRef: CFTypeRef?
            err = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsRef
            )
            if err == .success, let arr = windowsRef as? [AXUIElement], let first = arr.first {
                window = first
            }
        }

        guard let win = window, let rect = readRect(win) else { return nil }
        let title = stringAttribute(win, kAXTitleAttribute as CFString) ?? ""
        return WindowInfo(
            pid: pid,
            title: title,
            contentRect: rect,
            bundleID: frontApp.bundleIdentifier
        )
    }

    // MARK: - Private

    /// Read a string-valued AXUI attribute, returning nil on missing /
    /// wrong-type / error.
    private static func stringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr, &ref)
        guard err == .success, let str = ref as? String else { return nil }
        return str
    }

    /// Read kAXPositionAttribute + kAXSizeAttribute and return as an
    /// NSRect in Cocoa coords (origin bottom-left of primary screen).
    /// AXUI returns CGPoint/CGSize in top-left-origin screen coords; we
    /// flip Y against the primary screen's height.
    private static func readRect(_ window: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        let sizeErr = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard posErr == .success, sizeErr == .success,
              let posValue = posRef, let sizeValue = sizeRef else { return nil }

        var topLeft = CGPoint.zero
        var size = CGSize.zero
        // The AXValue refs unwrap to CGPoint / CGSize via AXValueGetValue.
        // CFTypeRef → AXValue cast is safe because we only ever asked for
        // attributes that return AXValue.
        let pAX = posValue as! AXValue   // swiftlint:disable:this force_cast
        let sAX = sizeValue as! AXValue  // swiftlint:disable:this force_cast
        guard AXValueGetValue(pAX, .cgPoint, &topLeft),
              AXValueGetValue(sAX, .cgSize, &size) else { return nil }

        // AXUI uses top-left origin; convert to Cocoa bottom-left origin
        // against the primary screen so callers can pass straight to
        // NSWindow / CGEvent screen-space APIs.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - topLeft.y - size.height

        return NSRect(
            x: topLeft.x,
            y: cocoaY,
            width: size.width,
            height: size.height
        )
    }
}
