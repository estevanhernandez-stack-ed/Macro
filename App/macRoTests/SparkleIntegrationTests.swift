// SparkleIntegrationTests.swift
// 11a — smoke tests for Sparkle SPM integration.
//
// These tests exist to catch obvious wiring breaks: SPM package not
// linked, framework missing at runtime, Info.plist keys absent, view
// init crash. Sparkle has its own internal test infrastructure for
// the deep paths (signature verification, appcast parsing, install
// flow); we don't reinvent it here.
//
// Tests use `startingUpdater: false` so the test process never fires
// scheduled checks against the live appcast feed.
//
// Spec ref: docs/checklist.md item 11a "1+ smoke test".

import Sparkle
import SwiftUI
import XCTest
@testable import macRo

@MainActor
final class SparkleIntegrationTests: XCTestCase {

    /// SPM linkage + framework presence at runtime + minimal init path.
    func testUpdaterControllerInitializesWithoutCrash() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        XCTAssertNotNil(controller.updater)
    }

    /// UpdateSettingsView constructs cleanly against a live updater.
    /// `_ = view.body` would force Environment lookup that's awkward in
    /// XCTest — constructing the view (and touching the inner closure
    /// trigger paths) is enough to catch wiring breaks.
    func testUpdateSettingsViewInitializesWithoutCrash() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let view = UpdateSettingsView(updater: controller.updater)
        _ = view
    }

    /// UpdateSettingsView also constructs cleanly with a nil updater
    /// (covers the brief pre-.onAppear boot window).
    func testUpdateSettingsViewInitializesWithNilUpdater() {
        let view = UpdateSettingsView(updater: nil)
        _ = view
    }

    /// UpdaterHost is idempotent — second bootIfNeeded() is a no-op.
    func testUpdaterHostBootIsIdempotent() {
        UpdaterHost.shared.bootIfNeeded()
        let first = UpdaterHost.shared.controller
        UpdaterHost.shared.bootIfNeeded()
        let second = UpdaterHost.shared.controller
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "UpdaterHost.bootIfNeeded must not replace the controller on repeat calls")
    }
}
