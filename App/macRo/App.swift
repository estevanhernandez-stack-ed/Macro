// App.swift
// macRo — entry point.
//
// v1 shell: a single WindowGroup that hosts either the OnboardingView
// (entitlements wizard) or ContentView (placeholder Library) based on
// live permission state. The global abort-hotkey monitor is wired here
// at @main init time so `⌃⌥⌘.` is live for the entire app lifetime —
// before any window scene loads, before the engine is first accessed.
// Sparkle and the rest of the app surface land in later checklist items.

import SwiftUI

@main
struct MacRoApp: App {

    /// Live grant state. Instantiated once at launch; injected into the
    /// SwiftUI environment so any view (Onboarding, future LibraryView,
    /// future RecorderHUD) can read it via `@Environment(Permissions.self)`.
    @State private var permissions = Permissions()

    /// Global abort-hotkey owner. Held for the app's lifetime by
    /// contract — see `AppShortcutMonitor`'s file header. Constructed at
    /// `@main` init so the hotkey is registered before SwiftUI loads
    /// any scene and before `Engine.shared` is first touched. Routes
    /// `⌃⌥⌘.` straight into `Engine.shared.abort(reason: .userHotkey)`.
    private let abortMonitor: AppShortcutMonitor

    init() {
        self.abortMonitor = AppShortcutMonitor(onAbort: {
            Engine.shared.abort(reason: .userHotkey)
        })
    }

    var body: some Scene {
        WindowGroup("macRo") {
            Group {
                if permissions.allGranted {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .frame(minWidth: 720, minHeight: 480)
            .environment(permissions)
        }
        .windowResizability(.contentSize)
    }
}
