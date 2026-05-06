// RecorderTests.swift
// Smoke tests for Recorder.shared — item 7c.
//
// Three tests, mirroring the EngineTests shape so /reflect can grep
// them as a coherent set:
//
//   • testStartRecordingRequiresAccessibilityPermission — the recorder's
//     pre-flight step 1 reads `AXIsProcessTrusted()` directly. Test
//     processes don't get the prompt UI and the granted state depends
//     entirely on whether the test runner host has been added to
//     System Settings → Privacy & Security → Accessibility. We can't
//     force `AXIsProcessTrusted` to return false without a permission
//     provider seam in Recorder.swift — adding one would touch the
//     domain logic, which 7c forbids. Instead, mirror EngineTests'
//     5c xctSkip pattern: when AX returns true (test runner already
//     trusted), skip with a TODO; when AX returns false, exercise the
//     real path and assert the throw is `.accessibilityDenied`.
//
//   • testAbortFromBackgroundThreadIsSafe — Recorder.shared.abort() is
//     contractually safe-from-any-state per the public-API doc comment
//     (see Recorder.swift:725). On an idle recorder, abort is a logged
//     no-op that ends the state machine at .idle. Mirrors
//     EngineTests.testAbortFromBackgroundThreadIsSafe — bound at 200ms
//     to catch any future regression that adds a deadlock path.
//
//   • testStopRecordingWithoutStartReturnsError — the state machine
//     refuses out-of-order calls. From .idle / terminal, stopRecording
//     must throw RecorderError.notRecording before doing any work.
//     Pure pre-flight short-circuit, safe in headless CI.

import XCTest
@testable import macRo

final class RecorderTests: XCTestCase {

    // MARK: - Helpers

    /// Per-test cleanup. Recorder.shared is a process-wide singleton;
    /// after stopRecording / abort the state ends at one of
    /// idle / .finished / .failed. We don't drain (none of these
    /// tests start an actual recording) but we keep the structure
    /// symmetric with EngineTests for future fixture-driven tests.
    override func tearDown() {
        super.tearDown()
    }

    // MARK: - (a) accessibility permission

    func testStartRecordingRequiresAccessibilityPermission() async throws {
        // Recorder.swift's startOnQueueAsync calls AXIsProcessTrusted()
        // as pre-flight step 1. If the test runner host is already
        // trusted (common on Estevan's dev machine — Xcode is
        // typically granted), the call short-circuits past the AX
        // check and proceeds to look for a Roblox window, which would
        // then either block on the SCK enumeration or fail with
        // .windowNotFound — neither is the assertion we want.
        //
        // Mirror item 5c's frontmost-app fallback: when the live
        // permission state doesn't match the test's needed precondition
        // (AX denied), xctSkip with a TODO referencing the seam.
        if AXIsProcessTrusted() {
            // TODO: needs permission-provider seam on Recorder so
            // tests can stub `AXIsProcessTrusted` → false. Deferred
            // to /iterate per 7c's "do not modify Recorder.swift's
            // logic" rule.
            throw XCTSkip(
                "Accessibility is granted on this test host; cannot exercise the "
                + "denied path without a permission-provider seam in Recorder.swift. "
                + "Deferred to /iterate."
            )
        }

        // AX is denied — exercise the real path. startRecording must
        // throw .accessibilityDenied AND end state at
        // .failed(.accessibilityDenied).
        do {
            try await Recorder.shared.startRecording(game: .untagged)
            XCTFail("expected RecorderError.accessibilityDenied, got success")
        } catch let error as RecorderError {
            switch error {
            case .accessibilityDenied:
                break // expected
            default:
                XCTFail("expected .accessibilityDenied, got \(error)")
            }
        } catch {
            XCTFail("expected RecorderError, got \(type(of: error)): \(error)")
        }

        // State must reflect the failure cleanly.
        let stateAfter = Recorder.shared.state
        switch stateAfter {
        case .failed(let err):
            XCTAssertEqual(err, .accessibilityDenied, "state should carry .accessibilityDenied")
        default:
            XCTFail("expected .failed(.accessibilityDenied), got \(stateAfter)")
        }
    }

    // MARK: - (b) abort from background thread

    func testAbortFromBackgroundThreadIsSafe() {
        // Recorder.shared.abort() is contractually safe-from-any-state
        // per Recorder.swift:725 ("Idempotent — safe to call from any
        // state."). On an idle recorder, abort should drain any
        // (non-existent) active session and land state at .idle without
        // blocking the caller.
        //
        // Bounded at 200ms to catch any future regression that adds a
        // synchronous wait or deadlock path. Mirrors
        // EngineTests.testAbortFromBackgroundThreadIsSafe.
        let expectation = XCTestExpectation(
            description: "Recorder.abort from background thread completes within 200ms"
        )

        let stateBefore = Recorder.shared.state

        Task.detached {
            try? await Recorder.shared.abort()
            // Hop to main to verify the @MainActor state setter has
            // run before we read state from the test's actor context.
            await MainActor.run {
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 0.2)

        let stateAfter = Recorder.shared.state

        // From .idle, abort lands at .idle. From a terminal state left
        // by a prior test, abort still lands at .idle (abort always
        // resets to .idle per Recorder.swift:745). What we reject is
        // a half-transition into .preflight / .recording / .finalizing.
        switch stateAfter {
        case .idle, .finished, .failed:
            break // coherent
        default:
            XCTFail("abort left recorder in non-coherent state \(stateAfter) (was \(stateBefore))")
        }
    }

    // MARK: - (c) stop without start

    func testStopRecordingWithoutStartReturnsError() async {
        // The state machine refuses out-of-order calls. From .idle (or
        // any terminal state), stopRecording reads the active session
        // under queue.sync; with no session it throws .notRecording
        // before doing any teardown work.
        //
        // Pure pre-flight short-circuit — no SCK, no EventTap, no
        // encoder. Safe in headless CI regardless of permission grants.
        do {
            _ = try await Recorder.shared.stopRecording()
            XCTFail("expected RecorderError.notRecording, got success")
        } catch let error as RecorderError {
            switch error {
            case .notRecording:
                break // expected
            default:
                XCTFail("expected .notRecording, got \(error)")
            }
        } catch {
            XCTFail("expected RecorderError, got \(type(of: error)): \(error)")
        }
    }
}
