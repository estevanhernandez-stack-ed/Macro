// EditorScriptView.swift
// UI — YAML script editor for the editor (item 8c).
//
// Toggled from the toolbar's `{ } script` button. Replaces the lane
// stack with an NSTextView-hosted YAML editor; toggle off restores
// the lanes.
//
// Lossless round-trip:
//   timeline view → bundle.timeline → YAML → user edits → re-parsed
//   YAML → bundle.timeline → timeline view
//
// The YAML serializer is Yams (same path the bundle save flow uses);
// any field on TimelineEvent / Timeline survives the round-trip
// because Codable encode then decode preserves every value the
// schema declares — including fields the timeline view doesn't
// surface today (jitter on click events, delayMs on loop events,
// etc.). The script view is the power-user surface that lets the
// user touch those without forcing a per-field inspector control.
//
// Live validation:
//   - Parse on every edit. Show a green dot if the YAML is a valid
//     Timeline; red dot + error message if it isn't.
//   - Don't gate Save here — that's the save flow's job. The script
//     view can leave the bundle in an unsaved-but-invalid state if
//     the user is mid-edit; on toggle-back-to-lanes (or on commit)
//     we reject the swap if invalid and surface the error inline.
//
// Decision on YAML highlighting:
//   - Full syntax highlighting (token-aware coloring) is a /iterate
//     surface — it's a substantial NSAttributedString pass and
//     doesn't change the round-trip contract.
//   - For 8c we ship monospaced JetBrains Mono, brand-cyan caret,
//     plain text. Validation status is the load-bearing read; once
//     highlighting lands at /iterate it's a strict polish pass.

import AppKit
import SwiftUI
import Yams

// MARK: - EditorScriptView

struct EditorScriptView: View {

    let state: WorkingState
    let dispatch: (EditorCommand) -> Void
    let onCloseRequested: () -> Void

    /// Serialized YAML text. Initialized from `state.bundle.timeline`
    /// on first appear, refreshed when the user comes back to the
    /// script view after a lane edit.
    @State private var yamlText: String = ""
    @State private var initialized: Bool = false
    /// Last-parse result. Drives the validation indicator + the
    /// commit button's enabled state.
    @State private var parseResult: ParseResult = .empty

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(MacRoTheme.Color.laneBorder)

            ScriptTextEditor(
                text: $yamlText,
                onChange: { newValue in
                    revalidate(yaml: newValue)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().background(MacRoTheme.Color.laneBorder)

            footer
        }
        .background(MacRoTheme.Color.bgPage)
        .onAppear {
            if !initialized {
                yamlText = (try? Self.serialize(timeline: state.bundle.timeline)) ?? "# (failed to serialize)\n"
                revalidate(yaml: yamlText)
                initialized = true
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        HStack(spacing: MacRoTheme.Spacing.sm) {
            Text("SCRIPT")
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("·")
                .foregroundStyle(MacRoTheme.Color.fg3)
            Text("timeline.yaml")
                .font(MacRoTheme.Font.mono)
                .foregroundStyle(MacRoTheme.Color.fg2)

            Spacer()

            validationIndicator

            pillButton(label: "Commit to lanes", enabled: parseResult.isValid) {
                commit()
            }
            pillButton(label: "Close (no commit)", enabled: true) {
                onCloseRequested()
            }
        }
        .padding(.horizontal, MacRoTheme.Spacing.lg)
        .padding(.vertical, MacRoTheme.Spacing.sm)
        .background(MacRoTheme.Color.bgSurface)
    }

    @ViewBuilder
    private var validationIndicator: some View {
        HStack(spacing: MacRoTheme.Spacing.xs) {
            Circle()
                .fill(parseResult.isValid ? MacRoTheme.Color.stateOk : MacRoTheme.Color.stateDanger)
                .frame(width: 8, height: 8)
            Text(parseResult.statusLabel)
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(parseResult.isValid ? MacRoTheme.Color.fg2 : MacRoTheme.Color.stateDanger)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if !parseResult.isValid, let msg = parseResult.errorMessage {
                Text(msg)
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.stateDanger)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else {
                Text("YAML is the canonical script for this macro. Edits round-trip through Yams — fields the lane view doesn't show (jitter, delayMs) are preserved.")
                    .font(MacRoTheme.Font.monoMicro)
                    .tracking(0.12 * 11)
                    .foregroundStyle(MacRoTheme.Color.fg3)
            }
            Spacer()
        }
        .padding(.horizontal, MacRoTheme.Spacing.lg)
        .padding(.vertical, MacRoTheme.Spacing.sm)
        .background(MacRoTheme.Color.bgSurface)
    }

    // MARK: - Validation

    private func revalidate(yaml: String) {
        if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parseResult = .empty
            return
        }
        do {
            let decoder = YAMLDecoder()
            let _: Timeline = try decoder.decode(Timeline.self, from: yaml)
            parseResult = .valid
        } catch {
            parseResult = .invalid(message: String(describing: error))
        }
    }

    // MARK: - Commit

    private func commit() {
        guard parseResult.isValid else { return }
        do {
            let decoder = YAMLDecoder()
            let parsed: Timeline = try decoder.decode(Timeline.self, from: yamlText)
            dispatch(EditorCommands.replaceTimeline(
                with: parsed,
                label: "Edit timeline via script view",
                from: state
            ))
            onCloseRequested()
        } catch {
            // revalidate will paint the error.
            revalidate(yaml: yamlText)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private func pillButton(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MacRoTheme.Font.monoMicro)
                .tracking(0.12 * 11)
                .foregroundStyle(enabled ? MacRoTheme.Color.fg2 : MacRoTheme.Color.fg3.opacity(0.4))
                .padding(.horizontal, MacRoTheme.Spacing.sm)
                .padding(.vertical, MacRoTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .fill(MacRoTheme.Color.bgRaised.opacity(enabled ? 1.0 : 0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MacRoTheme.Radius.sm)
                        .strokeBorder(MacRoTheme.Color.laneBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - YAML serialization helpers

    /// Serialize a Timeline to YAML via Yams. Pure encode — Codable
    /// preserves every field the schema declares, including
    /// jitterMs / delayMs that the lane view doesn't surface today.
    static func serialize(timeline: Timeline) throws -> String {
        let encoder = YAMLEncoder()
        return try encoder.encode(timeline)
    }
}

// MARK: - ParseResult

private enum ParseResult: Equatable {
    case empty
    case valid
    case invalid(message: String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var statusLabel: String {
        switch self {
        case .empty:   return "(empty)"
        case .valid:   return "valid YAML"
        case .invalid: return "invalid"
        }
    }

    var errorMessage: String? {
        if case .invalid(let m) = self { return m }
        return nil
    }
}

// MARK: - NSTextView host

/// NSTextView wrapped for SwiftUI. Plain monospaced text with brand
/// cursor color. We hand-wire `text` two-way so SwiftUI sees every
/// edit and `onChange` fires for the live-validation pass.
private struct ScriptTextEditor: NSViewRepresentable {

    @Binding var text: String
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        if let mono = NSFont(name: "JetBrains Mono", size: 13) {
            textView.font = mono
        } else {
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        textView.textColor = NSColor(MacRoTheme.Color.fg1)
        textView.backgroundColor = NSColor(MacRoTheme.Color.bgPage)
        textView.insertionPointColor = NSColor(MacRoTheme.Color.brandCyan)
        textView.drawsBackground = true

        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text

        scroll.documentView = textView
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onChange: (String) -> Void

        init(text: Binding<String>, onChange: @escaping (String) -> Void) {
            self._text = text
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newValue = textView.string
            text = newValue
            onChange(newValue)
        }
    }
}
