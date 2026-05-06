// CountdownOverlay.swift
// UI — 3-2-1 countdown shown after the game-pick sheet, before
// recording starts.
//
// Renders a large centered numeral that ticks 3 → 2 → 1 → "GO" with
// 1-second cadence. Hosted in an NSPanel at `.floating` level so it
// sits above Roblox while the user re-focuses the game window. Escape
// dismisses without starting recording.
//
// Once the countdown reaches zero, calls `Recorder.shared.startRecording`
// (async). On success → presents RecorderHUD. On failure → surfaces
// the error to the host (ContentView shows an alert) and returns to
// idle. This honors PRD epic B's edge case: "if Roblox isn't frontmost
// when the countdown ends, the recorder's preflight will throw — show
// the error gracefully, don't loop forever."
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5
// + docs/prd.md > Epic B (3-2-1 countdown story).
//
// Voice: builder-to-builder, sentence case, no emoji. All visuals via
// MacRoTheme.

import AppKit
import Combine
import SwiftUI

// MARK: - View model

/// Drives the 3 → 2 → 1 → GO sequence. Lifetime tied to the panel
/// host. 1-second cadence; total 3 seconds + a brief "GO" beat before
/// the recorder is asked to start.
@MainActor
final class CountdownViewModel: ObservableObject {

    /// Sequence we display. The "Go" beat is short (200ms) — long
    /// enough to register, short enough not to delay the recording.
    enum Step: Equatable {
        case three
        case two
        case one
        case go

        var label: String {
            switch self {
            case .three: return "3"
            case .two:   return "2"
            case .one:   return "1"
            case .go:    return "GO"
            }
        }
    }

    @Published var step: Step = .three

    /// Closure fired once the GO beat completes — host calls
    /// `Recorder.shared.startRecording` here.
    var onComplete: (() -> Void)?

    /// Closure fired when the user hits Escape during the countdown —
    /// host dismisses the overlay and returns to idle.
    var onCancel: (() -> Void)?

    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.step = .three
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            self.step = .two
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            self.step = .one
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            self.step = .go
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            self.onComplete?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        onCancel?()
    }

    deinit {
        task?.cancel()
    }
}

// MARK: - View

/// Centered numeral on a translucent backdrop. Whole panel is escape-
/// dismissable via the local key monitor installed by the host.
struct CountdownOverlayView: View {

    @ObservedObject var vm: CountdownViewModel
    let gameName: String

    var body: some View {
        ZStack {
            MacRoTheme.Color.bgPage.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: MacRoTheme.Spacing.xl) {
                Text("Recording \(gameName) in")
                    .font(MacRoTheme.Font.body)
                    .foregroundStyle(MacRoTheme.Color.fg2)
                    .tracking(0.12 * 13)
                    .textCase(.uppercase)

                Text(vm.step.label)
                    .font(MacRoTheme.Font.displayXL)
                    .foregroundStyle(numeralColor)
                    .id(vm.step)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                Text("press esc to cancel")
                    .font(MacRoTheme.Font.monoMicro)
                    .foregroundStyle(MacRoTheme.Color.fg3)
                    .tracking(0.12 * 11)
                    .textCase(.uppercase)
            }
            .animation(.easeInOut(duration: 0.18), value: vm.step)
        }
    }

    /// Numeral color shifts as the countdown progresses — brand cyan
    /// for the lead-in beats, brand magenta for "1" (the urgency
    /// moment), product teal for "GO" so the eye registers the
    /// transition into recording.
    private var numeralColor: SwiftUI.Color {
        switch vm.step {
        case .three, .two: return MacRoTheme.Color.brandCyan
        case .one:         return MacRoTheme.Color.brandMagenta
        case .go:          return MacRoTheme.Color.productTeal
        }
    }
}

// MARK: - Panel host

/// Floating-panel host for the countdown. Mirrors RecorderHUDPanel's
/// shape but covers the active screen's full visible frame so the
/// countdown reads from anywhere on screen.
@MainActor
public enum CountdownOverlayPanel {

    private static var panel: NSPanel?
    private static var viewModel: CountdownViewModel?
    private static var keyMonitor: Any?

    /// Show the countdown. `onComplete` fires after the GO beat;
    /// `onCancel` fires on Escape. Both close the panel before invoking.
    public static func show(
        game: GameSelection,
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        if panel != nil {
            // Already showing — defensive guard against double-tap.
            return
        }

        let vm = CountdownViewModel()
        vm.onComplete = {
            dismiss()
            onComplete()
        }
        vm.onCancel = {
            dismiss()
            onCancel()
        }

        let view = CountdownOverlayView(vm: vm, gameName: game.displayName)
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false

        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hasShadow = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.contentView = host
        p.setFrame(frame, display: true)

        // Local key monitor for Escape — the panel's `.nonactivatingPanel`
        // style means it doesn't become key, so we install a local
        // monitor scoped to the app. Mirror of AppShortcutMonitor's
        // local-monitor pattern.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 0x35 {  // kVK_Escape
                vm.cancel()
                return nil  // swallow the escape so it doesn't propagate
            }
            return event
        }

        // Honor the HUD-click filter contract — the countdown overlay
        // covers the screen and would absorb every click as a phantom
        // event if we didn't tell the recorder. The recorder isn't
        // running yet (countdown precedes startRecording), so this is
        // effectively a no-op now, but if a future code path reorders
        // the call site (e.g., overlap with a "warm up SCK before
        // countdown" path) the contract holds either way.
        Recorder.shared.setOwnWindowFrames([p.frame])

        panel = p
        viewModel = vm
        p.orderFrontRegardless()
        vm.start()
    }

    /// Close the overlay. Safe to call from any state.
    public static func dismiss() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        // Clear the recorder's frame filter — RecorderHUD will re-push
        // its own frame when it shows.
        Recorder.shared.setOwnWindowFrames([])
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
    }
}

#Preview {
    let vm = CountdownViewModel()
    return CountdownOverlayView(vm: vm, gameName: "Pet Simulator 99")
        .frame(width: 800, height: 600)
        .onAppear { vm.start() }
}
