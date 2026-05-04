// MacroBundleTests.swift
// Round-trip + cross-ref validation tests for the MacroBundle IO layer.
//
// Strategy:
//   • Locate the test fixture bundle relative to this source file (we
//     copy it into the test bundle resources via XcodeGen, but the
//     source-file lookup is the most reliable across xcodebuild + Xcode
//     IDE because the test target's resources path is configurable).
//   • Load it. Validate it. Round-trip save → re-load → equals.
//   • Negative case: copy the fixture into a tmp dir, delete the gate
//     PNG, attempt to load — expect a thrown crossRef error.

import XCTest
@testable import macRo

final class MacroBundleTests: XCTestCase {

    // MARK: - Fixture path

    /// Resolve the fixture path relative to this source file. Works in
    /// both `xcodebuild test` and Xcode's test runner because `#filePath`
    /// is the absolute path of this source on the build host (the
    /// fixtures are checked into the repo alongside this file).
    private var fixtureURL: URL {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent() // .../macRoTests/
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("sample-macro.macro", isDirectory: true)
    }

    // MARK: - Tests

    func testLoadValidFixture() throws {
        let bundle = try MacroBundle.load(at: fixtureURL)

        XCTAssertEqual(bundle.manifest.id, "sample-fixture-v1")
        XCTAssertEqual(bundle.manifest.schemaVersion, 1)
        XCTAssertEqual(bundle.manifest.version, "0.1.0")
        XCTAssertFalse(bundle.manifest.factoryPatchable)
        XCTAssertEqual(bundle.timeline.events.count, 5)
        XCTAssertEqual(bundle.timeline.subs?.count, 1)
        XCTAssertEqual(bundle.timeline.stopOn?.count, 1)
    }

    func testValidationProducesNoErrorsForFixture() throws {
        let bundle = try MacroBundle.load(at: fixtureURL)
        let gateRefs: Set<String> = ["img-test"] // matches gates/img-test.png
        let findings = MacroBundle.validate(bundle, availableGateRefs: gateRefs)
        let errors = findings.filter { $0.level == .error }
        XCTAssertEqual(errors, [], "expected zero error-level findings, got: \(errors)")
    }

    func testRoundTripSaveAndLoad() throws {
        let original = try MacroBundle.load(at: fixtureURL)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macRoTests-roundtrip-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("roundtrip.macro", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try MacroBundle.save(original, to: tmp)

        // Save does not copy gate PNGs (per item 3 architectural choice);
        // copy the one PNG over so cross-ref validation passes on reload.
        let srcGate = fixtureURL
            .appendingPathComponent("gates", isDirectory: true)
            .appendingPathComponent("img-test.png")
        let dstGate = tmp
            .appendingPathComponent("gates", isDirectory: true)
            .appendingPathComponent("img-test.png")
        try FileManager.default.copyItem(at: srcGate, to: dstGate)

        let reloaded = try MacroBundle.load(at: tmp)
        XCTAssertEqual(original, reloaded)
    }

    func testMissingGateImageProducesCrossRefError() throws {
        // Copy fixture to tmp, delete the gate PNG, attempt to load.
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macRoTests-missingGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let bundleCopy = tmpRoot.appendingPathComponent("sample-macro.macro", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureURL, to: bundleCopy)
        try FileManager.default.removeItem(
            at: bundleCopy.appendingPathComponent("gates/img-test.png")
        )

        XCTAssertThrowsError(try MacroBundle.load(at: bundleCopy)) { error in
            guard let bundleError = error as? MacroBundle.MacroBundleError else {
                XCTFail("expected MacroBundleError, got \(error)")
                return
            }
            switch bundleError {
            case .crossRef(let field, let missing):
                XCTAssertTrue(field.contains("ref"), "field path mentions ref: \(field)")
                XCTAssertTrue(missing.contains("img-test"), "missing message mentions img-test: \(missing)")
            default:
                XCTFail("expected .crossRef, got \(bundleError)")
            }
        }
    }

    func testNotABundleErrorWhenPathDoesNotExist() {
        let bogus = URL(fileURLWithPath: "/var/empty/definitely-not-a-bundle.macro")
        XCTAssertThrowsError(try MacroBundle.load(at: bogus)) { error in
            guard let bundleError = error as? MacroBundle.MacroBundleError else {
                XCTFail("expected MacroBundleError, got \(error)")
                return
            }
            switch bundleError {
            case .notABundle:
                break
            default:
                XCTFail("expected .notABundle, got \(bundleError)")
            }
        }
    }
}
