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
//
// Sparkle (item 11a): SPUStandardUpdaterController is framework-internal
// scheduling — it does NOT install NSEvent monitors — so init-time
// instantiation is genuinely safe. We still defer to .onAppear via
// `UpdaterHost.shared.bootIfNeeded()` for symmetry with the existing
// pattern; one trap-by-class-of-bug rule keeps App.init() intentionally
// inert.

import AppKit
import Sparkle
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

    /// View-model that mirrors Sparkle's `canCheckForUpdates` for the
    /// menu-bar "Check for Updates…" command. Constructed lazily once
    /// `UpdaterHost.shared.bootIfNeeded()` has produced an updater.
    @State private var checkForUpdatesViewModel: CheckForUpdatesViewModel? = nil

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
                    abortMonitor = AppShortcutMonitor(
                        onAbort: {
                            Engine.shared.abort(reason: .userHotkey)
                            // Recorder.shared.abort() is async-throws; fire-and-forget into a
                            // Task. Idempotent — abort() is documented safe-from-any-state.
                            // Engine + Recorder cannot both be active at once (Engine refuses
                            // to start while a recording is running per item 5's chokepoint),
                            // so the calls don't conflict — they're parallel safety surfaces.
                            Task { try? await Recorder.shared.abort() }
                            // Also broadcast so ContentView can clear a pending arm
                            // (no engine running yet, nothing for Engine.abort to act on).
                            NotificationCenter.default.post(name: .appShortcutAbortPressed, object: nil)
                        },
                        onEngage: {
                            // ContentView observes; when an entry is armed, fires
                            // the engine. When nothing is armed, no-op (the user
                            // hit the hotkey on accident).
                            NotificationCenter.default.post(name: .appShortcutEngagePressed, object: nil)
                        }
                    )
                }

                // Boot Sparkle's updater. Idempotent — second call no-ops.
                // Reads SUFeedURL + SUPublicEDKey + scheduling defaults
                // from Info.plist. updaterDelegate / userDriverDelegate
                // stay nil for v1 — the standard controller's defaults
                // are correct (alert UI, install-on-quit, etc.).
                UpdaterHost.shared.bootIfNeeded()
                if checkForUpdatesViewModel == nil, let updater = UpdaterHost.shared.updater {
                    checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
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
        .commands {
            // Sparkle's "Check for Updates…" menu item, slotted under
            // the app menu after "About macRo". The button is disabled
            // pre-boot (updater nil) and while Sparkle is mid-check.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(viewModel: checkForUpdatesViewModel)
            }
        }
    }
}

// MARK: - Notification names

/// Posted by `AppShortcutMonitor`'s `onAbort` callback. ContentView
/// observes to clear any pending arm (the engine call inside onAbort
/// already handles a running engine).
extension Notification.Name {
    static let appShortcutAbortPressed = Notification.Name("macRo.AppShortcut.abortPressed")
    static let appShortcutEngagePressed = Notification.Name("macRo.AppShortcut.engagePressed")
}

// MARK: - Check for Updates menu item

/// Menu-item wrapper. Reads the boot-time view-model; falls back to a
/// disabled button until the .onAppear cycle has completed (in practice
/// the user can't reach the menu before that anyway).
struct CheckForUpdatesMenuItem: View {
    let viewModel: CheckForUpdatesViewModel?

    var body: some View {
        if let viewModel {
            CheckForUpdatesButton(viewModel: viewModel)
        } else {
            Button("Check for Updates…") { /* no-op pre-boot */ }
                .disabled(true)
        }
    }
}

/// Inner button wired to a live `CheckForUpdatesViewModel`. Reactive
/// to Sparkle's `canCheckForUpdates` so the disabled state stays in sync.
struct CheckForUpdatesButton: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel

    var body: some View {
        Button("Check for Updates…", action: viewModel.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// View-model that mirrors Sparkle's `canCheckForUpdates` into a
/// SwiftUI-observable `@Published`. Sparkle exposes this property as
/// KVO-compliant; the Combine publisher assigns into the `@Published`
/// for free.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
