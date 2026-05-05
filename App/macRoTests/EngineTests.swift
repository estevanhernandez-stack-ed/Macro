// EngineTests.swift
// Smoke tests for the playback engine's pre-flight + abort + safety
// surfaces. Item 5c — the two tests that don't need a target window
// land cleanly; the frontmost-app safety test xctSkips pending a
// `frontmostBundleProvider` test seam (deferred to /iterate per the
// 5c prompt's "do NOT modify Engine.swift to ADD a seam" rule).
//
// Strategy:
//   • testUnsupportedSchemaVersionRefuses — construct a synthetic
//     MacroBundleData with schemaVersion: 999 (Engine.supported is 1).
//     `Engine.shared.run(_:)` MUST throw EngineError.unsupportedSchemaVersion.
//     This is a pure pre-flight short-circuit — no window, no SCK, no
//     timeline execution; safe in headless CI.
//   • testAbortFromBackgroundThreadIsSafe — the abort surface MUST be
//     callable from any thread per spec § 6 ("the global abort hotkey
//     is always available — no engine state, no UI flow may block
//     it"). On an idle engine, abort is a no-op; the test verifies the
//     queue.async hop completes cleanly, state stays coherent, and the
//     call returns without deadlock. Bounded by a 200ms expectation
//     to catch any future regression that adds a blocking path.
//     (Deeper "abort transitions a running engine to .aborted within
//     200ms" verification needs a recorded gameplay fixture; owed at
//     item 6's polished fixtures.)
//   • testFrontmostAppSafetyRule — xctSkip with TODO referencing the
//     missing test seam. Engine.swift's chokepoint reads NSWorkspace
//     directly; tests run headlessly so the test process IS frontmost.
//     No way to verify the safety rule without injecting a stub for
//     the bundle-id check. Adding the seam = touching Engine.swift
//     logic, which 5c forbids. Deferred to /iterate.

import XCTest
@testable import macRo

final class EngineTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal in-memory bundle with the given schemaVersion.
    /// Empty timeline, no target — the only non-default field is the
    /// schemaVersion (everything else is a placeholder so Manifest's
    /// init is satisfied). Used for the unsupportedSchemaVersion test;
    /// the engine refuses before any of the other fields are read.
    private func makeBundle(schemaVersion: Int) -> MacroBundleData {
        let manifest = Manifest(
            id: "test-bundle",
            name: "Test Bundle",
            version: "0.0.1",
            schemaVersion: schemaVersion,
            factoryPatchable: false
        )
        let timeline = Timeline(events: [])
        return MacroBundleData(manifest: manifest, timeline: timeline)
    }

    // MARK: - (a) unsupportedSchemaVersion

    func testUnsupportedSchemaVersionRefuses() async throws {
        // 999 >> Engine.supportedSchemaVersion (currently 1). Engine
        // pre-flight step 1 throws before any other side effect.
        let bundle = makeBundle(schemaVersion: 999)

        do {
            try await Engine.shared.run(bundle)
            XCTFail("expected EngineError.unsupportedSchemaVersion, got success")
        } catch let error as EngineError {
            switch error {
            case .unsupportedSchemaVersion(let found, let supported):
                XCTAssertEqual(found, 999, "found should echo the bundle's schemaVersion")
                XCTAssertEqual(
                    supported,
                    Engine.supportedSchemaVersion,
                    "supported should echo Engine.supportedSchemaVersion"
                )
            default:
                XCTFail("expected .unsupportedSchemaVersion, got \(error)")
            }
        } catch {
            XCTFail("expected EngineError, got \(error)")
        }
    }

    // MARK: - (b) abort from background thread

    func testAbortFromBackgroundThreadIsSafe() {
        // The abort surface is contractually safe-from-any-thread per
        // spec § 6. On an idle engine, abort is a logged no-op — the
        // queue.async hop must complete without blocking the caller
        // and without leaving the state machine in a corrupt shape.
        //
        // We bound the wait at 200ms to catch any future regression
        // that adds a synchronous wait or a deadlock path. The test
        // does not assert .aborted because no run was active; the
        // weaker (and honest-to-the-current-design) assertion is
        // "state survives the abort call coherently."
        let expectation = XCTestExpectation(
            description: "abort from background thread completes within 200ms"
        )

        let stateBefore = Engine.shared.state

        DispatchQueue.global(qos: .userInitiated).async {
            Engine.shared.abort(reason: .userHotkey)
            // Hop back to verify the engine queue processed the call.
            // Abort is async-fire-and-forget, so we give the engine
            // queue one tick to drain before reading state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 0.2)

        let stateAfter = Engine.shared.state

        // On an idle engine, abort leaves state at .idle. On a terminal
        // engine (left over from a prior test in this run), the state
        // remains terminal. Either is coherent; what we reject is a
        // half-transition into something like .preflight or .running.
        switch stateAfter {
        case .idle, .finished, .aborted, .failed:
            break // coherent
        default:
            XCTFail("abort left engine in non-coherent state \(stateAfter) (was \(stateBefore))")
        }
    }

    // MARK: - (c) frontmost-app safety rule (deferred)

    func testFrontmostAppSafetyRule() throws {
        // Engine.swift's `synthesize(_:)` chokepoint reads
        // NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // directly and refuses to synth when it equals macRo's bundle
        // id. Tests run headlessly so the test process (xctest) IS
        // frontmost — there's no path to force the equality check
        // without injecting a stub for the bundle-id read.
        //
        // Adding a `frontmostBundleProvider: () -> String?` test seam
        // would require a logic change in Engine.swift, which 5c
        // forbids ("Do NOT modify Engine.swift to ADD a seam — flag
        // it as deferred-to-/iterate"). The hard-safety rule is
        // exercised via in-engine NSWorkspace lookups during real runs
        // and verified manually post-item-6 with a hand-authored
        // bundle.
        //
        // TODO: needs frontmost-bundle-provider seam; revisit at /iterate.
        throw XCTSkip(
            "Frontmost-app safety rule needs a bundle-id provider seam in Engine.swift. "
            + "Deferred to /iterate per 5c's 'do not modify Engine.swift' rule."
        )
    }
}
