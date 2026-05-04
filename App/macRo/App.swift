// App.swift
// macRo — entry point.
//
// v1 shell: a single WindowGroup that hosts ContentView. Sparkle, abort hotkey,
// onboarding routing, and the rest of the app surface land in later checklist items.

import SwiftUI

@main
struct MacRoApp: App {
    var body: some Scene {
        WindowGroup("macRo") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentSize)
    }
}
