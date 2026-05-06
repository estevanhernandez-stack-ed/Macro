// RecorderHUD.swift
// UI — floating recording overlay window.
//
// RecorderHUD is the single-pane control surface during a capture. It
// mirrors `Recorder.shared.state` in real time, renders an MM:SS timer
// + pulsing recording-red dot, exposes a Stop button, and reminds the
// user that `⌃⌥⌘.` is always-on as a blast-shield. The HUD lives above
// every other window (`.floating` level) so it never gets buried under
// Roblox.
//
// HUD-CLICK FILTER (the load-bearing contract from item 7a):
//   The recorder writes input events to the JSONL UNFILTERED unless
//   the HUD reports its own panel frame via
//   `Recorder.shared.setOwnWindowFrames([panel.frame])`. Without that
//   call, every HUD click would land in the macro as a phantom event.
//   This file calls setOwnWindowFrames at:
//     • appear-time (panel first shown)
//     • every drag move (`NSWindow.didMoveNotification`)
//     • every screen change (`NSWindow.didChangeScreenNotification`)
//     • dismiss-time (cleared with empty array)
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// (Capture → edit) + § 8 (Visual treatment) + docs/spec.md > Recorder
// + docs/prd.md > Epic B.
//
// Threading: the HUD's view model wires `Recorder.shared.onStateChange`
// (which fires on MainActor by Recorder's contract) to `@Published`
// state. SwiftUI bindings stay on main throughout. The elapsed-time
// timer also runs on main via `Timer.scheduledTimer`.
//
// Voice: builder-to-builder, sentence case, em-dashes welcome, no emoji.
// All colors / fonts / spacing route through MacRoTheme.

import AppKit
import Combine
import SwiftUI

// MARK: - View model

/// Mirrors `Recorder.shared` state for SwiftUI. Owns a 1-Hz tick that
/// pushes the elapsed-time string into a `@Published` so the HUD redraws
/// once per second without re-rendering the whole tree on every state
/// transition. Also drives a 2-Hz pulse for the recording dot. Held by
/// `RecorderHUDPanel.show()` for the lifetime of the panel.
@MainActor
final class RecorderHUDViewModel: ObservableObject {

    // MARK: Published surface

    @Published var state: RecorderState = .idle
    @Published var elapsedDisplay: String = "00:00"
    /// Pulse value in [0, 1]; the recording dot's opacity oscillates
    /// against this. 2 Hz feels alive without strobing.
    @Published var pulse: Double = 1.0

    // MARK: Private

    private var tickTimer: Timer?
    private var pulseTimer: Timer?
    private var startedAt: CFAbsoluteTime?
    private var previousOnStateChange: ((RecorderState) -> Void)?

    /// Closure the panel host wires in so the VM can ask the host to
    /// dismiss after a `.finished` state's auto-dismiss timeout.
    var onAutoDismiss: (() -> Void)?

    /// Closure the panel host wires in so the VM can surface the
    /// finalized bundle URL once stopRecording resolves.
    var onFinished: ((URL) -> Void)?

    /// Closure the panel host wires in so the VM can surface a recorder
    /// failure (alert) on the host's container.
    var onFailed: ((RecorderError) -> Void)?

    // MARK: Lifecycle

    init() {
        previousOnStateChange = Recorder.shared.onStateChange
        let chained = previousOnStateChange
        Recorder.shared.onStateChange = { [weak self] newState in
            self?.handleStateChange(newState)
            chained?(newState)
        }
        // Pull initial values in case the recorder's already running when
        // the HUD is built.
        handleStateChange(Recorder.shared.state)
        startTick()
        startPulse()
    }

    deinit {
        tickTimer?.invalidate()
        pulseTimer?.invalidate()
        let prev = previousOnStateChange
        Task { @MainActor in
            Recorder.shared.onStateChange = prev
        }
    }

    // MARK: Actions

    /// Stop button → recorder finalize. Sets `finalizing` state via the
    /// recorder's own state machine; on success surfaces the bundle URL
    /// to the host via `onFinished`. The host shows the reveal-in-Finder
    /// alert.
    func stop() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Recorder.shared.stopRecording()
                self.onFinished?(url)
            } catch let err as RecorderError {
                self.onFailed?(err)
            } catch {
                self.onFailed?(.finalizeFailed(message: error.localizedDescription))
            }
        }
    }

    // MARK: Private helpers

    private func handleStateChange(_ newState: RecorderState) {
        state = newState
        if case .recording = newState, startedAt == nil {
            startedAt = CFAbsoluteTimeGetCurrent()
        }
        // Auto-dismiss on .finished after a brief beat. The host already
        // has the bundle URL via onFinished; this just hides the panel.
        if case .finished = newState {
            elapsedDisplay = elapsedString()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.onAutoDismiss?()
            }
        }
        if case .failed = newState {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.onAutoDismiss?()
            }
        }
    }

    private func startTick() {
        // 1 Hz is enough for an MM:SS display.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedDisplay = self?.elapsedString() ?? "00:00"
            }
        }
    }

    private func startPulse() {
        // 2 Hz fade for the recording dot. Visual heartbeat — alive
        // enough to be noticed, slow enough not to nag.
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pulse = (self?.pulse ?? 1.0) >= 1.0 ? 0.45 : 1.0
            }
        }
    }

    private func elapsedString() -> String {
        guard let started = startedAt else { return "00:00" }
        switch state {
        case .idle, .preflight:
            return "00:00"
        default:
            let secs = max(0, Int(CFAbsoluteTimeGetCurrent() - started))
            return String(format: "%02d:%02d", secs / 60, secs % 60)
        }
    }
}

// MARK: - View

/// The HUD body. Embedded in an NSPanel by `RecorderHUDPanel.show()`.
struct RecorderHUDView: View {

    @ObservedObject var vm: RecorderHUDViewModel

    /// Closure the host panel uses to dismiss itself when the user hits
    /// the dismiss button on a terminal state.
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
                .strokeBorder(borderColor.opacity(0.55), lineWidth: 1)
        )
    }

    /// Border tint shifts with state so the HUD reads as "live" without
    /// the user having to parse the pill text.
    private var borderColor: SwiftUI.Color {
        switch vm.state {
        case .recording:           return MacRoTheme.Color.recordingRed
        case .finalizing:          return MacRoTheme.Color.stateInfo
        case .finished:            return MacRoTheme.Color.stateOk
        case .failed:              return MacRoTheme.Color.stateDanger
        case .idle, .preflight:    return MacRoTheme.Color.hudBorder
        }
    }

    // MARK: Header — recording dot + state pill + timer

    private var header: some View {
        HStack(spacing: MacRoTheme.Spacing.sm) {
            if case .recording = vm.state {
                Circle()
                    .fill(MacRoTheme.Color.recordingRed)
                    .frame(width: 10, height: 10)
                    .opacity(vm.pulse)
                    .animation(.easeInOut(duration: 0.5), value: vm.pulse)
            }
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
    private func body(for state: RecorderState) -> some View {
        switch state {
        case .idle, .preflight:
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text("Finding the Roblox window and warming up capture.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .recording:
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Recording")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text("Every key, click, and camera move in Roblox is captured. HUD clicks are filtered out.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .finalizing:
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text("Packaging streams into a .macro bundle.")
                    .font(MacRoTheme.Font.bodySmall)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .finished(let url):
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Saved.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(url.lastPathComponent)
                    .font(MacRoTheme.Font.mono)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

        case .failed(let error):
            VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                Text("Failed.")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg1)
                Text(error.errorDescription ?? "Unknown recorder error.")
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
                .disabled(isFinalizing)
                .opacity(isFinalizing ? 0.6 : 1.0)
            }
            Spacer(minLength: 0)
            Text("abort: ⌃⌥⌘.")
                .font(MacRoTheme.Font.monoMicro)
                .foregroundStyle(MacRoTheme.Color.fg3)
                .tracking(0.12 * 11)
                .textCase(.uppercase)
        }
    }

    private var isFinalizing: Bool {
        if case .finalizing = vm.state { return true }
        return false
    }
}

// MARK: - State pill

private struct StatePill: View {
    let state: RecorderState

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

    private var label: String {
        switch state {
        case .idle:       return "Idle"
        case .preflight:  return "Preflight"
        case .recording:  return "Recording"
        case .finalizing: return "Saving"
        case .finished:   return "Saved"
        case .failed:     return "Failed"
        }
    }

    private var foreground: SwiftUI.Color {
        switch state {
        case .idle, .preflight: return MacRoTheme.Color.fg2
        case .recording:        return MacRoTheme.Color.recordingRed
        case .finalizing:       return MacRoTheme.Color.stateInfo
        case .finished:         return MacRoTheme.Color.stateOk
        case .failed:           return MacRoTheme.Color.stateDanger
        }
    }

    private var background: SwiftUI.Color {
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fill: SwiftUI.Color {
        // Stop is teal CTA per spec § 8 (matches RunHUD). Dismiss on
        // terminal states uses muted bgRaised.
        let base = isTerminal ? MacRoTheme.Color.bgRaised : MacRoTheme.Color.productTeal
        return base.opacity(hovering ? 0.92 : 1.0)
    }
}

// MARK: - Panel host

/// Floating-panel host for the RecorderHUD. Mirrors RunHUDPanel's
/// pattern — NSPanel + `.floating` + `.canJoinAllSpaces` +
/// `.nonactivatingPanel` so the panel never steals focus from Roblox.
///
/// `show()` is idempotent — calling it twice surfaces the existing
/// panel rather than spawning a second.
@MainActor
public enum RecorderHUDPanel {

    /// UserDefaults key for the HUD's persisted top-left origin. Stored
    /// as `[x, y]` array.
    static let positionDefaultsKey = "macRo.RecorderHUD.position"

    private static var panel: NSPanel?
    private static var viewModel: RecorderHUDViewModel?
    private static var moveObserver: NSObjectProtocol?
    private static var screenObserver: NSObjectProtocol?

    /// Show the HUD. Builds the panel + view model on first call;
    /// subsequent calls re-order it to front. The `onFinished` and
    /// `onFailed` closures bubble recorder outcomes back to the calling
    /// view (ContentView in 7b) so the reveal-in-Finder alert can be
    /// presented on the main app window — the HUD itself doesn't host
    /// alerts (NSPanel + alerts is a known SwiftUI sharp edge).
    public static func show(
        onFinished: @escaping (URL) -> Void,
        onFailed: @escaping (RecorderError) -> Void
    ) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let vm = RecorderHUDViewModel()
        vm.onFinished = onFinished
        vm.onFailed = onFailed
        vm.onAutoDismiss = { dismiss() }

        let view = RecorderHUDView(
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
        // bottom-right corner (16pt inset on the active screen). Mirror
        // RunHUD's geometry contract.
        if let saved = loadSavedOrigin() {
            p.setFrameOrigin(saved)
        } else {
            p.setFrameOrigin(defaultBottomRightOrigin(for: p))
        }

        // Persist origin on every move + report frame to the recorder so
        // the HUD-click filter contract holds.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: p,
            queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            saveOrigin(win.frame.origin)
            Recorder.shared.setOwnWindowFrames([win.frame])
        }

        // Screen change (display added / removed / scale flip) — re-push
        // the frame so screen-coord deltas don't desync the filter.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: p,
            queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            Recorder.shared.setOwnWindowFrames([win.frame])
        }

        panel = p
        viewModel = vm
        p.orderFrontRegardless()

        // First push of the frame happens after orderFrontRegardless so
        // the panel's frame is in its final post-orderFront position.
        Recorder.shared.setOwnWindowFrames([p.frame])
    }

    /// Dismiss the HUD if open. Clears the recorder's HUD-frame filter
    /// so a future non-recording session doesn't carry a stale rect.
    /// Safe to call from any state — no-op if the panel was never shown.
    public static func dismiss() {
        if let m = moveObserver {
            NotificationCenter.default.removeObserver(m)
            moveObserver = nil
        }
        if let s = screenObserver {
            NotificationCenter.default.removeObserver(s)
            screenObserver = nil
        }
        Recorder.shared.setOwnWindowFrames([])
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
    let vm = RecorderHUDViewModel()
    return RecorderHUDView(vm: vm, onDismiss: {})
        .padding(MacRoTheme.Spacing.xl)
        .background(MacRoTheme.Color.bgPage)
}
