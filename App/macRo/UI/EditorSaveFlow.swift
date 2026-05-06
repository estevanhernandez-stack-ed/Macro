// EditorSaveFlow.swift
// UI / domain glue — the editor's save flow (item 8c).
//
// The save flow takes a `WorkingState` (events + cuts + selection)
// and a destination URL, then:
//
//   1. Compresses cuts into the flat events list:
//      - Sort cuts by start time.
//      - For each cut [s, e), drop events with s < t < e.
//      - For events at t >= e, shift `t` backward by (e - s).
//      - For loop event `target` references that fall after a cut,
//        renumber by subtracting the cut duration.
//
//   2. Builds the final bundle:
//      - manifest.yaml — current `state.bundle.manifest` as-is.
//      - timeline.yaml — compressed events list + subs + stopOn.
//      - gates/ — copies referenced PNGs (gate refs from the
//        compressed event list + stopOn refs); drops every
//        snap-<ms>.png (those were authoring snapshots, not gate
//        refs).
//
//   3. Writes to disk:
//      - Default: overwrite-in-place at `currentBundleURL`.
//      - Backup-then-write semantics — write to a temp dir first,
//        then atomic-replace.
//      - On manifest.id collision with a different existing bundle:
//        prompt "Replace, save as new version, cancel?".
//
// Cut compression is the new logic the editor introduces. Tests
// cover a hand-built state to confirm semantics. Save-flow round
// trip is covered by a full bundle save → re-load assertion.

import AppKit
import Foundation

// MARK: - SaveResult

enum EditorSaveResult: Equatable {
    case saved(url: URL)
    case cancelled
    case failed(message: String)
}

// MARK: - SaveFlow

enum EditorSaveFlow {

    // MARK: - Cut compression (the load-bearing edit logic)

    /// Compress cuts into a flat events list. Returns the new events
    /// (with shifted `t` and updated loop targets). Cuts are not
    /// preserved in the result — they're the edit-time overlay; the
    /// saved bundle has flat, post-cut events.
    static func compress(
        events: [TimelineEvent],
        cuts: [CutRange]
    ) -> [TimelineEvent] {
        guard !cuts.isEmpty else { return events }

        // Sort cuts by start. Required for cumulative-shift math.
        let sortedCuts = cuts.sorted { $0.start < $1.start }

        // Helper — cumulative cut duration before original time `t`.
        // An event at `t` strictly inside a cut is dropped; we
        // therefore only call this for events that survive.
        func cumulativeBefore(_ t: Double) -> Double {
            var sum: Double = 0
            for cut in sortedCuts {
                if cut.end <= t {
                    sum += cut.duration
                } else if cut.contains(t) {
                    // Inside a cut — caller should not invoke this for
                    // strictly-inside events. Defensive: snap to cut
                    // start (drop the inside-cut span).
                    sum += (t - cut.start)
                    return sum
                } else {
                    // cut starts after t — no contribution.
                    break
                }
            }
            return sum
        }

        // Helper — true if `t` falls strictly inside ANY cut.
        func isCut(_ t: Double) -> Bool {
            sortedCuts.contains { $0.contains(t) }
        }

        // Walk events, drop strictly-inside, shift the rest.
        var out: [TimelineEvent] = []
        for ev in events {
            let t = eventTime(ev)
            if isCut(t) { continue }
            let newT = max(t - cumulativeBefore(t), 0)

            // Loop targets: same shift logic. If the target itself
            // falls inside a cut, snap to cut.start - cumulativeBefore
            // (the surviving boundary of where the loop wanted to
            // jump). Otherwise, normal shift.
            if case .loop(let p) = ev {
                let target = p.target
                let newTarget: Double
                if let inside = sortedCuts.first(where: { $0.contains(target) }) {
                    newTarget = max(inside.start - cumulativeBefore(inside.start), 0)
                } else {
                    newTarget = max(target - cumulativeBefore(target), 0)
                }
                out.append(.loop(.init(
                    t: newT,
                    label: p.label,
                    target: newTarget,
                    delayMs: p.delayMs
                )))
            } else if let shifted = withShifted(t: newT, event: ev) {
                out.append(shifted)
            }
        }
        return out
    }

    // MARK: - Build bundle

    /// Build the final compressed bundle from the working state.
    /// Pure transformation — no IO, no side effects. Ready for tests.
    static func buildBundle(from state: WorkingState) -> MacroBundleData {
        let compressed = compress(events: state.bundle.timeline.events, cuts: state.cuts)
        let timeline = Timeline(
            events: compressed,
            stopOn: state.bundle.timeline.stopOn,
            subs: state.bundle.timeline.subs
        )
        return MacroBundleData(
            manifest: state.bundle.manifest,
            timeline: timeline
        )
    }

    // MARK: - Referenced gate refs

    /// All gate refs referenced by the bundle's timeline + stopOn +
    /// subs. Returns `<gateKind>-<ref>` (without `.png`). The save
    /// flow uses this to decide which PNGs survive into the saved
    /// bundle's `gates/` dir.
    static func referencedGateRefs(in bundle: MacroBundleData) -> Set<String> {
        var refs: Set<String> = []

        func collect(from events: [TimelineEvent]) {
            for ev in events {
                if case .gate(let p) = ev {
                    refs.insert("\(p.gateKind.rawValue)-\(p.ref)")
                }
            }
        }

        collect(from: bundle.timeline.events)
        for trigger in bundle.timeline.stopOn ?? [] {
            refs.insert("\(trigger.when.gateKind.rawValue)-\(trigger.when.ref)")
        }
        for (_, sub) in bundle.timeline.subs ?? [:] {
            collect(from: sub.events)
        }
        return refs
    }

    // MARK: - Save (full IO path)

    /// Persist the working state to `destination`. Overwrites in place
    /// after a backup-to-temp safety pass.
    @MainActor
    static func save(
        state: WorkingState,
        currentBundleURL: URL,
        destination: URL? = nil,
        confirmReplace: () -> Bool = { true }
    ) -> EditorSaveResult {
        let target = destination ?? currentBundleURL
        let bundle = buildBundle(from: state)

        // Collision check — only if the destination exists AND points
        // to a bundle with a different `manifest.id`.
        if FileManager.default.fileExists(atPath: target.path),
           target != currentBundleURL {
            let existingId = (try? MacroBundle.load(at: target).manifest.id) ?? ""
            if !existingId.isEmpty, existingId != bundle.manifest.id {
                if !confirmReplace() {
                    return .cancelled
                }
            }
        }

        do {
            // 1. Write to a sibling temp dir so an interrupted save
            //    leaves the original bundle intact.
            let tempDir = target
                .deletingLastPathComponent()
                .appendingPathComponent(".macRo-save-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let tempBundle = tempDir.appendingPathComponent(target.lastPathComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: tempBundle, withIntermediateDirectories: true)

            // 2. Run MacroBundle.save (writes manifest.yaml + timeline.yaml).
            try MacroBundle.save(bundle, to: tempBundle)

            // 3. Copy referenced gate PNGs from the source bundle's
            //    gates/ dir; drop `snap-<ms>.png` and unreferenced files.
            let referenced = referencedGateRefs(in: bundle)
            let sourceGates = currentBundleURL.appendingPathComponent("gates", isDirectory: true)
            let destGates = tempBundle.appendingPathComponent("gates", isDirectory: true)
            if FileManager.default.fileExists(atPath: sourceGates.path) {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: sourceGates,
                    includingPropertiesForKeys: nil
                )) ?? []
                for url in contents where url.pathExtension.lowercased() == "png" {
                    let stem = url.deletingPathExtension().lastPathComponent
                    if stem.hasPrefix("snap-") { continue }
                    if !referenced.contains(stem) { continue }
                    let destURL = destGates.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.copyItem(at: url, to: destURL)
                }
            }

            // 4. Atomic-replace target with the temp bundle.
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tempBundle)
            } else {
                // Destination doesn't exist — move the temp into place.
                try FileManager.default.moveItem(at: tempBundle, to: target)
            }

            // 5. Best-effort cleanup of the .macRo-save-<hex> dir.
            try? FileManager.default.removeItem(at: tempDir)

            return .saved(url: target)
        } catch let error as MacroBundle.MacroBundleError {
            return .failed(message: error.errorDescription ?? "Unknown bundle error.")
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Replace prompt

    /// Default macOS NSAlert prompt for the "Replace, save as new
    /// version, cancel?" path. Returns true to proceed (replace).
    @MainActor
    static func defaultReplacePrompt(existingId: String, newId: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "A different macro is already saved at this location"
        alert.informativeText = "Existing: \(existingId)\nNew: \(newId)\n\nReplace it, or cancel?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
}
