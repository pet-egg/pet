import Foundation

/// Parses the subset of Orca's persisted `last-status.json` entry shape that
/// we need, using loose JSONSerialization dictionaries rather than a strict
/// Codable struct. Also reused by `ClaudeCodeStatusWatcher` for
/// `~/.claude/pet-status.json`, which our own hooks write in this same
/// shape (see `scripts/pet_hook_status.py`).
///
/// Why: real on-disk entries are NOT uniform. An entry that came from a
/// "SubagentStop" hook event (observed live) nests `state`/`prompt`/`agentType`
/// under a `payload` sub-object, while worktreeId/receivedAt/etc. stay at the
/// top level — other entries put `state` directly at the top level. A strict
/// Codable struct requiring a top-level `state` would fail to decode the
/// *entire file* the instant one entry used the other shape (JSONDecoder has
/// no per-entry recovery), silently zeroing out every pane's status. Parsing
/// loosely and checking both locations per-entry is what actually survives
/// Orca's real output.
func parseAgentStatusEntries(from data: Data) -> [AgentStatusEntry] {
    guard let rawObject = try? JSONSerialization.jsonObject(with: data) else { return [] }
    guard let root = rawObject as? [String: Any] else { return [] }
    guard let entriesObj = root["entries"] as? [String: Any] else { return [] }

    var result: [AgentStatusEntry] = []
    for (paneKey, value) in entriesObj {
        guard let entry = value as? [String: Any] else { continue }
        let payload = entry["payload"] as? [String: Any]
        // `state` (and its close relatives) may live at the top level or
        // nested under `payload`, depending on which hook event produced it.
        let stateSource = payload ?? entry
        guard let state = stateSource["state"] as? String else { continue }
        let workingMode = stateSource["workingMode"] as? String
        let worktreeId = entry["worktreeId"] as? String
        let receivedAt = (entry["receivedAt"] as? NSNumber)?.doubleValue
        // Orca hands us the transcript path outright, so token usage needs no
        // sessionId→path guessing on this source (unlike ClaudeCodeStatusWatcher).
        let transcriptPath = (entry["providerSession"] as? [String: Any])?["transcriptPath"] as? String

        result.append(AgentStatusEntry(
            paneKey: paneKey,
            state: state,
            workingMode: workingMode,
            worktreeId: worktreeId,
            updatedAt: receivedAt ?? (Date().timeIntervalSince1970 * 1000),
            transcriptPath: transcriptPath
        ))
    }
    return result
}

/// Polls Orca's on-disk agent-status file — the exact file Orca itself uses
/// to restore state across restarts (`src/main/agent-hooks/server/server-persistence.ts`)
/// — and republishes the aggregate pet animation whenever it changes.
///
/// Orca debounces writes to this file at 250ms, so a 1s poll is comfortably
/// within its real update cadence without needing FSEvents.
final class OrcaStatusWatcher: AgentStatusWatching {
    private let fileURL: URL
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastModifiedAt: Date?

    /// Agent panes whose worktree/pane closed after finishing but haven't
    /// been reviewed yet (Orca's `retainedAgentsByPaneKey`). We can't observe
    /// that in-memory renderer state from outside the app, so this is exposed
    /// for callers that want to simulate/inject it; defaults to 0.
    var retainedCount: Int = 0

    // ms epoch of the last acknowledgeDone() call — see suppressAcknowledgedDone.
    private var acknowledgedAtMs: Double = 0

    private let tokenReader = TranscriptTokenReader()

    var onUpdate: ((AgentStateAnimationResult) -> Void)?

    init(pollInterval: TimeInterval = 1.0) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = appSupport.appendingPathComponent("Orca/agent-hooks/last-status.json")
        self.pollInterval = pollInterval
    }

    func start() {
        poll()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func acknowledgeDone() {
        acknowledgedAtMs = Date().timeIntervalSince1970 * 1000
    }

    private func poll() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modifiedAt = attrs?[.modificationDate] as? Date

        // Why: skip the JSON parse entirely when the file hasn't changed since
        // the last poll — this runs every second for the app's whole lifetime.
        if let modifiedAt = modifiedAt, let lastModifiedAt = lastModifiedAt, modifiedAt <= lastModifiedAt {
            return
        }
        lastModifiedAt = modifiedAt

        guard let data = try? Data(contentsOf: fileURL) else {
            // Orca not installed, never launched, or no agent activity yet —
            // treat as "no entries" rather than crashing/hanging.
            publish(entries: [])
            return
        }
        publish(entries: parseAgentStatusEntries(from: data))
    }

    private func publish(entries: [AgentStatusEntry]) {
        let now = Date().timeIntervalSince1970 * 1000
        let decayed = decayStaleStates(entries, now: now)
        let suppressed = suppressAcknowledgedDone(decayed, acknowledgedAtMs: acknowledgedAtMs)
        var result = agentStateAnimation(entries: suppressed, retainedCount: retainedCount, now: now)
        result.gainedTokens = tokenReader.accrued(for: entries)
        if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
            FileHandle.standardError.write("[connor-pet] \(entries.count) entr(y/ies) -> \(result.animation), +\(Int(result.gainedTokens)) tokens\n".data(using: .utf8)!)
            for line in result.trace { FileHandle.standardError.write("  \(line.line)\n".data(using: .utf8)!) }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
    }
}
