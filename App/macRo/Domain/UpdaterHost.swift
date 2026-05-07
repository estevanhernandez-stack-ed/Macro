// UpdaterHost.swift
// Domain — app-lifetime owner for Sparkle's SPUStandardUpdaterController.
//
// Mirrors the singleton pattern used by Engine.shared / Recorder.shared
// / LibraryStore.shared / PluginLoader.shared. MacRoApp.onAppear calls
// `UpdaterHost.shared.bootIfNeeded()` exactly once; downstream surfaces
// (UpdateSettingsView, the menu-bar Check-for-Updates command, anything
// future) read `UpdaterHost.shared.updater` to reach Sparkle's
// `SPUUpdater` without threading a binding through the view tree.
//
// Why deferred boot: SPUStandardUpdaterController is framework-internal
// scheduling (it does NOT install NSEvent monitors), so init-time
// instantiation is genuinely safe — but we boot from .onAppear for
// symmetry with the AppShortcutMonitor pattern. One trap-by-class-of-bug
// rule keeps App.init() inert. See the file header on App.swift for the
// full timing-trap context.
//
// Threading: bootIfNeeded() is @MainActor — Sparkle's controller must
// be constructed on main. Reads of `controller` / `updater` are also
// main-thread by contract; SwiftUI surfaces are already on main.

import Foundation
import Sparkle

@MainActor
final class UpdaterHost {

    static let shared = UpdaterHost()

    /// Boot-once flag. Idempotent — a second call is a no-op.
    private(set) var controller: SPUStandardUpdaterController?

    /// Convenience: the underlying SPUUpdater, or nil pre-boot.
    var updater: SPUUpdater? { controller?.updater }

    private init() {}

    /// Construct the updater controller exactly once. startingUpdater:
    /// true triggers automatic checks per Info.plist's
    /// SUEnableAutomaticChecks + SUScheduledCheckInterval. Delegates
    /// stay nil for v1 — the standard controller's defaults handle
    /// alert UI, install-on-quit, signature verification, etc.
    func bootIfNeeded() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
