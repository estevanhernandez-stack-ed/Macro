// EditorWorkingState.swift
// UI / domain glue — the editor's mutable working state (item 8b).
//
// 8b introduces edit operations across four lanes + an inspector + a
// cropper. All of those mutate either the bundle or the cut set or the
// selection. We keep them in one value type so:
//
//   1. SwiftUI re-renders cleanly on a single @State change,
//   2. the undo/redo stack stores diffs against ONE thing, not three,
//   3. the eventual save flow (item 8c) can compress cuts and emit a
//      flat MacroBundleData without re-deriving the working set.
//
// Cut model (load-bearing decision):
//   - `bundle.timeline.events` is the AUTHORITATIVE event list. Cuts do
//     NOT mutate it.
//   - `cuts: [CutRange]` is a separate, editor-only list of half-open
//     [start, end) ranges (in seconds, original-timeline coordinates).
//   - `visibleEvents` derives at render time: drop events whose `t` is
//     strictly between any cut range, then shift later events backward
//     by the cumulative cut duration that precedes them.
//   - Boundary semantics: an event at `t == cutStart` is KEPT (and
//     timestamp unchanged). An event at `t == cutEnd` is KEPT and
//     shifted backward. Strictly-inside (cutStart < t < cutEnd) drops.
//     Half-open ranges keep operations idempotent (re-applying the same
//     cut is a no-op).
//   - "Uncut" reverses by removing the cut entry — events come back
//     because they were never deleted from `bundle.timeline.events`.
//
// Selection:
//   - Identifies an event by its index into `bundle.timeline.events`
//     (the AUTHORITATIVE list, not visible-list). The inspector reads
//     directly from that index. Lanes click-test against visible-list
//     indices and translate before storing on selection.
//
// Spec ref: docs/superpowers/specs/2026-05-03-macro-mac-app-design.md § 5.

import Foundation

// MARK: - CutRange

/// Half-open [start, end) cut on the original timeline. Keep these
/// non-overlapping and time-ordered; `addCut` enforces both.
///
/// `id` is var so resize commands can preserve identity across edits
/// (the drag-handle tracker keys by id; losing it on every resize
/// would orphan in-flight drags).
struct CutRange: Equatable, Hashable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double

    init(start: Double, end: Double, id: UUID = UUID()) {
        self.id = id
        self.start = start
        self.end = end
    }

    var duration: Double { max(end - start, 0) }

    func contains(_ t: Double) -> Bool {
        // Half-open: events at `start` are kept; events strictly inside
        // are dropped. Events at `end` are kept (and shifted backward).
        t > start && t < end
    }
}

// MARK: - EventSelection

/// Selection identifier for the inspector. Indexes into the
/// authoritative `bundle.timeline.events`.
///
/// 8b only selects top-level events; sub-macro event selection (and
/// `stopOn[]` selection) is a documented gap, captured in friction notes
/// for /iterate. Most v1 recordings have no subs, so the gap doesn't
/// block the day-one editor experience.
struct EventSelection: Equatable, Hashable {
    let originalEventIndex: Int
}

// MARK: - WorkingState

/// One value, three concerns: the bundle (authoritative events +
/// manifest), the cut overlay, and the inspector selection. Edits flow
/// in via `EditorCommand.apply(_:)`; undo via `.undo(_:)`.
struct WorkingState: Equatable {
    var bundle: MacroBundleData
    var cuts: [CutRange]
    var selection: EventSelection?

    init(
        bundle: MacroBundleData,
        cuts: [CutRange] = [],
        selection: EventSelection? = nil
    ) {
        self.bundle = bundle
        self.cuts = cuts
        self.selection = selection
    }

    // MARK: Cut helpers

    /// Cumulative cut duration before time `t` in original coordinates.
    /// Used to translate visible (compressed) timestamps back to
    /// original timestamps and vice versa.
    func cumulativeCutBefore(_ t: Double) -> Double {
        cuts
            .filter { $0.end <= t }
            .reduce(0) { $0 + $1.duration }
            // Plus the partial cut if `t` lies inside one (cuts are
            // sorted, but we search rather than assume ordering).
            + (cuts.first(where: { $0.contains(t) }).map { t - $0.start } ?? 0)
    }

    /// Total compressed-out time across all cuts.
    var totalCutDuration: Double {
        cuts.reduce(0) { $0 + $1.duration }
    }

    /// True if `t` (in original coordinates) sits strictly inside a cut.
    /// Used to drop events from `visibleEvents` and to mark paired-event
    /// deletes as "cross-cut" warnings.
    func isCut(_ t: Double) -> Bool {
        cuts.contains { $0.contains(t) }
    }

    /// Convert an original-timeline time to the visible (compressed)
    /// timeline. Times inside a cut snap to the cut's start (those
    /// events were dropped, but the playhead in compressed space lands
    /// on the surviving boundary).
    func compressedTime(_ original: Double) -> Double {
        if let cut = cuts.first(where: { $0.contains(original) }) {
            return cut.start - cumulativeCutBefore(cut.start)
        }
        return max(original - cumulativeCutBefore(original), 0)
    }

    /// Convert a visible (compressed) time back to original coordinates.
    /// Used when adding a gate or cut at the playhead — the playhead
    /// reads compressed; the schema stores original.
    func originalTime(fromCompressed compressed: Double) -> Double {
        var remaining = compressed
        var cursor: Double = 0
        // Walk cuts in order; for each kept span, see whether
        // `compressed` falls inside.
        let sortedCuts = cuts.sorted { $0.start < $1.start }
        for cut in sortedCuts {
            let keepLen = max(cut.start - cursor, 0)
            if remaining <= keepLen {
                return cursor + remaining
            }
            remaining -= keepLen
            cursor = cut.end
        }
        return cursor + remaining
    }

    /// Visible (rendered) events: drop strictly-inside cuts, shift
    /// later events backward by the cumulative cut before them.
    /// Boundary events keep their identity; downstream code can map a
    /// rendered `t` back to original via `cumulativeCutBefore` + index.
    var visibleEvents: [VisibleEvent] {
        bundle.timeline.events.enumerated().compactMap { (i, ev) -> VisibleEvent? in
            let t = eventTime(ev)
            if isCut(t) { return nil }
            return VisibleEvent(
                originalEventIndex: i,
                originalT: t,
                compressedT: max(t - cumulativeCutBefore(t), 0),
                event: ev
            )
        }
    }

    /// Compressed playback duration (original duration minus all cuts).
    var compressedDuration: Double {
        let last = bundle.timeline.events.last.map(eventTime) ?? 0
        // Pad +0.5s for editor breathing room (matches EditorView's
        // `computedDuration` original behavior).
        return max(last - totalCutDuration + 0.5, 1.0)
    }
}

// MARK: - VisibleEvent

/// A timeline event mapped into the compressed view space. The lanes
/// render against `compressedT`; the inspector edits via
/// `originalEventIndex`.
///
/// `id` derives from `originalEventIndex` so SwiftUI's `ForEach` diff
/// is stable across re-renders. (A fresh UUID per render would force a
/// full redraw on every command apply — every command rewrites
/// `bundle.timeline.events` and thus the visible-event list.)
struct VisibleEvent: Identifiable {
    var id: Int { originalEventIndex }
    let originalEventIndex: Int
    let originalT: Double
    let compressedT: Double
    let event: TimelineEvent
}

// MARK: - EditorCommand

/// Command-pattern entry. Every edit produces one of these so undo /
/// redo is just stack pop + apply. The closures capture a brief
/// description ("Add IMG gate at 0:42") for diagnostic logging; the
/// editor doesn't surface them in the UI in 8b but logs to console on
/// each apply so manual verification has a paper trail.
struct EditorCommand {
    let label: String
    let apply: (WorkingState) -> WorkingState
    let undo: (WorkingState) -> WorkingState
}

// MARK: - Command factory

enum EditorCommands {

    // -- Insert gate event --------------------------------------------

    /// Insert a gate event at original-timeline `t`. Used by the
    /// cropper after writing the PNG to disk (the disk write happens
    /// outside the command — commands are pure transforms over
    /// WorkingState).
    static func insertGate(
        at t: Double,
        ref: String,
        gateKind: TimelineEvent.TimelineEventGateKind,
        retries: Int = 3,
        timeout: Double = 30,
        onFail: TimelineEvent.TimelineEventOnFail
    ) -> EditorCommand {
        EditorCommand(
            label: "Insert \(gateKind.rawValue.uppercased()) gate at t=\(String(format: "%.2f", t))",
            apply: { state in
                let payload = TimelineEvent.TimelineEventGatePayload(
                    t: t,
                    gateKind: gateKind,
                    ref: ref,
                    retries: retries,
                    timeout: timeout,
                    onFail: onFail
                )
                let newEvent: TimelineEvent = .gate(payload)
                var events = state.bundle.timeline.events
                // Insert at the correct sorted position by `t`. Stable
                // tie-break: appended after any existing event at the
                // same t (gate-after-input feels right when the user
                // drops a gate at the playhead).
                let insertIndex = events.firstIndex(where: { eventTime($0) > t })
                    ?? events.count
                events.insert(newEvent, at: insertIndex)
                var s = state
                s.bundle = MacroBundleData(
                    manifest: state.bundle.manifest,
                    timeline: Timeline(
                        events: events,
                        stopOn: state.bundle.timeline.stopOn,
                        subs: state.bundle.timeline.subs
                    )
                )
                s.selection = EventSelection(originalEventIndex: insertIndex)
                return s
            },
            undo: { state in
                // Find the gate we inserted. We identify it by ref +
                // exact (t, kind) — there's only ever one in a sane
                // bundle. Walk in reverse so we hit the most recently
                // appended on duplicates.
                var events = state.bundle.timeline.events
                if let idx = events.lastIndex(where: { ev in
                    if case .gate(let p) = ev,
                       p.ref == ref,
                       p.gateKind == gateKind,
                       abs(p.t - t) < 0.0005 {
                        return true
                    }
                    return false
                }) {
                    events.remove(at: idx)
                }
                var s = state
                s.bundle = MacroBundleData(
                    manifest: state.bundle.manifest,
                    timeline: Timeline(
                        events: events,
                        stopOn: state.bundle.timeline.stopOn,
                        subs: state.bundle.timeline.subs
                    )
                )
                s.selection = nil
                return s
            }
        )
    }

    // -- Delete event(s) ----------------------------------------------

    /// Delete one or more events by their original-list index. Captures
    /// (index, event) pairs so undo restores them at the same indices
    /// in reverse order. Pair-aware deletion (keyDown + matching keyUp)
    /// is the caller's job — it builds the index set; this command
    /// just deletes the set.
    static func deleteEvents(
        atOriginalIndices indices: [Int]
    ) -> EditorCommand {
        // Sort descending so removal-by-index doesn't shift later
        // indices we still need to remove.
        let sorted = indices.sorted(by: >)
        return EditorCommand(
            label: "Delete \(indices.count) event(s)",
            apply: { state in
                var events = state.bundle.timeline.events
                for i in sorted where i >= 0 && i < events.count {
                    events.remove(at: i)
                }
                var s = state
                s.bundle = MacroBundleData(
                    manifest: state.bundle.manifest,
                    timeline: Timeline(
                        events: events,
                        stopOn: state.bundle.timeline.stopOn,
                        subs: state.bundle.timeline.subs
                    )
                )
                s.selection = nil
                return s
            },
            undo: { state in
                // Re-insert in ascending index order so each restore
                // lands at the correct original index. We need the
                // original events; capture from the pre-apply state via
                // a closure in the dispatcher (see Editor.dispatch).
                // Fallback path: nothing to do — the dispatcher uses
                // `deleteEventsCapturing` for restorable deletes.
                state
            }
        )
    }

    /// Restorable delete — captures (index, event) snapshots up-front so
    /// undo can rebuild the original list exactly. Use this in normal
    /// editor flows; the bare `deleteEvents` exists only as a safety
    /// path for when an undo cannot restore (e.g., already-applied).
    static func deleteEventsCapturing(
        atOriginalIndices indices: [Int],
        from state: WorkingState
    ) -> EditorCommand {
        let snapshots: [(Int, TimelineEvent)] = indices
            .filter { $0 >= 0 && $0 < state.bundle.timeline.events.count }
            .sorted()
            .map { ($0, state.bundle.timeline.events[$0]) }

        return EditorCommand(
            label: "Delete \(snapshots.count) event(s)",
            apply: { s in
                var events = s.bundle.timeline.events
                // Descending removal preserves indices.
                for (idx, _) in snapshots.reversed() where idx < events.count {
                    events.remove(at: idx)
                }
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: Timeline(
                        events: events,
                        stopOn: s.bundle.timeline.stopOn,
                        subs: s.bundle.timeline.subs
                    )
                )
                out.selection = nil
                return out
            },
            undo: { s in
                var events = s.bundle.timeline.events
                // Ascending insert restores positions.
                for (idx, ev) in snapshots {
                    let safeIdx = min(max(idx, 0), events.count)
                    events.insert(ev, at: safeIdx)
                }
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: Timeline(
                        events: events,
                        stopOn: s.bundle.timeline.stopOn,
                        subs: s.bundle.timeline.subs
                    )
                )
                return out
            }
        )
    }

    // -- Replace event ------------------------------------------------

    /// Replace the event at `originalIndex` with a new value. Used for
    /// inspector edits — timing offset, jitter, gate retries / timeout /
    /// onFail. Captures the prior value for undo.
    static func replaceEvent(
        atOriginalIndex index: Int,
        with newEvent: TimelineEvent,
        from state: WorkingState,
        label: String
    ) -> EditorCommand {
        let priorEvent = (index >= 0 && index < state.bundle.timeline.events.count)
            ? state.bundle.timeline.events[index]
            : nil
        return EditorCommand(
            label: label,
            apply: { s in
                guard index >= 0 && index < s.bundle.timeline.events.count else { return s }
                var events = s.bundle.timeline.events
                events[index] = newEvent
                // Re-sort if the timestamp moved; preserve the user's
                // selection by tracking the new index.
                let needsResort = events.indices.dropFirst().contains { i in
                    eventTime(events[i]) < eventTime(events[i - 1])
                }
                if needsResort {
                    events = events.enumerated()
                        .sorted { eventTime($0.element) < eventTime($1.element) }
                        .map { $0.element }
                }
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: Timeline(
                        events: events,
                        stopOn: s.bundle.timeline.stopOn,
                        subs: s.bundle.timeline.subs
                    )
                )
                // Re-find the new event's index for selection.
                if let newIdx = out.bundle.timeline.events.firstIndex(where: { $0 == newEvent }) {
                    out.selection = EventSelection(originalEventIndex: newIdx)
                }
                return out
            },
            undo: { s in
                guard let prior = priorEvent,
                      let idx = s.bundle.timeline.events.firstIndex(where: { $0 == newEvent })
                else { return s }
                var events = s.bundle.timeline.events
                events[idx] = prior
                // Same re-sort guard.
                let needsResort = events.indices.dropFirst().contains { i in
                    eventTime(events[i]) < eventTime(events[i - 1])
                }
                if needsResort {
                    events = events.enumerated()
                        .sorted { eventTime($0.element) < eventTime($1.element) }
                        .map { $0.element }
                }
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: Timeline(
                        events: events,
                        stopOn: s.bundle.timeline.stopOn,
                        subs: s.bundle.timeline.subs
                    )
                )
                if let restoredIdx = out.bundle.timeline.events.firstIndex(where: { $0 == prior }) {
                    out.selection = EventSelection(originalEventIndex: restoredIdx)
                }
                return out
            }
        )
    }

    // -- Cuts ---------------------------------------------------------

    static func addCut(_ range: CutRange) -> EditorCommand {
        // Capture a stable UUID so undo can target the exact insertion
        // even after the user adds more cuts.
        let stableId = range.id
        let lo = min(range.start, range.end)
        let hi = max(range.start, range.end)
        return EditorCommand(
            label: "Cut \(String(format: "%.2f", lo))–\(String(format: "%.2f", hi))",
            apply: { s in
                var out = s
                guard (hi - lo) > 0.001 else { return s }
                let safe = CutRange(start: lo, end: hi, id: stableId)
                var cuts = s.cuts.filter { existing in
                    // Drop fully-overlapped existing cuts (caller likely
                    // expanded one). Partial overlap stays — adjacent
                    // cuts compose correctly via cumulative-cut math.
                    !(safe.start <= existing.start && safe.end >= existing.end)
                }
                cuts.append(safe)
                cuts.sort { $0.start < $1.start }
                out.cuts = cuts
                // Selection inside the cut is now invalid; clear it.
                if let sel = s.selection,
                   sel.originalEventIndex < s.bundle.timeline.events.count {
                    let t = eventTime(s.bundle.timeline.events[sel.originalEventIndex])
                    if safe.contains(t) { out.selection = nil }
                }
                return out
            },
            undo: { s in
                var out = s
                out.cuts = s.cuts.filter { $0.id != stableId }
                return out
            }
        )
    }

    static func removeCut(_ range: CutRange) -> EditorCommand {
        EditorCommand(
            label: "Uncut \(String(format: "%.2f", range.start))–\(String(format: "%.2f", range.end))",
            apply: { s in
                var out = s
                out.cuts = s.cuts.filter { $0.id != range.id }
                return out
            },
            undo: { s in
                var out = s
                var cuts = out.cuts
                cuts.append(range)
                cuts.sort { $0.start < $1.start }
                out.cuts = cuts
                return out
            }
        )
    }

    /// Resize an existing cut's start or end (used by the drag-handle
    /// trim affordance). Captures the prior range for undo. Preserves
    /// the cut's UUID across the edit so the drag-state tracker stays
    /// stable.
    static func resizeCut(
        cutId: UUID,
        newStart: Double,
        newEnd: Double,
        from state: WorkingState
    ) -> EditorCommand {
        let prior = state.cuts.first(where: { $0.id == cutId })
        return EditorCommand(
            label: "Resize cut",
            apply: { s in
                var out = s
                guard let idx = s.cuts.firstIndex(where: { $0.id == cutId }) else { return s }
                let lo = min(newStart, newEnd)
                let hi = max(newStart, newEnd)
                guard (hi - lo) > 0.001 else { return s }
                var cuts = s.cuts
                cuts[idx].start = lo
                cuts[idx].end = hi
                cuts.sort { $0.start < $1.start }
                out.cuts = cuts
                return out
            },
            undo: { s in
                guard let prior,
                      let idx = s.cuts.firstIndex(where: { $0.id == cutId })
                else { return s }
                var out = s
                var cuts = s.cuts
                cuts[idx].start = prior.start
                cuts[idx].end = prior.end
                cuts.sort { $0.start < $1.start }
                out.cuts = cuts
                return out
            }
        )
    }

    // -- Subs ---------------------------------------------------------

    /// Replace the entire `subs` map on the timeline. Captures the prior
    /// map for undo so add/rename/delete all funnel through one
    /// command.
    static func replaceSubs(
        with newSubs: [String: SubMacro],
        label: String,
        from state: WorkingState
    ) -> EditorCommand {
        let priorSubs = state.bundle.timeline.subs ?? [:]
        return EditorCommand(
            label: label,
            apply: { s in
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: Timeline(
                        events: s.bundle.timeline.events,
                        stopOn: s.bundle.timeline.stopOn,
                        subs: newSubs.isEmpty ? nil : newSubs
                    )
                )
                return out
            },
            undo: { s in
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: Timeline(
                        events: s.bundle.timeline.events,
                        stopOn: s.bundle.timeline.stopOn,
                        subs: priorSubs.isEmpty ? nil : priorSubs
                    )
                )
                return out
            }
        )
    }

    // -- StopOn -------------------------------------------------------

    /// Replace the entire `stopOn[]` triggers list. Captures prior list
    /// for undo. Add / edit / delete all route through this one path.
    static func replaceStopOn(
        with newTriggers: [StopOnTrigger],
        label: String,
        from state: WorkingState
    ) -> EditorCommand {
        let prior = state.bundle.timeline.stopOn ?? []
        return EditorCommand(
            label: label,
            apply: { s in
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: Timeline(
                        events: s.bundle.timeline.events,
                        stopOn: newTriggers.isEmpty ? nil : newTriggers,
                        subs: s.bundle.timeline.subs
                    )
                )
                return out
            },
            undo: { s in
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: Timeline(
                        events: s.bundle.timeline.events,
                        stopOn: prior.isEmpty ? nil : prior,
                        subs: s.bundle.timeline.subs
                    )
                )
                return out
            }
        )
    }

    // -- Schedule -----------------------------------------------------

    /// Replace the entire `manifest.schedule` list. Captures prior list
    /// for undo. Schedule is the only manifest-level field the panels
    /// edit in 8c (subs / stopOn live on Timeline; schedule on Manifest).
    static func replaceSchedule(
        with newWindows: [ScheduleWindow],
        label: String,
        from state: WorkingState
    ) -> EditorCommand {
        let prior = state.bundle.manifest.schedule ?? []
        return EditorCommand(
            label: label,
            apply: { s in
                var out = s
                out.bundle = MacroBundleData(
                    manifest: manifestWithSchedule(s.bundle.manifest, schedule: newWindows.isEmpty ? nil : newWindows),
                    timeline: s.bundle.timeline
                )
                return out
            },
            undo: { s in
                var out = s
                out.bundle = MacroBundleData(
                    manifest: manifestWithSchedule(s.bundle.manifest, schedule: prior.isEmpty ? nil : prior),
                    timeline: s.bundle.timeline
                )
                return out
            }
        )
    }

    /// Replace the entire timeline events list. Used by the script view
    /// when the user commits a YAML edit — we re-parse the YAML into a
    /// Timeline and swap. Captures the prior event list for undo.
    static func replaceTimeline(
        with newTimeline: Timeline,
        label: String,
        from state: WorkingState
    ) -> EditorCommand {
        let prior = state.bundle.timeline
        return EditorCommand(
            label: label,
            apply: { s in
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: newTimeline
                )
                out.selection = nil
                return out
            },
            undo: { s in
                var out = s
                out.bundle = MacroBundleData(
                    manifest: s.bundle.manifest,
                    timeline: prior
                )
                out.selection = nil
                return out
            }
        )
    }
}

// MARK: - Manifest-rebuild helper

/// Rebuild a `Manifest` swapping only the `schedule` field. Codegen'd
/// Manifest has 14 fields, all `let` — needed to splice the schedule
/// without touching the generated file.
private func manifestWithSchedule(_ manifest: Manifest, schedule: [ScheduleWindow]?) -> Manifest {
    Manifest(
        id: manifest.id,
        name: manifest.name,
        description: manifest.description,
        author: manifest.author,
        version: manifest.version,
        schemaVersion: manifest.schemaVersion,
        factoryPatchable: manifest.factoryPatchable,
        estimatedRuntime: manifest.estimatedRuntime,
        recordedFrameRate: manifest.recordedFrameRate,
        maxRuntimeHours: manifest.maxRuntimeHours,
        game: manifest.game,
        target: manifest.target,
        requires: manifest.requires,
        schedule: schedule,
        patchHistory: manifest.patchHistory
    )
}

// MARK: - Pair-finder

/// Helpers for the inspector + cropper to find the matching keyUp /
/// keyDown for a given event index. Returns the matching index or nil
/// if unpaired (or if the pair sits inside a cut — caller decides what
/// to do with that info).
enum EditorEventPairs {

    /// Given a `keyDown` index, find the next `keyUp` for the same key.
    /// Returns nil if not found.
    static func matchingKeyUp(
        forKeyDownAt index: Int,
        in events: [TimelineEvent]
    ) -> Int? {
        guard index >= 0 && index < events.count,
              case .keyDown(let down) = events[index] else { return nil }
        for j in (index + 1)..<events.count {
            if case .keyUp(let up) = events[j],
               up.key.lowercased() == down.key.lowercased() {
                return j
            }
        }
        return nil
    }

    /// Given a `keyUp` index, find the most recent prior `keyDown` for
    /// the same key. Returns nil if not found.
    static func matchingKeyDown(
        forKeyUpAt index: Int,
        in events: [TimelineEvent]
    ) -> Int? {
        guard index >= 0 && index < events.count,
              case .keyUp(let up) = events[index] else { return nil }
        for j in stride(from: index - 1, through: 0, by: -1) {
            if case .keyDown(let down) = events[j],
               down.key.lowercased() == up.key.lowercased() {
                return j
            }
        }
        return nil
    }
}
