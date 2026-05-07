// PS99SeedMacrosTests.swift
// Item 10b — fixture-load tests for the 5 hand-authored Pet Simulator 99
// seed macro bundles at `games/pet-sim-99/seed-macros/`.
//
// Each test loads one bundle via `MacroBundle.load(at:)` and asserts the
// manifest fields the validator pass relies on (id, version, factoryPatchable
// per the brief, target.placeId-via-game). Cross-ref validation runs inside
// `load(at:)` — gate refs that don't resolve to a PNG on disk would already
// surface as a thrown `MacroBundleError.crossRef` before this test sees the
// bundle, so a clean load is the structural pass.
//
// Pattern matches `EngineTests.fixtureURL` — uses `#filePath`-relative URL
// resolution to walk up from `App/macRoTests/PS99SeedMacrosTests.swift`
// to the repo root, then down into `games/pet-sim-99/seed-macros/<name>.macro/`.
//
// Empirical "engine actually plays the macro against PS99" verification owes
// real PS99 captures replacing the 1×1 RGBA stub PNGs and is owed-to-Estevan
// at the CHECKPOINT debt pass. Stub PNGs are fine for 10b's structural pass.

import XCTest
@testable import macRo

@MainActor
final class PS99SeedMacrosTests: XCTestCase {

    // MARK: - Fixture path

    /// Resolve a seed-macro bundle URL relative to this source file. Walks
    /// from `App/macRoTests/PS99SeedMacrosTests.swift` up to the repo root,
    /// then into `games/pet-sim-99/seed-macros/<name>.macro/`. The repo path
    /// is the canonical source — same pattern as MacroBundleTests + the
    /// item-6 fixture-smoke tests in EngineTests.
    private func seedMacroURL(named name: String) -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // App/macRoTests/
            .deletingLastPathComponent()  // App/
            .deletingLastPathComponent()  // repo root
        return repoRoot
            .appendingPathComponent("games", isDirectory: true)
            .appendingPathComponent("pet-sim-99", isDirectory: true)
            .appendingPathComponent("seed-macros", isDirectory: true)
            .appendingPathComponent("\(name).macro", isDirectory: true)
    }

    // MARK: - Tests

    func testAutoHatchLoadsCleanly() throws {
        let url = seedMacroURL(named: "auto-hatch")
        let bundle = try MacroBundle.load(at: url)
        XCTAssertEqual(bundle.manifest.id, "auto-hatch")
        XCTAssertEqual(bundle.manifest.name, "Auto Hatch")
        XCTAssertEqual(bundle.manifest.version, "1.0.0")
        XCTAssertEqual(bundle.manifest.schemaVersion, 1)
        XCTAssertTrue(bundle.manifest.factoryPatchable)
        XCTAssertEqual(bundle.manifest.game?.placeId, 8737899170)
        // Loop + delayMs + stopOn block — the long-running, Mythic-interrupt
        // demo. Last event is the loop; stopOn is on the timeline.
        XCTAssertEqual(bundle.timeline.stopOn?.count, 1)
        if case .loop(let payload) = bundle.timeline.events.last! {
            XCTAssertEqual(payload.delayMs, 1500)
            XCTAssertEqual(payload.target, 0.0)
        } else {
            XCTFail("auto-hatch timeline must end in a loop event")
        }
    }

    func testAutoGrindBiome1LoadsCleanly() throws {
        let url = seedMacroURL(named: "auto-grind-biome-1")
        let bundle = try MacroBundle.load(at: url)
        XCTAssertEqual(bundle.manifest.id, "auto-grind-biome-1")
        XCTAssertEqual(bundle.manifest.name, "Auto Grind — Biome 1")
        XCTAssertEqual(bundle.manifest.version, "1.0.0")
        XCTAssertEqual(bundle.manifest.schemaVersion, 1)
        XCTAssertTrue(bundle.manifest.factoryPatchable)
        XCTAssertEqual(bundle.manifest.game?.placeId, 8737899170)
        // 1080p target — the WOW-moment macro's MOVE-lane premise depends on
        // the recorded resolution being a common Roblox window size.
        XCTAssertEqual(bundle.manifest.target?.recordedResolution?.width, 1920)
        XCTAssertEqual(bundle.manifest.target?.recordedResolution?.height, 1080)
        // No gates by design — pure WASD held-key sequences.
        let gateEvents = bundle.timeline.events.filter {
            if case .gate = $0 { return true }
            return false
        }
        XCTAssertEqual(gateEvents.count, 0, "auto-grind-biome-1 is the MOVE-lane demo and should contain no gate events")
    }

    func testAutoRebirthLoadsCleanly() throws {
        let url = seedMacroURL(named: "auto-rebirth")
        let bundle = try MacroBundle.load(at: url)
        XCTAssertEqual(bundle.manifest.id, "auto-rebirth")
        XCTAssertEqual(bundle.manifest.name, "Auto Rebirth")
        XCTAssertEqual(bundle.manifest.version, "1.0.0")
        XCTAssertEqual(bundle.manifest.schemaVersion, 1)
        XCTAssertTrue(bundle.manifest.factoryPatchable)
        XCTAssertEqual(bundle.manifest.game?.placeId, 8737899170)
        // image-anchored resolution policy is the GATES demo's premise.
        XCTAssertEqual(bundle.manifest.target?.resolutionPolicy, .imageAnchored)
        // Two img gates with onFail=abort.
        let gateEvents = bundle.timeline.events.compactMap { event -> TimelineEvent.TimelineEventGatePayload? in
            if case .gate(let payload) = event { return payload }
            return nil
        }
        XCTAssertEqual(gateEvents.count, 2)
        for gate in gateEvents {
            XCTAssertEqual(gate.gateKind, .img)
            XCTAssertEqual(gate.onFail, .literal(.abort))
        }
    }

    func testAutoFusePetsLoadsCleanly() throws {
        let url = seedMacroURL(named: "auto-fuse-pets")
        let bundle = try MacroBundle.load(at: url)
        XCTAssertEqual(bundle.manifest.id, "auto-fuse-pets")
        XCTAssertEqual(bundle.manifest.name, "Auto Fuse Pets")
        XCTAssertEqual(bundle.manifest.version, "1.0.0")
        XCTAssertEqual(bundle.manifest.schemaVersion, 1)
        XCTAssertTrue(bundle.manifest.factoryPatchable)
        XCTAssertEqual(bundle.manifest.game?.placeId, 8737899170)
        // subs + stopOn combo — the demo's premise.
        XCTAssertEqual(bundle.timeline.subs?.count, 1)
        XCTAssertNotNil(bundle.timeline.subs?["fuseOne"])
        XCTAssertEqual(bundle.timeline.stopOn?.count, 1)
        // Main timeline invokes fuseOne via invokeSub.
        let invokeSubEvents = bundle.timeline.events.compactMap { event -> TimelineEvent.TimelineEventInvokeSubPayload? in
            if case .invokeSub(let payload) = event { return payload }
            return nil
        }
        XCTAssertEqual(invokeSubEvents.count, 1)
        XCTAssertEqual(invokeSubEvents.first?.name, "fuseOne")
    }

    func testClanBattleHelperLoadsCleanly() throws {
        let url = seedMacroURL(named: "clan-battle-helper")
        let bundle = try MacroBundle.load(at: url)
        XCTAssertEqual(bundle.manifest.id, "clan-battle-helper")
        XCTAssertEqual(bundle.manifest.name, "Clan Battle Helper")
        XCTAssertEqual(bundle.manifest.version, "1.0.0")
        XCTAssertEqual(bundle.manifest.schemaVersion, 1)
        // Placeholder — factoryPatchable=false intentionally (the factory
        // ignores not-yet-authored placeholders). Refines post-CHECKPOINT.
        XCTAssertFalse(bundle.manifest.factoryPatchable)
        XCTAssertEqual(bundle.manifest.game?.placeId, 8737899170)
        // Minimal valid timeline — single keyDown/keyUp pair.
        XCTAssertEqual(bundle.timeline.events.count, 2)
        XCTAssertNil(bundle.timeline.stopOn)
        XCTAssertNil(bundle.timeline.subs)
    }
}
