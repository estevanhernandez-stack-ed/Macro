// RunHUD.swift
// UI — floating playback overlay window.
//
// RunHUD is the user's single-pane control surface during macro playback.
// It mirrors `Engine.shared.state` in real time, renders the active
// macro's name + elapsed time, exposes a stop button, and reminds the
// user that `⌃⌥⌘.` is always-on as a blast-shield. The HUD lives above
// every other window (`.floating` level) so it never gets buried under
// Roblox.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 8
// (Visual treatment — RunHUD uses JetBrains Mono uppercase tracking for
// the timer; teal stop button) + docs/spec.md > RunHUD + docs/prd.md >
// Epic D (abort surfaces).
//
// Threading: the HUD's view model wires `Engine.shared.onStateChange`
// (which fires on MainActor by Engine's contract) to `@Published`
// state. SwiftUI bindings stay on main throughout. The elapsed-time
// timer also runs on main via `Timer.scheduledTimer`.
//
// Voice: builder-to-builder, sentence case, em-dashes welcome, no emoji.
// All colors / fonts / spacing route through MacRoTheme.

import AppKit
import Combine
import SwiftUI

// MARK: - View model

/// Mirrors `Engine.shared` state for SwiftUI. Owns a 1-Hz tick that
/// pushes the elapsed-time string into a `@Published` so the HUD redraws
/// once per second without re-rendering the whole tree on every state
/// transition. Held by `RunHUD.show()` for the lifetime of the panel.
@MainActor
final class RunHUDViewModel: ObservableObject {

    // MARK: Published surface

    @Published var state: EngineState = .idle
    @Published var macroName: String = ""
    @Published var elapsedDisplay: String = "00:00"
    @Published var currentGateRef: String? = nil

    // MARK: Private

    private var tickTimer: Timer?
    private var previousOnStateChange: ((EngineState) -> Void)?

    // MARK: Lifecycle

    init() {
        // Snapshot whatever's already wired so we don't clobber another
        // observer (e.g., a future EditorView's "Run" button hook).
        // We chain through, calling the previous handler after our own.
        previousOnStateChange = Engine.shared.onStateChange
        let chained = previousOnStateChange
        Engine.shared.onStateChange = { [weak self] newState in
            self?.handleStateChange(newState)
            chained?(newState)
        }
        // Pull initial values in case the engine's already running when
        // the HUD is built.
        handleStateChange(Engine.shared.state)
        startTick()
    }

    deinit {
        tickTimer?.invalidate()
        // Best-effort restore of the previous observer. If nobody else
        // has touched it since we wired in, this leaves the engine in
        // its pre-HUD state.
        let prev = previousOnStateChange
        Task { @MainActor in
            Engine.shared.onStateChange = prev
        }
    }

    // MARK: Actions

    /// Stop button → engine abort. Routes through the chokepoint via
    /// `Engine.shared.abort` so the abort hits the same audit trail as
    /// the global hotkey path.
    func stop() {
        Engine.shared.abort(reason: .userStopButton)
    }

    // MARK: Private helpers

    private func handleStateChange(_ newState: EngineState) {
        state = newState
        macroName = Engine.shared.currentManifest?.name ?? ""
        // Stop the tick when there's nothing to count.
        if newState.isTerminal || isPreRun(newState) {
            elapsedDisplay = elapsedString(for: newState)
        }
    }

    private func isPreRun(_ s: EngineState) -> Bool {
        switch s {
        case .idle, .preflight: return true
        default: return false
        }
    }

    private func startTick() {
        // 1 Hz is enough for an MM:SS display; faster wastes wakeups.
        // Timer is on main, which is exactly where SwiftUI wants its
        // @Published mutations.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshElapsed()
            }
        }
    }

    private func refreshElapsed() {
        elapsedDisplay = elapsedString(for: state)
    }

    private func elapsedString(for state: EngineState) -> String {
        // Pre-run: clock at 00:00. Terminal: freeze at last value (we
        // simply don't recompute; whatever was last shown stays).
        guard let started = Engine.shared.runStartedAt else { return "00:00" }
        if isPreRun(state) { return "00:00" }
        if state.isTerminal { return elapsedDisplay }
        let secs = max(0, Int(CFAbsoluteTimeGetCurrent() - started))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}

// MARK: - View

/// The HUD body. Embedded in an NSPanel by `RunHUD.show()`.
struct RunHUD: View {

    @ObservedObject var vm: RunHUDViewModel

    /// Closure the host panel uses to dismiss itself when the user hits
    /// the dismiss button on a terminal state. Set by the panel host.
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
            header
            body(for: vm.state)
            footer
        }
        .padding(MacRoTheme.Spacing.lg)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.lg, style: .continuous)
                .fill(MacRoTheme.Color.hudSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacRoTheme.Radius.lg, style: .continuous)
                .strokeBorder(MacRoTheme.Color.hudBorder.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: Header — state pill + macro name

    private var header: some View {
        HStack(spacing: MacRoTheme.Spacing.sm) {
            StatePill(state: vm.state)
            Spacer(minLength: 0)
            Text(vm.elapsedDisplay)
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg1)
                .tracking(0.12 * 13)
                .textCase(.uppercase)
        }
    }

    // MARK: Body — state-aware content

    @ViewBuilder
    private func body(for state: EngineState) -> some View {
        switch state {
        case .idle, .preflight:
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(vm.macroName.isEmpty ? "" : vm.macroName)
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
            }

        case .running:
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text(vm.macroName.isEmpty ? "Running" : vm.macroName)
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text("Macro is playing — keep the target window frontmost.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .gating:
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Waiting on gate")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(vm.currentGateRef ?? vm.macroName)
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .tracking(0.12 * 13)
                    .textCase(.uppercase)
            }

        case .paused(let reason):
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Paused")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(humanReadable(reason))
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .finished:
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Finished.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(vm.macroName)
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
            }

        case .aborted(let reason):
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Aborted.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(humanReadable(reason))
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .failed(let error):
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Failed.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(error.errorDescription ?? "Unknown engine error.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer — stop / dismiss + abort hint

    private var footer: some View {
        HStack(spacing: MacRoTheme.Spacing.sm) {
            if vm.state.isTerminal {
                StopButton(title: "Dismiss", isTerminal: true) {
                    onDismiss?()
                }
            } else {
                StopButton(title: "Stop", isTerminal: false) {
                    vm.stop()
                }
            }
            Spacer(minLength: 0)
            Text("abort: ⌃⌥⌘.")
                .font(MacRoTheme.Font.monoMicro)
                .foregroundStyle(MacRoTheme.Color.fg3)
                .tracking(0.12 * 11)
                .textCase(.uppercase)
        }
    }

    // MARK: Helpers

    private func humanReadable(_ reason: EnginePauseReason) -> String {
        switch reason {
        case .outsideSchedule(let next):
            if let next {
                return "Outside schedule — resumes \(formatted(next))."
            }
            return "Outside schedule window."
        case .stopOnPause(let message):
            return message ?? "Stopped on a watcher trigger."
        case .windowLost:
            return "Target window lost focus or closed — bring it back."
        case .userPaused:
            return "User pause."
        }
    }

    private func humanReadable(_ reason: EngineAbortReason) -> String {
        switch reason {
        case .userHotkey:
            return "User pressed ⌃⌥⌘."
        case .userStopButton:
            return "User clicked Stop."
        case .stopOnExit:
            return "Stop-on watcher fired."
        case .gateAbort(let ref):
            return "Gate \(ref) failed past its retry budget."
        case .loopRunaway(let label):
            return "Loop \(label) ran past the runaway threshold."
        case .preflightFailed:
            return "Pre-flight refused to proceed."
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - State pill

private struct StatePill: View {
    let state: EngineState

    var body: some View {
        Text(label)
            .font(MacRoTheme.Font.monoMicro)
            .foregroundStyle(foreground)
            .tracking(0.12 * 11)
            .textCase(.uppercase)
            .padding(.horizontal, MacRoTheme.Spacing.sm + 2)
            .padding(.vertical, MacRoTheme.Spacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(foreground.opacity(0.6), lineWidth: 1)
            )
    }

    // Color routing — every variant draws from MacRoTheme.Color.state*.
    // Keeping the switch in one place makes new states a one-line add.
    private var label: String {
        switch state {
        case .idle:       return "Idle"
        case .preflight:  return "Preflight"
        case .paused:     return "Paused"
        case .running:    return "Running"
        case .gating:     return "Gating"
        case .finished:   return "Finished"
        case .aborted:    return "Aborted"
        case .failed:     return "Failed"
        }
    }

    private var foreground: SwiftUI.Color {
        switch state {
        case .idle, .preflight: return MacRoTheme.Color.fg2
        case .running, .gating: return MacRoTheme.Color.stateInfo
        case .paused:           return MacRoTheme.Color.stateWarn
        case .finished:         return MacRoTheme.Color.stateOk
        case .aborted, .failed: return MacRoTheme.Color.stateDanger
        }
    }

    private var background: SwiftUI.Color {
        // Translucent version of the foreground reads cleanly against
        // the deep-navy hudSurface without needing a per-state bg token.
        foreground.opacity(0.16)
    }
}

// MARK: - Stop / dismiss button

private struct StopButton: View {
    let title: String
    let isTerminal: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MacRoTheme.Font.bodySmall)
                .foregroundStyle(MacRoTheme.Color.bgPage)
                .padding(.horizontal, MacRoTheme.Spacing.md + 2)
                .padding(.vertical, MacRoTheme.Spacing.sm - 1)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.md, style: .continuous)
                        .fill(fill)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fill: SwiftUI.Color {
        // Stop is teal CTA per spec § 8 ("teal stop button"). Dismiss on
        // terminal states uses the muted bgRaised so it doesn't compete
        // with the pill's color signal.
        let base = isTerminal ? MacRoTheme.Color.bgRaised : MacRoTheme.Color.productTeal
        return base.opacity(hovering ? 0.92 : 1.0)
    }
}

// MARK: - Panel host

/// Floating-panel host for the HUD. macOS 14's `Window` scene is the
/// simpler path on paper, but Window scenes are tied to the App's
/// Scene tree — they don't take a non-activating, click-through-friendly
/// floating-panel level cleanly. NSPanel + `.floating` level is the
/// right shape for "always-on-top, doesn't steal focus from Roblox."
///
/// `show()` is idempotent — calling it twice surfaces the existing
/// panel rather than spawning a second.
@MainActor
public enum RunHUDPanel {

    /// UserDefaults key for the HUD's persisted top-left origin. Stored
    /// as `[x, y]` array to keep the schema dead-simple.
    static let positionDefaultsKey = "macRo.RunHUD.position"

    private static var panel: NSPanel?
    private static var viewModel: RunHUDViewModel?

    /// Show the HUD. Builds the panel + view model on first call;
    /// subsequent calls re-order it to front. Called from wherever the
    /// engine's run is kicked off (Editor's "Run" button, Recorder's
    /// "Test playback", future debug menu).
    public static func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let vm = RunHUDViewModel()
        let view = RunHUD(
            vm: vm,
            onDismiss: { dismiss() }
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false

        let p = NSPanel(
            contentRect: defaultRect(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true   // draggable from anywhere
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.contentView = host

        // Restore persisted origin if we have one; otherwise default to
        // bottom-right corner (16pt inset on the active screen).
        if let saved = loadSavedOrigin() {
            p.setFrameOrigin(saved)
        } else {
            p.setFrameOrigin(defaultBottomRightOrigin(for: p))
        }

        // Persist origin on every move. NSPanel doesn't expose a move
        // delegate hook directly; we observe `didMove` via NotificationCenter.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: p,
            queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            saveOrigin(win.frame.origin)
        }

        panel = p
        viewModel = vm
        p.orderFrontRegardless()
    }

    /// Dismiss the HUD if open. Safe to call from any state — no-op if
    /// the panel was never shown.
    public static func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
    }

    // MARK: Private — geometry + persistence

    private static func defaultRect() -> NSRect {
        NSRect(x: 0, y: 0, width: 320, height: 160)
    }

    private static func defaultBottomRightOrigin(for panel: NSPanel) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return .zero }
        let inset: CGFloat = 16
        let size = panel.frame.size
        let x = frame.maxX - size.width - inset
        let y = frame.minY + inset
        return NSPoint(x: x, y: y)
    }

    private static func loadSavedOrigin() -> NSPoint? {
        guard let arr = UserDefaults.standard.array(
            forKey: positionDefaultsKey
        ) as? [Double], arr.count == 2 else { return nil }
        return NSPoint(x: arr[0], y: arr[1])
    }

    private static func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(
            [Double(origin.x), Double(origin.y)],
            forKey: positionDefaultsKey
        )
    }
}

#Preview {
    let vm = RunHUDViewModel()
    return RunHUD(vm: vm, onDismiss: {})
        .padding(MacRoTheme.Spacing.xl)
        .background(MacRoTheme.Color.bgPage)
}
