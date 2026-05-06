// ContentView.swift
// macRo — placeholder content view for the v1 shell.
//
// Renders the brand glyph (cyan/magenta gradient swoosh, abstract) and the
// "macRo" wordmark over a deep-navy field. All colors and fonts route through
// MacRoTheme — no hardcoded styling. Full surface (Library, Editor) lands
// in later checklist items.
//
// 7b additions: the recording entry point — a primary CTA below the
// tagline that orchestrates the GamePickSheet → CountdownOverlay →
// RecorderHUD chain. Recording lifecycle outcomes (saved bundle URL,
// recorder error) bubble back here for the reveal-in-Finder alert.

import AppKit
import SwiftUI

struct ContentView: View {

    /// Whether the GamePickSheet is presented.
    @State private var showingGamePick: Bool = false

    /// Most recent finalized bundle URL — drives the "Recording saved"
    /// alert. Wrapped in an Identifiable so SwiftUI's `.alert(item:)`
    /// presentation triggers reliably across rapid stop → re-record
    /// cycles.
    @State private var savedBundle: SavedBundle?

    /// Most recent recorder failure — drives the "Recording failed"
    /// alert.
    @State private var recorderFailure: RecorderFailureBox?

    var body: some View {
        ZStack {
            MacRoTheme.Color.bgPage
                .ignoresSafeArea()

            VStack(spacing: 24) {
                BrandGlyph()
                    .frame(width: 96, height: 96)

                Text("macRo")
                    .font(MacRoTheme.Font.display)
                    .foregroundStyle(MacRoTheme.Color.fg1)

                Text("Imagine Something Else.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .tracking(0.3)

                StartRecordingButton {
                    showingGamePick = true
                }
                .padding(.top, 8)
            }
            .padding(48)
        }
        .sheet(isPresented: $showingGamePick) {
            GamePickSheet(
                onConfirm: { selection in
                    presentCountdown(for: selection)
                },
                onCancel: {
                    // No-op — sheet dismissal handles UI state; we just
                    // return to ContentView's idle state.
                }
            )
        }
        .alert(item: $savedBundle) { bundle in
            Alert(
                title: Text("Recording saved"),
                message: Text(savedAlertMessage(for: bundle.url)),
                primaryButton: .default(Text("Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([bundle.url])
                },
                secondaryButton: .cancel(Text("OK"))
            )
        }
        .alert(item: $recorderFailure) { box in
            Alert(
                title: Text("Recording failed"),
                message: Text(box.error.errorDescription ?? "Unknown recorder error."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Orchestration

    /// Game-pick → countdown → recorder.start → RecorderHUD. The chain
    /// lives in ContentView because each step's host (sheet, panel,
    /// panel) is owned by a different surface and only ContentView
    /// has the lifetime to bridge them all.
    private func presentCountdown(for game: GameSelection) {
        CountdownOverlayPanel.show(
            game: game,
            onComplete: {
                // Countdown finished — bring Roblox to the front BEFORE
                // calling startRecording. Without this, Roblox could be
                // occluded or background; SCK would still find the window
                // but the user's expectation is "I clicked Start, Roblox
                // is now in front, I'm recording." Surfacing Roblox here
                // closes the focus-handoff gap.
                Task { @MainActor in
                    activateRoblox()
                    do {
                        try await Recorder.shared.startRecording(game: game)
                        // Show the HUD only after startRecording resolves
                        // — if pre-flight fails (Roblox not frontmost,
                        // permission revoked since wizard, etc.) the
                        // catch surfaces the error and we never show the
                        // HUD.
                        RecorderHUDPanel.show(
                            onFinished: { url in
                                savedBundle = SavedBundle(url: url)
                            },
                            onFailed: { err in
                                recorderFailure = RecorderFailureBox(error: err)
                            }
                        )
                    } catch let err as RecorderError {
                        recorderFailure = RecorderFailureBox(error: err)
                    } catch {
                        recorderFailure = RecorderFailureBox(
                            error: .captureStartFailed(message: error.localizedDescription)
                        )
                    }
                }
            },
            onCancel: {
                // User hit Escape during countdown — return to idle.
            }
        )
    }

    private func savedAlertMessage(for url: URL) -> String {
        // EditorView lands at item 8 — surface that explicitly so the
        // user knows the bundle is on disk and inspectable but not yet
        // opened in an editor.
        return "Saved to \(url.lastPathComponent). Open in Finder to inspect — the in-app editor lands at item 8."
    }
}

/// Bring the Roblox client to the front via NSRunningApplication. Tries
/// the canonical Mac bundle ID first, falls back to localized name match.
/// No-op if Roblox isn't running — startRecording's preflight will throw
/// windowNotFound and the caller surfaces the error.
@MainActor
private func activateRoblox() {
    let candidates = [
        "com.Roblox.RobloxPlayer",
        "com.Roblox.client",
        "com.roblox.RobloxPlayer"
    ]
    for bundleID in candidates {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if let app = apps.first {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
    }
    // Bundle ID lookup miss — try by localized name.
    if let app = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").localizedCaseInsensitiveContains("Roblox")
    }) {
        app.activate(options: [.activateIgnoringOtherApps])
    }
}

// MARK: - Identifiable boxes for `.alert(item:)`

private struct SavedBundle: Identifiable {
    let id = UUID()
    let url: URL
}

private struct RecorderFailureBox: Identifiable {
    let id = UUID()
    let error: RecorderError
}

// MARK: - Start Recording button

/// Primary CTA below the tagline. Mirrors OnboardingView's PrimaryButton
/// style: teal fill, bgPage text, 10pt continuous radius, contentShape
/// rect for hit-test. Inlined here because OnboardingView's button is
/// fileprivate; sharing one button helper would be a future cleanup
/// (move to MacRoTheme or a Buttons.swift file when a third caller
/// appears).
private struct StartRecordingButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Start Recording")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.bgPage)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MacRoTheme.Color.productTeal.opacity(hovering ? 0.92 : 1.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Brand glyph

/// Placeholder brand glyph — abstract cyan→magenta gradient swoosh.
/// Real lockup lands during the first 626labs-design-skill authoring beat.
private struct BrandGlyph: View {
    var body: some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: [MacRoTheme.Color.brandCyan, MacRoTheme.Color.brandMagenta],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 4
            )
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                MacRoTheme.Color.brandCyan.opacity(0.18),
                                MacRoTheme.Color.brandMagenta.opacity(0.10),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
            )
    }
}

#Preview {
    ContentView()
}
