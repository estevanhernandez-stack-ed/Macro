// EditorCropper.swift
// UI — modal sheet for the image-trigger / position-trigger cropper
// (item 8b).
//
// Triggered by the toolbar's `+ Image trigger` / `+ Position trigger`
// buttons. Loads the snapshot at the current playhead time
// (`gates/snap-<elapsed-ms>.png` — recorder dropped these every 200ms
// during capture per item 5; if no exact ms-match, we pick the nearest
// snapshot). User drags to draw a crop rectangle. On confirm:
//
//   1. Crop the image region into an NSImage.
//   2. Generate a UUID-derived 8-char hex slug — `img-<hex>` for IMG,
//      `pos-<hex>` for POS.
//   3. Save the cropped PNG to `<bundle>/gates/<gateKind>-<slug>.png`.
//   4. Hand the gate (kind + ref + t) back to the host via the
//      `onConfirm` closure — host wraps the insertion in an
//      `EditorCommand` so undo/redo covers it.
//
// We never write the timeline.yaml here — disk persistence lands at
// 8c's save flow. The PNG IS written eagerly because it's the
// load-bearing artifact; the timeline only references it by id, and
// the YAML save in 8c will see the PNG already in `gates/` and emit
// the matching ref.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 4
// (image refs by ID) + .claude/rules/macro-format-rules.md (image ref
// naming convention).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Cropper config

/// What to drop on confirm — image trigger (IMG, default onFail =
/// continue) or position trigger (POS, default onFail = abort). The
/// kind drives the gate-event payload AND the on-disk filename prefix.
enum CropperKind {
    case image
    case position

    var gateKind: TimelineEvent.TimelineEventGateKind {
        switch self {
        case .image: return .img
        case .position: return .pos
        }
    }

    /// Default `onFail` policy per spec § 4 + macro-format-rules.md.
    /// IMG = continue (UI cue not present → press on, retry later).
    /// POS = abort (position not where we expect → stop, the macro is
    /// off-rails).
    var defaultOnFail: TimelineEvent.TimelineEventOnFail {
        switch self {
        case .image:    return .literal(.continue)
        case .position: return .literal(.abort)
        }
    }

    /// Human-facing copy.
    var displayName: String {
        switch self {
        case .image:    return "Image trigger"
        case .position: return "Position trigger"
        }
    }
}

// MARK: - Result

/// What the cropper hands back on confirm. The host inserts a gate
/// event and registers an undo command.
struct CropperResult {
    let gateKind: TimelineEvent.TimelineEventGateKind
    let ref: String                                // e.g., "<8-hex>" — no prefix
    let originalT: Double                          // original-timeline seconds
    let onFail: TimelineEvent.TimelineEventOnFail
}

// MARK: - EditorCropper

struct EditorCropper: View {

    let bundleURL: URL
    let kind: CropperKind
    /// Original-timeline time at which the gate should drop. EditorView
    /// converts the compressed playhead to original via
    /// `WorkingState.originalTime(fromCompressed:)` before opening the
    /// sheet — the cropper itself never touches cut math.
    let originalT: Double

    let onCancel: () -> Void
    let onConfirm: (CropperResult) -> Void

    @State private var nsImage: NSImage? = nil
    @State private var loadError: String? = nil
    /// Crop rect in IMAGE-pixel coordinates. We translate from the
    /// SwiftUI display rect on confirm so the saved PNG matches the
    /// user's drawn region 1:1 regardless of view-resize.
    @State private var cropRectImage: CGRect? = nil

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            header

            ZStack {
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.md)
                    .fill(MacRoTheme.Color.bgSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.md)
                            .strokeBorder(MacRoTheme.Color.laneBorder, lineWidth: 1)
                    )

                if let nsImage {
                    croppingCanvas(image: nsImage)
                } else if let loadError {
                    Text(loadError)
                        .font(MacRoTheme.Font.bodySmall)
                        .foregroundStyle(MacRoTheme.Color.fg2)
                        .multilineTextAlignment(.center)
                        .padding(MacRoTheme.Spacing.lg)
                } else {
                    ProgressView()
                        .tint(MacRoTheme.Color.brandCyan)
                }
            }
            .frame(minHeight: 360)

            Divider().background(MacRoTheme.Color.laneBorder)

            footer
        }
        .padding(MacRoTheme.Spacing.lg)
        .frame(width: 720, height: 560)
        .background(MacRoTheme.Color.bgPage)
        .task {
            loadSnapshot()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: MacRoTheme.Spacing.sm) {
            Text(kind.displayName)
                .font(MacRoTheme.Font.heading1)
                .foregroundStyle(MacRoTheme.Color.fg1)
            Text("· t=\(String(format: "%.2f", originalT))s")
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Spacer()
        }
        Text(headerHint)
            .font(MacRoTheme.Font.bodySmall)
            .foregroundStyle(MacRoTheme.Color.fg2)
    }

    private var headerHint: String {
        switch kind {
        case .image:
            return "Draw a tight rectangle around the UI element you want the engine to verify before continuing. IMG gates use a ~95% similarity threshold — crop precisely."
        case .position:
            return "Draw a generous rectangle around the environment region you want the engine to confirm before continuing. POS gates use a ~85% threshold — bigger crops are forgiving."
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private func croppingCanvas(image nsImage: NSImage) -> some View {
        GeometryReader { proxy in
            let displayRect = aspectFitRect(
                image: nsImage.size,
                in: proxy.size
            )
            let scale = displayRect.width / max(nsImage.size.width, 1)

            ZStack(alignment: .topLeading) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                if let crop = cropRectImage {
                    let displayCrop = CGRect(
                        x: displayRect.minX + crop.minX * scale,
                        y: displayRect.minY + crop.minY * scale,
                        width: crop.width * scale,
                        height: crop.height * scale
                    )
                    Rectangle()
                        .strokeBorder(MacRoTheme.Color.brandCyan, lineWidth: 2)
                        .background(
                            Rectangle().fill(MacRoTheme.Color.brandCyan.opacity(0.12))
                        )
                        .frame(width: displayCrop.width, height: displayCrop.height)
                        .offset(x: displayCrop.minX, y: displayCrop.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // Clamp to display rect, then translate to image space.
                        let start = clampPoint(value.startLocation, to: displayRect)
                        let curr  = clampPoint(value.location, to: displayRect)
                        let raw = CGRect(
                            x: min(start.x, curr.x),
                            y: min(start.y, curr.y),
                            width: abs(curr.x - start.x),
                            height: abs(curr.y - start.y)
                        )
                        // Translate to image-pixel coordinates.
                        let imageRect = CGRect(
                            x: (raw.minX - displayRect.minX) / scale,
                            y: (raw.minY - displayRect.minY) / scale,
                            width: raw.width / scale,
                            height: raw.height / scale
                        )
                        cropRectImage = imageRect
                    }
            )
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: MacRoTheme.Spacing.md) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .padding(.horizontal, MacRoTheme.Spacing.md)
                    .padding(.vertical, MacRoTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                            .strokeBorder(MacRoTheme.Color.fg3.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()

            if cropRectImage == nil {
                Text("Drag on the snapshot to draw a crop region")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }

            Button(action: confirm) {
                Text("Drop \(kind.displayName.lowercased())")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.bgPage)
                    .padding(.horizontal, MacRoTheme.Spacing.md)
                    .padding(.vertical, MacRoTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                            .fill(canConfirm
                                  ? MacRoTheme.Color.productTeal
                                  : MacRoTheme.Color.productTeal.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var canConfirm: Bool {
        guard let r = cropRectImage else { return false }
        return r.width >= 4 && r.height >= 4 && nsImage != nil
    }

    // MARK: - Snapshot loading

    private func loadSnapshot() {
        let gatesDir = bundleURL.appendingPathComponent("gates", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gatesDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            self.loadError = "This bundle has no `gates/` folder yet, so there are no snapshots to crop. Re-record with snapshots enabled to use the cropper."
            return
        }

        // Find every snap-<ms>.png and pick the closest to playhead.
        let contents = (try? fm.contentsOfDirectory(at: gatesDir, includingPropertiesForKeys: nil)) ?? []
        let snaps = contents.compactMap { url -> (URL, Int)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("snap-"),
                  let ms = Int(name.dropFirst("snap-".count)) else { return nil }
            return (url, ms)
        }
        guard !snaps.isEmpty else {
            self.loadError = "No snapshot frames in `gates/`. The recorder skipped frame capture for this bundle (encoder graceful-degrade); add an image trigger by re-recording with snapshots enabled."
            return
        }
        let targetMs = Int((originalT * 1000.0).rounded())
        let nearest = snaps.min(by: { abs($0.1 - targetMs) < abs($1.1 - targetMs) })!

        // Load it.
        if let img = NSImage(contentsOf: nearest.0) {
            self.nsImage = img
        } else {
            self.loadError = "Could not load snapshot at \(nearest.0.lastPathComponent)."
        }
    }

    // MARK: - Confirm

    private func confirm() {
        guard let nsImage,
              let crop = cropRectImage,
              canConfirm else { return }

        let gatesDir = bundleURL.appendingPathComponent("gates", isDirectory: true)
        try? FileManager.default.createDirectory(at: gatesDir, withIntermediateDirectories: true)

        // Slug = first 8 hex chars of a UUID. Short enough to grep,
        // unique enough to not collide in practice.
        let slug = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let prefix = kind.gateKind.rawValue
        let filename = "\(prefix)-\(slug).png"
        let destURL = gatesDir.appendingPathComponent(filename)

        // Crop the image and write PNG.
        if let cropped = croppedImage(from: nsImage, rect: crop),
           let pngData = pngData(from: cropped) {
            do {
                try pngData.write(to: destURL, options: .atomic)
            } catch {
                self.loadError = "Failed to save crop: \(error.localizedDescription)"
                return
            }
        } else {
            self.loadError = "Failed to crop image."
            return
        }

        // The gate-event `ref` is the bare slug; the engine resolves
        // the file via `gates/<gateKind>-<ref>.png` per
        // macro-format-rules.md.
        let result = CropperResult(
            gateKind: kind.gateKind,
            ref: slug,
            originalT: originalT,
            onFail: kind.defaultOnFail
        )
        onConfirm(result)
    }
}

// MARK: - Image helpers

/// Crop an NSImage to a CGRect (image-pixel space). Returns a fresh
/// NSImage at the cropped dimensions.
private func croppedImage(from image: NSImage, rect: CGRect) -> NSImage? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    // Image-pixel coordinate system in NSImage uses top-left origin.
    // CGImage uses bottom-left. NSImage `cgImage(...)` already gives
    // us a top-left CGImage, so we crop directly.
    let safeRect = rect.intersection(CGRect(origin: .zero, size: image.size))
    guard safeRect.width > 0 && safeRect.height > 0,
          let cropped = cgImage.cropping(to: safeRect) else { return nil }
    return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
}

private func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Geometry helpers

private func aspectFitRect(image: CGSize, in container: CGSize) -> CGRect {
    let scale = min(container.width / image.width, container.height / image.height)
    let w = image.width * scale
    let h = image.height * scale
    let x = (container.width - w) / 2
    let y = (container.height - h) / 2
    return CGRect(x: x, y: y, width: w, height: h)
}

private func clampPoint(_ p: CGPoint, to rect: CGRect) -> CGPoint {
    CGPoint(
        x: min(max(p.x, rect.minX), rect.maxX),
        y: min(max(p.y, rect.minY), rect.maxY)
    )
}
