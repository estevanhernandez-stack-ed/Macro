// App.swift
// macRo — entry point.
//
// v1 shell: a single WindowGroup that hosts either the OnboardingView
// (entitlements wizard) or ContentView (placeholder Library) based on
// live permission state. Sparkle, abort hotkey, and the rest of the app
// surface land in later checklist items.

import SwiftUI

@main
struct MacRoApp: App {

    /// Live grant state. Instantiated once at launch; injected into the
    /// SwiftUI environment so any view (Onboarding, future LibraryView,
    /// future RecorderHUD) can read it via `@Environment(Permissions.self)`.
    @State private var permissions = Permissions()

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
