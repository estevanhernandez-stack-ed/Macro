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
//
// 7.5 additions: replace the single "Recording saved" alert with a
// PostRecordSheet — three explicit paths so casual users don't have to
// open the editor for trivial macros: Save (one-shot, current behavior),
// Save as loop (append a `loop` event with delayMs, modify in place),
// Open in Editor (placeholder until item 8). Loop-save mutates the
// already-finalized bundle on disk: load timeline.yaml, append
// `loop {target: 0.0, delayMs: <input * 1000>}`, save back to the same
// URL. Gate PNGs and manifest are untouched.

import AppKit
import SwiftUI

struct ContentView: View {

    /// Whether the GamePickSheet is presented.
    @State private var showingGamePick: Bool = false

    /// Most recent finalized bundle URL — drives the post-record sheet
    /// (Save / Save as loop / Open in Editor). Identifiable so SwiftUI's
    /// `.sheet(item:)` presentation triggers reliably across rapid stop →
    /// re-record cycles.
    @State private var savedBundle: SavedBundle?

    /// Most recent recorder failure — drives the "Recording failed"
    /// alert.
    @State private var recorderFailure: RecorderFailureBox?

    /// Reveal-in-Finder confirmation surfaced after Save / Save as loop
    /// resolves. Distinct from `savedBundle` so the post-record sheet
    /// can dismiss cleanly before the confirmation appears.
    @State private var revealConfirmation: RevealConfirmation?

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
        .sheet(item: $savedBundle) { bundle in
            PostRecordSheet(
                bundleURL: bundle.url,
                onResolve: { outcome in
                    savedBundle = nil
                    handlePostRecord(outcome: outcome, bundleURL: bundle.url)
                }
            )
        }
        .alert(item: $recorderFailure) { box in
            Alert(
                title: Text("Recording failed"),
                message: Text(box.error.errorDescription ?? "Unknown recorder error."),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $revealConfirmation) { conf in
            Alert(
                title: Text(conf.title),
                message: Text(conf.message),
                primaryButton: .default(Text("Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([conf.url])
                },
                secondaryButton: .cancel(Text("OK"))
            )
        }
    }

    // MARK: - Post-record outcome

    private func handlePostRecord(outcome: PostRecordOutcome, bundleURL: URL) {
        switch outcome {
        case .save:
            // One-shot save — current v1 behavior. The bundle is already
            // on disk; just confirm and offer reveal-in-Finder.
            revealConfirmation = RevealConfirmation(
                url: bundleURL,
                title: "Recording saved",
                message: savedAlertMessage(for: bundleURL)
            )

        case .saveAsLoop(let seconds):
            // Append a loop event to timeline.yaml. Modify-in-place — the
            // recorder already finalized to the permanent location and
            // copying the bundle would orphan its gates/ directory.
            do {
                try appendLoopEvent(toBundleAt: bundleURL, delaySeconds: seconds)
                revealConfirmation = RevealConfirmation(
                    url: bundleURL,
                    title: "Saved as loop",
                    message: loopSavedMessage(for: bundleURL, seconds: seconds)
                )
            } catch {
                recorderFailure = RecorderFailureBox(
                    error: .captureStartFailed(
                        message: "Could not append loop event: \(error.localizedDescription)"
                    )
                )
            }

        case .openInEditor:
            // Placeholder until item 8 lands the full editor. For now,
            // reveal in Finder so the user can inspect the bundle.
            revealConfirmation = RevealConfirmation(
                url: bundleURL,
                title: "Editor lands at item 8",
                message: editorPlaceholderMessage(for: bundleURL)
            )
        }
    }

    /// Load the timeline at `bundleURL`, append a `loop` event whose
    /// `target` is the first event's `t` (or 0.0 if the timeline is empty)
    /// and whose `delayMs` is the user's wait, and write it back.
    /// Manifest is read-then-written-unchanged so save's atomic-pair
    /// contract is preserved. Gates dir is untouched.
    private func appendLoopEvent(toBundleAt bundleURL: URL, delaySeconds: Double) throws {
        let loaded = try MacroBundle.load(at: bundleURL)

        // Where to jump: the t of the first event, defaulting to 0 when
        // the timeline is empty (degenerate but legal — the loop becomes
        // a "wait, then no-op" until runaway-guard aborts; documented).
        let firstEventTime = loaded.timeline.events.first.map { eventT($0) } ?? 0.0

        // Position the loop event AFTER the last event so the engine
        // hits it once it has played everything. delayMs honors the
        // user's chosen pause; rounded to the nearest millisecond.
        let lastEventTime = loaded.timeline.events.last.map { eventT($0) } ?? 0.0
        let loopT = lastEventTime + 0.001 // strictly after the last event
        let delayMs = Int((delaySeconds * 1000.0).rounded())

        let loopPayload = TimelineEvent.TimelineEventLoopPayload(
            t: loopT,
            label: "quick-loop",
            target: firstEventTime,
            delayMs: delayMs
        )
        let loopEvent: TimelineEvent = .loop(loopPayload)

        var newEvents = loaded.timeline.events
        newEvents.append(loopEvent)

        let newTimeline = Timeline(
            events: newEvents,
            stopOn: loaded.timeline.stopOn,
            subs: loaded.timeline.subs
        )
        let newBundle = MacroBundleData(manifest: loaded.manifest, timeline: newTimeline)

        try MacroBundle.save(newBundle, to: bundleURL)
    }

    /// Pull the absolute time `t` off any TimelineEvent variant. The
    /// codegen enum's payloads all carry `t`; this is a small bridge so
    /// ContentView doesn't need a switch over every variant.
    private func eventT(_ event: TimelineEvent) -> Double {
        switch event {
        case .keyDown(let p):     return p.t
        case .keyUp(let p):       return p.t
        case .keyPress(let p):    return p.t
        case .click(let p):       return p.t
        case .cameraDelta(let p): return p.t
        case .gate(let p):        return p.t
        case .loop(let p):        return p.t
        case .invokeSub(let p):   return p.t
        }
    }

    private func loopSavedMessage(for url: URL, seconds: Double) -> String {
        let formatted: String = (seconds == seconds.rounded())
            ? String(format: "%.0f", seconds)
            : String(format: "%.2f", seconds)
        return "Saved \(url.lastPathComponent) with a \(formatted)-second wait between iterations. Run it from the Library — abort with control-option-command-period."
    }

    private func editorPlaceholderMessage(for url: URL) -> String {
        return "The in-app editor lands at item 8. For now you can inspect the bundle in Finder. The Save and Save-as-loop paths above cover the casual flow."
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

/// Reveal-in-Finder confirmation surfaced after the post-record sheet
/// resolves. Title + message + URL so the alert can speak in the same
/// voice for all three outcomes (Save / Save as loop / Open in Editor).
private struct RevealConfirmation: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let message: String
}

/// The user's choice from PostRecordSheet. Values flow back to
/// ContentView.handlePostRecord which routes the side effects.
enum PostRecordOutcome {
    case save
    case saveAsLoop(seconds: Double)
    case openInEditor
}

// MARK: - PostRecordSheet (item 7.5)

/// Three-option sheet shown after the recorder finalizes a draft bundle.
/// Replaces the v1 "Recording saved" alert with explicit paths so a
/// user who recorded a 3-keystroke loop can ship it as a looping macro
/// without ever opening the editor.
///
/// Layout:
///   • Header — title + bundle name + builder-to-builder copy.
///   • Option 1: Save — primary CTA, current v1 one-shot behavior.
///   • Option 2: Save as loop — when active, reveals an inline
///     numeric input ("Wait [N] seconds between iterations"), then a
///     Confirm CTA. Default 1.0 seconds, decimals OK, minimum 0.
///   • Option 3: Open in Editor — placeholder, copy explains item 8.
///   • Cancel — dismisses without saving (sheet owner state is the
///     bundle URL; cancelling here treats it as Save without reveal).
struct PostRecordSheet: View {
    let bundleURL: URL
    let onResolve: (PostRecordOutcome) -> Void

    @State private var loopExpanded: Bool = false
    @State private var loopSecondsText: String = "1.0"

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.lg) {

            // Header
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Recording saved")
                    .font(MacRoTheme.Font.heading1)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(bundleURL.lastPathComponent)
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                Text("Pick how you want to use it. The editor lands at item 8 — for the simplest case, Save as loop is all you need.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .padding(.top, MacRoTheme.Spacing.xs)
            }

            // Option 1 — Save
            PostRecordOptionButton(
                title: "Save",
                subtitle: "One-shot. Plays the timeline once when you run it.",
                isPrimary: true
            ) {
                onResolve(.save)
            }

            // Option 2 — Save as loop (inline reveal)
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
                PostRecordOptionButton(
                    title: "Save as loop",
                    subtitle: "Repeats from start to finish forever, with a wait between iterations.",
                    isPrimary: false
                ) {
                    loopExpanded.toggle()
                }

                if loopExpanded {
                    LoopDelayInput(
                        secondsText: $loopSecondsText,
                        onConfirm: {
                            let value = parsedSeconds()
                            onResolve(.saveAsLoop(seconds: value))
                        }
                    )
                    .padding(.leading, MacRoTheme.Spacing.lg)
                }
            }

            // Option 3 — Open in Editor (placeholder)
            PostRecordOptionButton(
                title: "Open in Editor",
                subtitle: "The full editor lands at item 8. For now this reveals the bundle in Finder so you can inspect it.",
                isPrimary: false
            ) {
                onResolve(.openInEditor)
            }

            Spacer(minLength: 0)
        }
        .padding(MacRoTheme.Spacing.xl)
        .frame(width: 460)
        .background(MacRoTheme.Color.bgSurface)
    }

    /// Parse the user's input. Empty / unparseable / negative all clamp
    /// to 0 (the engine treats 0 as "no wait" — same as omitted).
    private func parsedSeconds() -> Double {
        let trimmed = loopSecondsText.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value >= 0 else { return 0 }
        return value
    }
}

/// Single-option button row used by PostRecordSheet. Primary CTA picks
/// up the productTeal fill (matches StartRecordingButton); secondary
/// rows render as outlined cards over bgRaised so they read as
/// affordances without competing with the primary.
private struct PostRecordOptionButton: View {
    let title: String
    let subtitle: String
    let isPrimary: Bool
    let action: () -> Void

    @State private var hovering: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text(title)
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(isPrimary ? MacRoTheme.Color.bgPage : MacRoTheme.Color.fg1)
                Text(subtitle)
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(isPrimary ? MacRoTheme.Color.bgPage.opacity(0.78) : MacRoTheme.Color.fg2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MacRoTheme.Spacing.md)
            .padding(.vertical, MacRoTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                    .fill(
                        isPrimary
                            ? MacRoTheme.Color.productTeal.opacity(hovering ? 0.92 : 1.0)
                            : MacRoTheme.Color.bgRaised.opacity(hovering ? 0.92 : 1.0)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                    .strokeBorder(
                        isPrimary ? Color.clear : MacRoTheme.Color.fg3.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Inline numeric input shown when "Save as loop" is the active choice.
/// Decimals OK; the parent clamps negatives to 0 at confirm.
private struct LoopDelayInput: View {
    @Binding var secondsText: String
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.sm) {
            HStack(spacing: MacRoTheme.Spacing.sm) {
                Text("Wait")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                TextField("1.0", text: $secondsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .font(MacRoTheme.Font.mono)
                Text("seconds between iterations.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
            }

            Button(action: onConfirm) {
                Text("Confirm and save loop")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.bgPage)
                    .padding(.horizontal, MacRoTheme.Spacing.md)
                    .padding(.vertical, MacRoTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm, style: .continuous)
                            .fill(MacRoTheme.Color.productTeal)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
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
