// EditorView.swift
// UI — the iMovie-flavored timeline editor.
//
// Item 8a: editor SHELL + lane infrastructure + read-only rendering of
// VIDEO / MOVE / ACTIONS lanes.
// Item 8b: GATES lane + image-trigger cropper + inspector panel + edit
// operations (cut / refine / delete) + undo/redo.
//
// 8a's read-only `bundle` state is upgraded to a full `WorkingState`
// (bundle + cuts + selection); every edit produces an `EditorCommand`
// pushed to an undo stack. ⌘Z / ⌘⇧Z drive the stack. The cropper sheet
// is presented from the toolbar's `+ Image trigger` and `+ Position
// trigger` buttons; on confirm the sheet hands back a `CropperResult`
// and we wrap it in `EditorCommands.insertGate`. The PNG was already
// written to disk by the cropper — disk persistence of the timeline
// itself stays at 8c's save flow.
//
// Layout (locked v2 mockup, item 8b adds inspector panel on right):
//
//   ┌────────────────────────────────────────────────────────┐
//   │ macRo · "<macro name>"     · ▸ Run · + Image trigger… │  Toolbar
//   ├────────────────────────────────────────────────────────┤
//   │            [ video preview area ]                      │  Top
//   ├────────────────────────────────────────────────────────┤
//   │  ◀◀  ▶  ▶▶                            0:42 / 2:17     │  Transport
//   ├──────────────────────────────────────────┬─────────────┤
//   │ VIDEO  ▓▓▓▓░░░▓▓▓▓▓▓▓▓░░░▓▓▓▓▓▓▓▓▓▓     │             │
//   │ MOVE      [W·3.5s]   [A·.4][cam]         │  INSPECTOR  │
//   │ ACTIONS   ·    ·   ·    [1]    ·    [E]  │   (right)   │
//   │ GATES               ◇        ◆           │             │
//   └──────────────────────────────────────────┴─────────────┘
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + docs/spec.md > EditorView + docs/prd.md > Epic C.
//
// Voice: builder-to-builder, sentence case, em-dashes welcome, no emoji.
// All colors / fonts / spacing route through MacRoTheme.

import AppKit
import AVKit
import SwiftUI

// MARK: - EditorView

/// The editor's top-level view.
struct EditorView: View {

    let bundleURL: URL
    var onDismiss: () -> Void = {}

    // MARK: Loaded bundle / working state

    @State private var workingState: WorkingState? = nil
    @State private var loadError: String? = nil

    // MARK: Undo / redo

    /// Stacks of commands. `undoStack` holds applied commands; the top
    /// is the most recent. `redoStack` fills as ⌘Z pops from undo.
    /// Both clear when a fresh command lands (standard editor pattern —
    /// any new edit invalidates pending redos).
    @State private var undoStack: [EditorCommand] = []
    @State private var redoStack: [EditorCommand] = []

    // MARK: Cropper sheet

    /// What the cropper should produce when it confirms. Nil = sheet
    /// closed. Driving via an enum (rather than two booleans) keeps the
    /// sheet single-presented even if both buttons race.
    @State private var cropperRequest: CropperRequest? = nil

    // MARK: 8c — toolbar panels + script view + save toast

    /// Which toolbar panel sheet (if any) is active.
    @State private var activePanel: ToolbarPanel? = nil

    /// True when the script view is up (replaces the lane stack).
    @State private var showScriptView: Bool = false

    /// Last save status (drives an inline toast in the toolbar).
    @State private var saveToast: SaveToast? = nil

    // MARK: Transport state

    @State private var playheadSeconds: Double = 0
    @State private var isPlaying: Bool = false

    // MARK: Body

    var body: some View {
        ZStack {
            MacRoTheme.Color.bgPage.ignoresSafeArea()

            if let workingState {
                loadedBody(workingState: workingState)
            } else if let loadError {
                errorBody(message: loadError)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(MacRoTheme.Color.brandCyan)
            }
        }
        .task {
            await loadBundle()
        }
        // Cropper sheet — driven by `cropperRequest`.
        .sheet(item: $cropperRequest) { req in
            EditorCropper(
                bundleURL: bundleURL,
                kind: req.kind,
                originalT: req.originalT,
                onCancel: {
                    cropperRequest = nil
                },
                onConfirm: { result in
                    handleCropperConfirm(result, request: req)
                    cropperRequest = nil
                }
            )
        }
        // Toolbar panels (subs / stopOn / schedule). Driven by
        // `activePanel`; only one of the three is up at a time.
        .sheet(item: $activePanel) { panel in
            if let workingState {
                switch panel {
                case .subs:
                    SubsPanel(
                        state: workingState,
                        dispatch: dispatch,
                        onClose: { activePanel = nil }
                    )
                case .stopOn:
                    StopOnPanel(
                        state: workingState,
                        dispatch: dispatch,
                        onClose: { activePanel = nil }
                    )
                case .schedule:
                    SchedulePanel(
                        state: workingState,
                        dispatch: dispatch,
                        onClose: { activePanel = nil }
                    )
                }
            }
        }
        // Undo / redo + Save keyboard shortcuts. SwiftUI's command modifier
        // on a hidden `Color.clear` view keeps the shortcuts active across
        // every focused subview without depending on Scene-level
        // commands (the editor lives in an NSWindow + NSHostingController,
        // so SwiftUI's @Environment(\.undoManager) is fragile here).
        .background(
            ZStack {
                Button("") { performUndo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .opacity(0)
                Button("") { performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .opacity(0)
                Button("") { performSave() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .opacity(0)
            }
        )
    }

    // MARK: - Loaded layout

    @ViewBuilder
    private func loadedBody(workingState: WorkingState) -> some View {
        let duration = workingState.compressedDuration

        VStack(spacing: 0) {
            EditorToolbar(
                macroName: workingState.bundle.manifest.name,
                canUndo: !undoStack.isEmpty,
                canRedo: !redoStack.isEmpty,
                scriptViewActive: showScriptView,
                saveToast: saveToast,
                onUndo: performUndo,
                onRedo: performRedo,
                onSave: performSave,
                onAddImageTrigger: { presentCropper(kind: .image) },
                onAddPositionTrigger: { presentCropper(kind: .position) },
                onSubs: { activePanel = .subs },
                onStopOn: { activePanel = .stopOn },
                onSchedule: { activePanel = .schedule },
                onToggleScriptView: { showScriptView.toggle() },
                onClose: onDismiss
            )
            Divider().background(MacRoTheme.Color.laneBorder)

            if showScriptView {
                EditorScriptView(
                    state: workingState,
                    dispatch: dispatch,
                    onCloseRequested: { showScriptView = false }
                )
            } else {
                HStack(alignment: .top, spacing: 0) {
                    // Center column: preview + transport + lanes.
                    VStack(spacing: 0) {
                        VideoPreviewPanel(bundleURL: bundleURL)
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .padding(.horizontal, MacRoTheme.Spacing.lg)
                            .padding(.top, MacRoTheme.Spacing.md)

                        EditorTransport(
                            playheadSeconds: $playheadSeconds,
                            isPlaying: $isPlaying,
                            duration: duration
                        )
                        .padding(.horizontal, MacRoTheme.Spacing.lg)
                        .padding(.vertical, MacRoTheme.Spacing.md)

                        Divider().background(MacRoTheme.Color.laneBorder)

                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: MacRoTheme.Lane.rowGap) {
                                laneRow(label: "VIDEO") {
                                    EditableVideoLane(
                                        state: workingState,
                                        playheadSeconds: playheadSeconds,
                                        onAddCut: { range in
                                            dispatch(EditorCommands.addCut(range))
                                        },
                                        onRemoveCut: { range in
                                            dispatch(EditorCommands.removeCut(range))
                                        },
                                        onResizeCut: { id, s, e in
                                            dispatch(EditorCommands.resizeCut(
                                                cutId: id,
                                                newStart: s,
                                                newEnd: e,
                                                from: workingState
                                            ))
                                        }
                                    )
                                }
                                laneRow(label: "MOVE") {
                                    MoveLane(
                                        events: visibleTimelineEvents(workingState: workingState),
                                        duration: duration,
                                        playheadSeconds: playheadSeconds
                                    )
                                }
                                laneRow(label: "ACTIONS") {
                                    ActionsLane(
                                        events: visibleTimelineEvents(workingState: workingState),
                                        duration: duration,
                                        playheadSeconds: playheadSeconds
                                    )
                                }
                                laneRow(label: "GATES") {
                                    GatesLane(
                                        events: workingState.visibleEvents,
                                        duration: duration,
                                        playheadSeconds: playheadSeconds,
                                        selection: workingState.selection,
                                        onSelectGate: { idx in
                                            select(originalIndex: idx)
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, MacRoTheme.Spacing.lg)
                            .padding(.vertical, MacRoTheme.Spacing.md)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)

                    // Inspector panel — right side.
                    Divider().background(MacRoTheme.Color.laneBorder)
                    EditorInspector(
                        state: workingState,
                        bundleURL: bundleURL,
                        dispatch: dispatch,
                        openImageAnchorCropper: { clickIndex in
                            // Click → image-anchor: read the click's t,
                            // convert to original (it already IS in original
                            // coords since we read from the bundle), and
                            // present an IMG cropper. On confirm we drop a
                            // gate at that t — engine-side click→gate-anchor
                            // resolution lands at /iterate per the inspector
                            // doc-comment.
                            guard clickIndex < workingState.bundle.timeline.events.count else { return }
                            let t = eventTime(workingState.bundle.timeline.events[clickIndex])
                            cropperRequest = CropperRequest(
                                kind: .image,
                                originalT: t,
                                origin: .clickAnchor(clickIndex: clickIndex)
                            )
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func laneRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: MacRoTheme.Spacing.sm) {
            Text(label)
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
                .frame(width: MacRoTheme.Lane.labelGutter, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Error layout

    @ViewBuilder
    private func errorBody(message: String) -> some View {
        VStack(spacing: MacRoTheme.Spacing.md) {
            Text("Could not open this macro")
                .font(MacRoTheme.Font.heading1)
                .foregroundStyle(MacRoTheme.Color.fg1)
            Text(message)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(action: onDismiss) {
                Text("Close")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.bgPage)
                    .padding(.horizontal, MacRoTheme.Spacing.md)
                    .padding(.vertical, MacRoTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                            .fill(MacRoTheme.Color.productTeal)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(MacRoTheme.Spacing.xl)
    }

    // MARK: - Loading

    private func loadBundle() async {
        do {
            let url = bundleURL
            let loaded = try await Task.detached(priority: .userInitiated) {
                try MacroBundle.load(at: url)
            }.value
            await MainActor.run {
                self.workingState = WorkingState(bundle: loaded)
            }
        } catch let error as MacroBundle.MacroBundleError {
            await MainActor.run {
                self.loadError = error.errorDescription ?? "Unknown bundle error."
            }
        } catch {
            await MainActor.run {
                self.loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Visible-event compatibility shim

    /// MOVE / ACTIONS lanes still take a `[TimelineEvent]` (8a contract).
    /// Translate the working state's compressed visible-event list back
    /// to bare TimelineEvents for those lanes, with `t` rewritten to
    /// compressed coordinates so positioning matches GATES + VIDEO. This
    /// is a thin adapter — when 8c lands script-view round-trip the
    /// lanes can take VisibleEvent directly and we'll drop this shim.
    private func visibleTimelineEvents(workingState: WorkingState) -> [TimelineEvent] {
        workingState.visibleEvents.compactMap { ve -> TimelineEvent? in
            // Rewrite `t` to compressed coordinates so the lanes
            // position correctly against `compressedDuration`.
            withShifted(t: ve.compressedT, event: ve.event)
        }
    }

    // MARK: - Command dispatch

    private func dispatch(_ command: EditorCommand) {
        guard var state = workingState else { return }
        let next = command.apply(state)
        if next == state { return } // no-op (e.g., zero-length cut)
        state = next
        workingState = state
        undoStack.append(command)
        redoStack.removeAll()
    }

    private func performUndo() {
        guard let cmd = undoStack.popLast(),
              var state = workingState else { return }
        state = cmd.undo(state)
        workingState = state
        redoStack.append(cmd)
    }

    private func performRedo() {
        guard let cmd = redoStack.popLast(),
              var state = workingState else { return }
        state = cmd.apply(state)
        workingState = state
        undoStack.append(cmd)
    }

    // MARK: - Selection

    private func select(originalIndex: Int) {
        guard var state = workingState else { return }
        state.selection = EventSelection(originalEventIndex: originalIndex)
        workingState = state
    }

    // MARK: - Cropper

    private func presentCropper(kind: CropperKind) {
        guard let workingState else { return }
        // Convert the compressed playhead to original-timeline
        // coordinates so the gate event's `t` matches the user's
        // intent on the underlying schema.
        let origT = workingState.originalTime(fromCompressed: playheadSeconds)
        cropperRequest = CropperRequest(
            kind: kind,
            originalT: origT,
            origin: .toolbar
        )
    }

    private func handleCropperConfirm(
        _ result: CropperResult,
        request: CropperRequest
    ) {
        // Insert the gate event. PNG already on disk.
        let cmd = EditorCommands.insertGate(
            at: result.originalT,
            ref: result.ref,
            gateKind: result.gateKind,
            retries: 3,
            timeout: 30,
            onFail: result.onFail
        )
        dispatch(cmd)

        // If this came from the click→image-anchor flow, log the
        // intent so /iterate has a paper trail. Engine-side resolution
        // (replace click coords with image-anchor lookup) lands there.
        if case .clickAnchor(let clickIndex) = request.origin {
            print("[editor] click→image-anchor: click@\(clickIndex) anchored to gate \(result.gateKind.rawValue)-\(result.ref) — engine-side wiring at /iterate")
        }
    }

    // MARK: - Save

    @MainActor
    private func performSave() {
        guard let workingState else { return }
        let result = EditorSaveFlow.save(
            state: workingState,
            currentBundleURL: bundleURL,
            destination: nil,
            confirmReplace: {
                EditorSaveFlow.defaultReplacePrompt(
                    existingId: "",
                    newId: workingState.bundle.manifest.id
                )
            }
        )
        switch result {
        case .saved(let url):
            // Saved cleanly: undo/redo stacks reset since on-disk
            // bundle now matches the in-memory state. Surface a toast
            // so the user sees the save landed.
            undoStack.removeAll()
            redoStack.removeAll()
            saveToast = SaveToast(message: "Saved to \(url.lastPathComponent)", isError: false)
            dismissToastAfterDelay()
            print("[editor] saved bundle to \(url.path)")
        case .cancelled:
            saveToast = SaveToast(message: "Save cancelled.", isError: false)
            dismissToastAfterDelay()
        case .failed(let msg):
            saveToast = SaveToast(message: "Save failed: \(msg)", isError: true)
            dismissToastAfterDelay(seconds: 6)
        }
    }

    private func dismissToastAfterDelay(seconds: Double = 3) {
        let captured = saveToast?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if saveToast?.id == captured {
                saveToast = nil
            }
        }
    }
}

// MARK: - Toolbar panel

/// Identifies which toolbar-panel sheet is currently up. Single
/// presented at a time per `.sheet(item:)` semantics.
enum ToolbarPanel: String, Identifiable {
    case subs
    case stopOn
    case schedule

    var id: String { rawValue }
}

// MARK: - Save toast

/// Lightweight save-status pill rendered in the toolbar after a save
/// attempt. Self-dismissing after a few seconds.
struct SaveToast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

// MARK: - CropperRequest

/// Identifiable wrapper so SwiftUI's `.sheet(item:)` triggers cleanly.
struct CropperRequest: Identifiable {
    enum Origin {
        case toolbar
        case clickAnchor(clickIndex: Int)
    }

    let id = UUID()
    let kind: CropperKind
    let originalT: Double
    let origin: Origin
}

// MARK: - Toolbar

private struct EditorToolbar: View {
    let macroName: String
    let canUndo: Bool
    let canRedo: Bool
    let scriptViewActive: Bool
    let saveToast: SaveToast?
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSave: () -> Void
    let onAddImageTrigger: () -> Void
    let onAddPositionTrigger: () -> Void
    let onSubs: () -> Void
    let onStopOn: () -> Void
    let onSchedule: () -> Void
    let onToggleScriptView: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: MacRoTheme.Spacing.md) {
            Text("macRo")
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.fg2)
                .tracking(0.3)
            Text("·")
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("\"\(macroName)\"")
                .font(MacRoTheme.Font.body)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: MacRoTheme.Spacing.lg)

            if let toast = saveToast {
                Text(toast.message)
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(toast.isError ? MacRoTheme.Color.stateDanger : MacRoTheme.Color.stateOk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, MacRoTheme.Spacing.sm)
                    .padding(.vertical, MacRoTheme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                            .fill(MacRoTheme.Color.bgRaised)
                    )
            }

            ToolbarPill(label: "▸ Run") { print("[editor] Run — wired at 8b") }
            ToolbarPill(label: "⤓ Save", action: onSave)
            ToolbarPill(label: "+ Image trigger", action: onAddImageTrigger)
            ToolbarPill(label: "+ Position trigger", action: onAddPositionTrigger)
            ToolbarPill(label: "subs:", action: onSubs)
            ToolbarPill(label: "stopOn:", action: onStopOn)
            ToolbarPill(label: "schedule:", action: onSchedule)
            ToolbarPill(label: scriptViewActive ? "≡ lanes" : "{ } script", action: onToggleScriptView)

            // Undo / redo affordances. Keyboard shortcuts (⌘Z / ⌘⇧Z) are
            // wired via the hidden background; these visible buttons mirror
            // the state for click-friendly users.
            ToolbarPill(label: "↶ Undo", enabled: canUndo, action: onUndo)
            ToolbarPill(label: "↷ Redo", enabled: canRedo, action: onRedo)

            Button(action: onClose) {
                Text("Close")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .padding(.horizontal, MacRoTheme.Spacing.md)
                    .padding(.vertical, MacRoTheme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                            .strokeBorder(MacRoTheme.Color.fg3.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MacRoTheme.Spacing.lg)
        .padding(.vertical, MacRoTheme.Spacing.sm)
        .background(MacRoTheme.Color.bgSurface)
    }
}

private struct ToolbarPill: View {
    let label: String
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(MacRoTheme.Font.monoMicro)
                .foregroundStyle(enabled ? MacRoTheme.Color.fg2 : MacRoTheme.Color.fg3.opacity(0.4))
                .tracking(0.12 * 11)
                .padding(.horizontal, MacRoTheme.Spacing.sm)
                .padding(.vertical, MacRoTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .fill(MacRoTheme.Color.bgRaised.opacity(hovering && enabled ? 1.0 : 0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .strokeBorder(MacRoTheme.Color.laneBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

// MARK: - Video preview panel

private struct VideoPreviewPanel: View {
    let bundleURL: URL

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                .fill(MacRoTheme.Color.bgSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md)
                        .strokeBorder(MacRoTheme.Color.laneBorder, lineWidth: 1)
                )

            if let videoURL = resolveVideoURL() {
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .clipShape(
                        RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                    )
            } else {
                VStack(spacing: MacRoTheme.Spacing.sm) {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    MacRoTheme.Color.brandCyan,
                                    MacRoTheme.Color.brandMagenta
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 56, height: 56)

                    Text("no video preview — recorded inputs only")
                        .font(MacRoTheme.Font.monoMicro)
                        .tracking(0.12 * 11)
                        .foregroundStyle(MacRoTheme.Color.fg3)

                    Text("the encoder gracefully degraded for this recording; the input timeline below is the source of truth")
                        .font(MacRoTheme.Font.bodySmall)
                        .foregroundStyle(MacRoTheme.Color.fg3.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
        }
    }

    private func resolveVideoURL() -> URL? {
        let candidates = ["raw-video.mov", "preview.mp4"]
        for name in candidates {
            let candidate = bundleURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Event time helper

func eventTime(_ event: TimelineEvent) -> Double {
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

/// Build a fresh TimelineEvent that's a copy of `event` with `t` swapped.
/// Public-on-file because EditorView's visibleTimelineEvents shim needs
/// to translate event timestamps to compressed space, and the inspector
/// uses the same helper for timing-offset commits. Lifted to file scope
/// so both call sites share one implementation.
func withShifted(t newT: Double, event: TimelineEvent) -> TimelineEvent? {
    switch event {
    case .keyDown(let p):
        return .keyDown(.init(t: newT, key: p.key))
    case .keyUp(let p):
        return .keyUp(.init(t: newT, key: p.key))
    case .keyPress(let p):
        return .keyPress(.init(t: newT, key: p.key))
    case .click(let p):
        return .click(.init(t: newT, x: p.x, y: p.y, button: p.button, jitterMs: p.jitterMs))
    case .cameraDelta(let p):
        return .cameraDelta(.init(t: newT, dx: p.dx, dy: p.dy, duration: p.duration))
    case .gate(let p):
        return .gate(.init(t: newT, gateKind: p.gateKind, ref: p.ref, retries: p.retries, timeout: p.timeout, onFail: p.onFail))
    case .loop(let p):
        return .loop(.init(t: newT, label: p.label, target: p.target, delayMs: p.delayMs))
    case .invokeSub(let p):
        return .invokeSub(.init(t: newT, name: p.name))
    }
}

// MARK: - Editor window host

@MainActor
public enum EditorWindow {

    private static var window: NSWindow?
    private static var hosting: NSHostingController<EditorView>?

    public static func show(bundleURL: URL) {
        let view = EditorView(
            bundleURL: bundleURL,
            onDismiss: { dismiss() }
        )

        if let hosting {
            hosting.rootView = view
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: view)
        host.view.translatesAutoresizingMaskIntoConstraints = false

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.title = "macRo Editor"
        win.contentViewController = host
        win.center()
        win.minSize = NSSize(width: 920, height: 600)
        win.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { _ in
            EditorWindow.hosting = nil
            EditorWindow.window = nil
        }

        window = win
        hosting = host
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func dismiss() {
        window?.performClose(nil)
    }
}
