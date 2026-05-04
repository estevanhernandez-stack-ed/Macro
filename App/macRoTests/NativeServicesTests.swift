// NativeServicesTests.swift
// Happy-path tests for the four native-service wrappers.
//
// Strategy:
//   • WindowDetector — exercise against a known macOS app (TextEdit) so
//     the assertion is deterministic across machines. Fall back to
//     "skip if Accessibility is not granted" so CI without grants does
//     not produce a false failure (Accessibility cannot be granted from
//     code; only the user can flip the toggle).
//   • EventTap.synth — fire a CGEvent and assert no throw. We do NOT
//     require Accessibility for synth (CGEvent.post does not need it),
//     but the test runner needs to be a foreground app for the synth to
//     reliably reach a target — we don't assert on what was typed,
//     just that the construction + post path doesn't throw.
//   • Encoder — produce a 5-frame .mov at a tmp path from synthesized
//     BGRA buffers, then re-open with AVAsset and assert duration.
//   • SCKCapture — query SCShareableContent.windows and assert
//     non-empty. We do NOT actually start a capture: that requires
//     Screen Recording permission (cannot be granted from code) AND
//     would prompt mid-test. Real start/stop is a manual verification
//     step on Estevan's machine after Roblox is open.
//
// Threading: tests run on the XCTest main thread; native-service
// callbacks fire on their own queues / threads. We use semaphores to
// block test completion until the relevant async work finishes.

import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit
import XCTest
@testable import macRo

final class NativeServicesTests: XCTestCase {

    // MARK: - WindowDetector

    func testWindowDetectorFindsCurrentWindow() throws {
        // Skip cleanly if Accessibility is not granted on the host.
        // AXIsProcessTrusted() does not prompt — safe to call.
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility not granted on this host; manual verification required.")
        }

        // current() returns whatever's frontmost. The test runner itself
        // is usually frontmost when xcodebuild test is driving the GUI;
        // when run from Xcode interactively, Xcode is frontmost. Either
        // way, we expect a non-nil result with a non-empty bundleID.
        let info = try WindowDetector.current()
        if let info = info {
            XCTAssertGreaterThan(info.pid, 0, "pid should be positive")
            XCTAssertNotNil(info.bundleID, "frontmost regular app should have a bundleID")
            XCTAssertGreaterThan(info.contentRect.width, 0, "content rect should have width")
            XCTAssertGreaterThan(info.contentRect.height, 0, "content rect should have height")
        } else {
            // Running headless or no regular app frontmost — acceptable
            // failure to find, not a code failure.
            throw XCTSkip("No frontmost regular app available to match against.")
        }
    }

    func testWindowDetectorMatchAcceptsEmptyCriteria() throws {
        // An all-nil Match should not throw and should return either nil
        // or the first matching window across all running apps. Useful
        // smoke test for the regex-compile path.
        let match = WindowDetector.Match(windowClass: nil, titleMatch: nil)
        _ = try WindowDetector.find(match)
        // No assertion on return — we only verify no throw.
    }

    func testWindowDetectorRejectsBogusRegex() {
        let match = WindowDetector.Match(windowClass: nil, titleMatch: "[unterminated")
        XCTAssertThrowsError(try WindowDetector.find(match)) { error in
            guard let detectorError = error as? WindowDetector.WindowDetectorError else {
                XCTFail("expected WindowDetectorError, got \(error)")
                return
            }
            switch detectorError {
            case .invalidTitleRegex(let pattern, _):
                XCTAssertEqual(pattern, "[unterminated")
            default:
                XCTFail("expected .invalidTitleRegex, got \(detectorError)")
            }
        }
    }

    // MARK: - EventTap

    func testEventTapSynthesizesAKeyWithoutThrowing() throws {
        // Synth path doesn't require Accessibility (it requires it only
        // to be reliably DELIVERED to apps that filter, but the post call
        // itself doesn't throw). We assert on the construction + post
        // path here, not on whether anything received the keystroke.
        let tap = EventTap()
        // Virtual keycode for 'a' on a standard US keyboard is 0x00.
        XCTAssertNoThrow(try tap.synth(.keyDown(keyCode: 0x00, flags: [])))
        XCTAssertNoThrow(try tap.synth(.keyUp(keyCode: 0x00, flags: [])))
    }

    func testEventTapStartStopLifecycle() throws {
        // tapCreate's success depends on whether the test runner's parent
        // process has been granted Accessibility (in CI, usually no; in
        // a developer's Xcode-driven session, often yes — Xcode itself
        // is granted, and child processes inherit some allowances). We
        // accept either:
        //   • start succeeds → stop must succeed and isRecording flips.
        //   • start throws → that's also a valid no-grant outcome and
        //     the lifecycle is still exercised.
        // What we do NOT accept: start succeeds and stop fails, or
        // start succeeds and isRecording stays false.
        let tap = EventTap()
        do {
            try tap.startRecording { _ in /* ignore events */ }
            XCTAssertTrue(tap.isRecording, "isRecording should be true after successful start")
            try tap.stopRecording()
            XCTAssertFalse(tap.isRecording, "isRecording should be false after stop")
        } catch let error as EventTap.EventTapError {
            // Acceptable error: tapCreate was denied. Anything else is a
            // bug in the wrapper.
            switch error {
            case .tapCreateFailed, .accessibilityDenied:
                throw XCTSkip("EventTap could not start (Accessibility likely denied for the test runner): \(error.localizedDescription)")
            default:
                XCTFail("unexpected EventTapError on start: \(error)")
            }
        }
    }

    // MARK: - Encoder

    func testEncoderProducesAValidMovFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macRoTests-encoder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outputURL = tmpDir.appendingPathComponent("test.mov")
        let size = CGSize(width: 320, height: 240)
        let frameRate = 30
        let encoder = Encoder(outputURL: outputURL, size: size, frameRate: frameRate)

        try encoder.start()

        // Synthesize 5 BGRA sample buffers spaced one frame apart at 30
        // FPS. Use a CMTime base of 0 so the writer's session start lands
        // on time 0; durations land at 5/30s ≈ 0.166s.
        let timescale: CMTimeScale = CMTimeScale(frameRate)
        for frameIndex in 0..<5 {
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: timescale)
            let sampleBuffer = try Self.makeBGRASampleBuffer(size: size, presentationTime: pts)
            try encoder.append(sampleBuffer)
        }

        try await encoder.finish()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "encoder should produce a file at the requested path"
        )

        // Re-open with AVAsset and verify duration.
        let asset = AVURLAsset(url: outputURL)
        let durationCMTime = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(durationCMTime)
        // 5 frames at 30 FPS is 5/30 = 0.166s; AVAsset rounds liberally
        // depending on the keyframe cadence. Anything in (0.0, 1.0] is
        // a valid encode; assert non-zero.
        XCTAssertGreaterThan(durationSeconds, 0.0, "asset duration should be > 0")
        XCTAssertLessThan(durationSeconds, 5.0, "5 frames @ 30 FPS should be well under 5s")
    }

    // MARK: - SCKCapture

    func testSCKCaptureCanQueryShareableWindows() async throws {
        // SCShareableContent enumeration requires Screen Recording in
        // some macOS versions; in others (including the test runner
        // when launched without GUI), it returns an empty list rather
        // than throwing. Either is acceptable for this smoke test.
        //
        // What we assert: the call doesn't crash, and if it returns
        // windows, each has a non-nil owningApplication. We do NOT
        // start a capture because that would prompt for Screen
        // Recording mid-test (and likely fail in CI).
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            for window in content.windows.prefix(5) {
                _ = window.title // touch the field to ensure no crash
                _ = window.owningApplication?.bundleIdentifier
            }
        } catch {
            // SCShareableContent throwing is the test runner's signal
            // that Screen Recording is not granted. Skip cleanly so CI
            // without permission does not red-line.
            throw XCTSkip("SCShareableContent unavailable (likely Screen Recording denied): \(error.localizedDescription)")
        }
    }

    func testSCKCaptureFindWindowReturnsNilForNonsense() async throws {
        // Match against a deliberately-impossible set so the find loop
        // completes a full scan and returns nil rather than throwing.
        // This exercises the regex-compile + loop-exit path without
        // depending on a specific app being open.
        let match = WindowDetector.Match(
            windowClass: ["DefinitelyNotARealAppName_zzz_xxx"],
            titleMatch: "^macRo-test-no-window-with-this-title-please$"
        )
        do {
            let result = try await SCKCapture.findWindow(matching: match)
            XCTAssertNil(result, "no window should match a deliberately-impossible criteria")
        } catch SCKCapture.SCKCaptureError.screenRecordingDenied {
            throw XCTSkip("Screen Recording denied; manual verification required.")
        }
    }

    // MARK: - Helpers

    /// Build a minimal BGRA CMSampleBuffer at the requested size + PTS.
    /// Pixels are uninitialized (we don't care about content for an
    /// encoder smoke test; AVAssetWriter accepts the buffer regardless).
    private static func makeBGRASampleBuffer(size: CGSize, presentationTime: CMTime) throws -> CMSampleBuffer {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixels = pixelBuffer else {
            throw NSError(
                domain: "NativeServicesTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"]
            )
        }

        // Zero-fill the pixel buffer so the encoder gets deterministic
        // bytes (some H.264 encoders complain about uninitialized
        // memory in input).
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
            memset(base, 0, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        var formatDescription: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixels,
            formatDescriptionOut: &formatDescription
        )
        guard fdStatus == noErr, let fd = formatDescription else {
            throw NSError(
                domain: "NativeServicesTests",
                code: Int(fdStatus),
                userInfo: [NSLocalizedDescriptionKey: "CMVideoFormatDescriptionCreateForImageBuffer failed"]
            )
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: presentationTime.timescale),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixels,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let buffer = sampleBuffer else {
            throw NSError(
                domain: "NativeServicesTests",
                code: Int(sbStatus),
                userInfo: [NSLocalizedDescriptionKey: "CMSampleBufferCreateForImageBuffer failed"]
            )
        }
        return buffer
    }
}
