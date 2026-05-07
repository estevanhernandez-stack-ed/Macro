// ArmedOverlayPanel.swift
// UI — floating "armed" overlay shown after the user clicks Run on a
// Library card. Bridges the gap between "macro is loaded" and "engine
// is firing" so the user can switch to Roblox at their own pace and
// fire the engine via the global engage hotkey (⌃⌥⌘,).
//
// Why a panel instead of a sheet: the user must be able to leave macRo
// and switch to Roblox while this stays visible. NSPanel with
// `.nonactivatingPanel` + `.canJoinAllSpaces` + `.fullScreenAuxiliary`
// floats above all other apps including Roblox in fullscreen.
//
// Also surfaces the macro's required PS99 keybinds — the user is
// expected to set these in PS99's Settings → Keybinds before firing.
// macRo can't read PS99's keybind state from outside, so the contract
// is "match these exactly or the macro will misfire." Same line that
// the existing BindingMismatchPrompt walks at engine pre-flight; this
// is the pre-arm prompt so the user has a chance to set them BEFORE
// engaging.

import AppKit
import SwiftUI

// MARK: - View model

@MainActor
final class ArmedOverlayViewModel: ObservableObject {
    let macroName: String
    let bindings: [BindingRow]
    var onCancel: (() -> Void)?

    init(macroName: String, bindings: [BindingRow], onCancel: (() -> Void)? = nil) {
        self.macroName = macroName
        self.bindings = bindings
        self.onCancel = onCancel
    }

    struct BindingRow: Identifiable, Hashable {
        let id: String     // action label
        let action: String // human-readable
        let key: String    // the literal key the engine will press
    }
}

// MARK: - Overlay view

struct ArmedOverlayView: View {
    @ObservedObject var vm: ArmedOverlayViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(MacRoTheme.Color.bgSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(MacRoTheme.Color.productTeal, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 6)

                VStack(alignment: .leading, spacing: MacRoTheme.Spacing.md) {
                    HStack(spacing: MacRoTheme.Spacing.sm) {
                        Circle()
                            .fill(MacRoTheme.Color.productTeal)
                            .frame(width: 10, height: 10)
                        Text("ARMED")
                            .font(MacRoTheme.Font.monoMicro)
                            .tracking(0.12 * 11)
                            .foregroundStyle(MacRoTheme.Color.productTeal)
                        Text(vm.macroName)
                            .font(MacRoTheme.Font.heading1)
                            .foregroundStyle(MacRoTheme.Color.fg1)
                        Spacer()
                    }

                    if !vm.bindings.isEmpty {
                        VStack(alignment: .leading, spacing: MacRoTheme.Spacing.xs) {
                            Text("SET THESE KEYBINDS IN PET SIM 99 SETTINGS")
                                .font(MacRoTheme.Font.monoMicro)
                                .tracking(0.12 * 11)
                                .foregroundStyle(MacRoTheme.Color.fg3)
                            ForEach(vm.bindings) { row in
                                HStack(spacing: MacRoTheme.Spacing.sm) {
                                    Text(row.action)
                                        .font(MacRoTheme.Font.bodySmall)
                                        .foregroundStyle(MacRoTheme.Color.fg2)
                                    Spacer()
                                    Text(row.key.uppercased())
                                        .font(MacRoTheme.Font.monoMicro)
                                        .foregroundStyle(MacRoTheme.Color.productTeal)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(MacRoTheme.Color.laneBorder, lineWidth: 1)
                                        )
                                }
                            }
                        }
                        .padding(.vertical, MacRoTheme.Spacing.xs)
                    }

                    Divider().background(MacRoTheme.Color.laneBorder)

                    HStack(spacing: MacRoTheme.Spacing.lg) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Switch to Roblox, then press")
                                .font(MacRoTheme.Font.bodySmall)
                                .foregroundStyle(MacRoTheme.Color.fg2)
                            HStack(spacing: 6) {
                                KeyChip("⌃")
                                KeyChip("⌥")
                                KeyChip("⌘")
                                KeyChip(",")
                                Text("to start")
                                    .font(MacRoTheme.Font.bodySmall)
                                    .foregroundStyle(MacRoTheme.Color.fg2)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Cancel anytime")
                                .font(MacRoTheme.Font.bodySmall)
                                .foregroundStyle(MacRoTheme.Color.fg3)
                            HStack(spacing: 6) {
                                KeyChip("⌃")
                                KeyChip("⌥")
                                KeyChip("⌘")
                                KeyChip(".")
                            }
                        }
                    }
                }
                .padding(MacRoTheme.Spacing.lg)
            }
            .frame(maxWidth: 640)
            .padding(MacRoTheme.Spacing.lg)
            Spacer().frame(height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

private struct KeyChip: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(MacRoTheme.Font.monoMicro)
            .foregroundStyle(MacRoTheme.Color.fg1)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(MacRoTheme.Color.bgRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(MacRoTheme.Color.laneBorder, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Panel host

@MainActor
enum ArmedOverlayPanel {

    private static var panel: NSPanel?
    private static var viewModel: ArmedOverlayViewModel?
    private static var keyMonitor: Any?

    /// Show the armed overlay. `onCancel` fires on Escape (the global
    /// abort hotkey path goes through ContentView's notification handler,
    /// not through this monitor — this monitor is just for Esc when the
    /// overlay has focus).
    static func show(
        macroName: String,
        bindings: [ArmedOverlayViewModel.BindingRow],
        onCancel: @escaping () -> Void
    ) {
        if panel != nil {
            // Already showing — defensive guard against double-tap.
            return
        }

        let vm = ArmedOverlayViewModel(macroName: macroName, bindings: bindings)
        vm.onCancel = {
            dismiss()
            onCancel()
        }

        let view = ArmedOverlayView(vm: vm)
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
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()

        panel = p
        viewModel = vm

        // Local Esc monitor (when macRo has focus). The global engage /
        // abort hotkeys flow through AppShortcutMonitor + the
        // notifications it posts — ContentView dismisses this panel on
        // those signals. This monitor handles the macRo-frontmost Esc
        // cancel only.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 0x35 {  // kVK_Escape
                vm.onCancel?()
                return nil
            }
            return event
        }
    }

    static func dismiss() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
    }

    static var isShowing: Bool { panel != nil }
}

