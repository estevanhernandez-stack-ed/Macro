// App.swift
// macRo — entry point.
//
// v1 shell: a single WindowGroup that hosts either the OnboardingView
// (entitlements wizard) or ContentView (placeholder Library) based on
// live permission state.
//
// IMPORTANT TIMING RULE: AppShortcutMonitor + Permissions installation
// is deferred to `.onAppear` on the root view rather than running in
// the App's `init()`. Installing NSEvent.addLocalMonitorForEvents
// during App.init() — which runs before NSApplication is fully booted —
// silently breaks SwiftUI's own event-routing setup, leaving the
// resulting window unable to receive ANY mouse events (no hover state,
// no clicks, dim traffic lights). The deferred-install pattern fixes
// this and is good practice regardless. Discovered via the diagnostic
// strip-down on 2026-05-05; bare-bones SwiftUI app worked, full app
// didn't, narrowed via init-vs-onAppear toggle.

import AppKit
import SwiftUI

@main
struct MacRoApp: App {

    /// Live grant state. Constructed empty here; populated lazily on
    /// first .onAppear so we don't fight SwiftUI's init-phase setup.
    @State private var permissions = Permissions()

    /// Global abort-hotkey owner. Held for the app's lifetime once
    /// installed. Constructed empty/nil here; the actual NSEvent
    /// monitors install in .onAppear after the window is up.
    @State private var abortMonitor: AppShortcutMonitor? = nil

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
            .onAppear {
                // Install the abort-hotkey monitor only once, after the
                // first window is on-screen. NSApp.windows is non-empty
                // by this point.
                if abortMonitor == nil {
                    abortMonitor = AppShortcutMonitor(onAbort: {
                        Engine.shared.abort(reason: .userHotkey)
                        // Recorder.shared.abort() is async-throws; fire-and-forget into a
                        // Task. Idempotent — abort() is documented safe-from-any-state.
                        // Engine + Recorder cannot both be active at once (Engine refuses
                        // to start while a recording is running per item 5's chokepoint),
                        // so the calls don't conflict — they're parallel safety surfaces.
                        Task { try? await Recorder.shared.abort() }
                    })
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .task {
                // 10c — post-onboarding bootstrap. Idempotent on every
                // launch: indexes plugins + installs seed macros for any
                // bundled plugin whose `macRo.seedsInstalled.<id>` flag
                // is unset. Covers users who already onboarded before
                // 10c shipped (their seeds haven't been installed yet)
                // AND every cold launch after the wizard
                // (PluginLoader.shared.plugins gets refreshed so a
                // newly-dropped community plugin shows up in
                // GamePickSheet without a relaunch). Skipped pre-grant —
                // there's no point indexing plugins for a wizard.
                guard permissions.allGranted else { return }
                await PluginLoader.shared.loadAll()
                await LibraryStore.shared.installSeedsFromBundledPlugins()
            }
        }
        .windowResizability(.contentSize)
    }
}
