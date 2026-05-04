// Encoder.swift
// Native services — AVAssetWriter wrapper for raw-video.mov encoding.
//
// Consumes CMSampleBuffers from SCKCapture and writes them to a .mov
// container with H.264 video. AVCaptureMovieFileOutput is the easier API
// but doesn't give us precise timing control, which the recorder needs
// for input-event-to-frame correlation.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 3
// (Native services layer) + § 5 (capture → edit, three streams in
// parallel) + docs/spec.md > AVFoundation encoder.
//
// Threading: append() must be called from a single producer (the SCK
// callback queue is the only intended caller in v1). AVAssetWriterInput
// internally serializes on its own queue. start() and finish() may be
// called from any thread; callers typically invoke them on a setup /
// teardown path before / after frames flow.

import AVFoundation
import CoreMedia
import Foundation

/// Final-class wrapper around AVAssetWriter for SCK frame ingestion.
public final class Encoder {

    // MARK: - Errors

    public enum EncoderError: LocalizedError, Equatable {
        case notStarted
        case alreadyStarted
        case cannotWrite(path: String, message: String)
        case appendFailed(message: String)
        case finishFailed(message: String)

        public var errorDescription: String? {
            switch self {
            case .notStarted:
                return "Encoder.append() called before start()."
            case .alreadyStarted:
                return "Encoder.start() called twice without an intervening finish()."
            case .cannotWrite(let path, let msg):
                return "Encoder cannot open writer at \(path): \(msg)"
            case .appendFailed(let msg):
                return "Encoder failed to append a frame: \(msg)"
            case .finishFailed(let msg):
                return "Encoder finish failed: \(msg)"
            }
        }
    }

    // MARK: - Inputs

    /// Output URL on disk. Caller owns the path; encoder will overwrite
    /// any existing file at start time.
    public let outputURL: URL
    /// Pixel dimensions of the captured frames.
    public let size: CGSize
    /// Target frame rate. Used to compute average bitrate hints; SCK's
    /// observed FPS may differ.
    public let frameRate: Int

    // MARK: - State

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted: Bool = false

    /// Lock-free progress flag for callers that want to gate appends
    /// without surfacing the writer.
    public private(set) var isWriting: Bool = false

    // MARK: - Init

    public init(outputURL: URL, size: CGSize, frameRate: Int) {
        self.outputURL = outputURL
        self.size = size
        self.frameRate = frameRate
    }

    // MARK: - Lifecycle

    /// Open the writer and prepare for input. Must be called once before
    /// the first `append`. Removes any existing file at `outputURL`.
    public func start() throws {
        if isWriting { throw EncoderError.alreadyStarted }

        // Clean any previous artifact at the path.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw EncoderError.cannotWrite(path: outputURL.path, message: error.localizedDescription)
        }

        // Reasonable defaults; spec calls out 1080p / ~5 Mbps as the
        // template. Bitrate scales linearly with pixel count.
        let bitsPerSecond = max(2_000_000, Int(Double(size.width * size.height) * 0.005))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: max(frameRate, 30),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw EncoderError.cannotWrite(
                path: outputURL.path,
                message: "writer rejected video input configuration"
            )
        }
        writer.add(input)

        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "writer.startWriting() returned false"
            throw EncoderError.cannotWrite(path: outputURL.path, message: msg)
        }

        // Defer startSession() until the first sample lands so we use a
        // real CMTime that matches the buffer presentation timestamps.
        self.writer = writer
        self.input = input
        self.sessionStarted = false
        self.isWriting = true
    }

    /// Append one CMSampleBuffer (typically straight from SCK). Drops
    /// frames silently when the input is not ready (back-pressure
    /// behavior — losing a frame here is better than blocking SCK).
    /// Throws if the encoder was never started or the writer reports
    /// failure mid-stream.
    public func append(_ buffer: CMSampleBuffer) throws {
        guard isWriting, let writer = writer, let input = input else {
            throw EncoderError.notStarted
        }
        guard CMSampleBufferDataIsReady(buffer) else { return }

        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        // Honor input back-pressure. AVAssetWriterInput surfaces this via
        // isReadyForMoreMediaData; appending while not ready logs a
        // warning and may corrupt the file.
        guard input.isReadyForMoreMediaData else { return }

        if !input.append(buffer) {
            let msg = writer.error?.localizedDescription ?? "input.append returned false"
            throw EncoderError.appendFailed(message: msg)
        }
    }

    /// Finalize the file. Async because AVAssetWriter's finishWriting is
    /// async by nature; we wrap the closure-completion shape into
    /// async/await for caller ergonomics.
    public func finish() async throws {
        guard isWriting, let writer = writer, let input = input else {
            throw EncoderError.notStarted
        }
        input.markAsFinished()
        await writer.finishWriting()
        let status = writer.status
        let writerError = writer.error
        self.isWriting = false
        self.writer = nil
        self.input = nil
        self.sessionStarted = false

        if status == .failed {
            throw EncoderError.finishFailed(
                message: writerError?.localizedDescription ?? "writer.status == .failed"
            )
        }
    }
}
