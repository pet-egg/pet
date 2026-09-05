import Darwin
import Foundation

/// Polls Claude Code's own on-disk status for live agent activity and
/// republishes the aggregate pet animation whenever it changes. Mirrors
/// `OrcaStatusWatcher`'s shape so the menu-bar source picker can swap between
/// the two transparently.
///
/// **No hook is required** — the session file plus a little edge-detection give
/// us every state (running/waiting/idle/done/failed). The hook file, when
/// present, is a strictly optional overlay. Two sources are merged every poll,
/// with the session file authoritative:
///
/// 1. `~/.claude/sessions/<pid>.json` — one file per running CLI process
///    (the same files backing `claude agents`/`claude agents --json`).
///    Confirmed live fields (v2.1.197): `sessionId`, `cwd`, `name`, and a
///    `status` that Claude Code keeps *level-triggered* — always the current
///    truth: "busy" while a turn is in flight, "waiting" (with `waitingFor`,
///    e.g. "permission prompt") while blocked on the user, "idle" between
///    turns. This directly covers working/blocked/idle. We additionally watch
///    each session's busy→idle transition (a turn ending — the same edge the
///    Stop hook fires on) and mint "done", upgraded to "failed" when the
///    transcript's last tool result is an error (`lastToolErrored`, ported
///    from the hook). So done/failed are derived here too — no hook needed.
///    Because it's PID-keyed and we gate on `kill(pid, 0)`, a dead session can
///    never linger as a ghost.
///
/// 2. `~/.claude/pet-status.json` — written by our own Claude Code hooks
///    (`scripts/pet_hook_status.py`, wired into `Stop`/`SessionEnd` in the
///    user's `~/.claude/settings.json` — see README "Claude Code 훅으로
///    헤롱헤롱/실패까지 보기"). Purely optional now that done/failed are derived
///    above; its only remaining edge is surviving an app restart (a turn that
///    ended while the app was closed, so we never saw the live transition).
///    Shaped like Orca's last-status.json, so it reuses
///    `parseAgentStatusEntries` unchanged.
///
/// Merge rule (see `poll()`): the session file decides working/blocked/idle;
/// an otherwise-idle session is *upgraded* to done/failed, preferring the hook
/// entry when installed, else our own edge-detected one. An overlay can never
/// force blocked/working, so a stale one can never mask a live session — that
/// hook-wins inversion was the old "frozen on 얼음 mid-session" bug.
final class ClaudeCodeStatusWatcher: AgentStatusWatching {
    private let sessionsDir: URL
    private let hookStatusFileURL: URL
    private let projectsDir: URL
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastFingerprint: [String: Date] = [:]
    private var acknowledgedAtMs: Double = 0

    // Per-session tracking so we can detect the busy→idle (Stop) edge ourselves
    // and synthesize done/failed with no hook installed — see the switch in
    // `poll()`. `lastBusyIdleBySession` remembers each session's prior status;
    // `completionBySession` holds the done/failed we minted at its last Stop
    // (it must outlive the edge poll, since the session stays idle afterward).
    // Both are pruned each poll to sessions whose files still exist.
    private var lastBusyIdleBySession: [String: String] = [:]
    private var completionBySession: [String: (state: String, at: Double)] = [:]

    private let tokenReader = TranscriptTokenReader()
    // Resolved `<sessionId>.jsonl` paths, cached so we don't rescan the
    // projects tree every poll. A session's transcript never changes location.
    private var transcriptPathCache: [String: String] = [:]

    var onUpdate: ((AgentStateAnimationResult) -> Void)?

    init(pollInterval: TimeInterval = 0.25) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDir = home.appendingPathComponent(".claude/sessions")
        self.hookStatusFileURL = home.appendingPathComponent(".claude/pet-status.json")
        self.projectsDir = home.appendingPathComponent(".claude/projects")
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
        let sessionFiles = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ))?.filter { $0.pathExtension == "json" } ?? []

        // Why: skip re-parsing entirely when nothing changed since the last
        // poll — this runs 4x/sec for the app's whole lifetime. Covers both
        // the sessions directory and the (optional) hook status file, since
        // either can change independently.
        var fingerprint: [String: Date] = [:]
        for file in sessionFiles {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            fingerprint[file.lastPathComponent] = mtime ?? .distantPast
        }
        let hookAttrs = try? FileManager.default.attributesOfItem(atPath: hookStatusFileURL.path)
        fingerprint["pet-status.json"] = (hookAttrs?[.modificationDate] as? Date) ?? .distantPast
        // Also fold in the transcripts we already resolved on prior polls, so a
        // token count that grows mid-turn refreshes the XP bar even in the rare
        // window where the session file itself didn't change.
        for (sessionId, path) in transcriptPathCache {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            fingerprint["transcript:\(sessionId)"] = mtime ?? .distantPast
        }
        if fingerprint == lastFingerprint {
            return
        }
        lastFingerprint = fingerprint

        var sessionsById: [String: SessionInfo] = [:]
        for file in sessionFiles {
            guard let (sessionId, info) = parseSessionFile(at: file) else { continue }
            sessionsById[sessionId] = info
        }

        var hookEntriesById: [String: AgentStatusEntry] = [:]
        if let data = try? Data(contentsOf: hookStatusFileURL) {
            for entry in parseAgentStatusEntries(from: data) {
                hookEntriesById[entry.paneKey] = entry
            }
        }

        let now = Date().timeIntervalSince1970 * 1000
        var entries: [AgentStatusEntry] = []
        var seenSessionIds = Set<String>()
        for (sessionId, session) in sessionsById {
            seenSessionIds.insert(sessionId)
            guard session.alive else { continue }
            let label = "claude-code:\(session.name ?? sessionId)"
            let transcriptPath = transcriptPath(forSessionId: sessionId)

            // Detect the busy→idle (Stop) edge ourselves so done/failed work
            // without any hook. This is exactly what the Stop hook keys off: a
            // turn ending. We decide done vs failed the same way the hook does
            // — by inspecting the transcript tail for a last tool that errored
            // (`last_tool_errored` in pet_hook_status.py, ported below).
            let prev = lastBusyIdleBySession[sessionId]
            switch session.busyIdleState {
            case "working", "blocked":
                // Active again — cancel any pending completion for this session.
                completionBySession[sessionId] = nil
            case "idle" where prev == "working":
                let doneState = lastToolErrored(transcriptPath: transcriptPath) ? "failed" : "done"
                completionBySession[sessionId] = (state: doneState, at: now)
            default:
                break
            }
            lastBusyIdleBySession[sessionId] = session.busyIdleState

            // The session file is authoritative for working/blocked/idle (it's
            // live and level-triggered). For an *idle* session we overlay a
            // completion state (리뷰 대기 하트 / 실패): the hook file wins when
            // installed (it survives app restarts and cross-checks the same
            // transcript), otherwise our own edge-detected one. Either way it's
            // stamped with when the turn ended, so decayStaleStates ages it and
            // suppressAcknowledgedDone can hover-dismiss it. A completion can
            // never force blocked/working, so nothing here can freeze a live pet.
            var state = session.busyIdleState
            var updatedAt = session.updatedAt
            if session.busyIdleState == "idle" {
                if let hookEntry = hookEntriesById[sessionId],
                   hookEntry.state == "done" || hookEntry.state == "failed" {
                    state = hookEntry.state
                    updatedAt = hookEntry.updatedAt
                } else if let completion = completionBySession[sessionId] {
                    state = completion.state
                    updatedAt = completion.at
                }
            }

            entries.append(AgentStatusEntry(
                paneKey: label,
                state: state,
                workingMode: nil,
                worktreeId: session.cwd,
                updatedAt: updatedAt,
                transcriptPath: transcriptPath
            ))
        }
        // Hook entries for sessions with no live session file are deliberately
        // dropped: a hook state we can't tie to a running process is unreliable
        // (SessionEnd→remove doesn't fire on crash/kill), and appending stale
        // "blocked" ones as-is was exactly the old frozen-ice bug.

        // Prune per-session tracking for sessions whose files are gone, so the
        // two dictionaries can't grow without bound over a long-lived app.
        lastBusyIdleBySession = lastBusyIdleBySession.filter { seenSessionIds.contains($0.key) }
        completionBySession = completionBySession.filter { seenSessionIds.contains($0.key) }

        publish(entries: entries)
    }

    /// Finds `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` without having to
    /// reproduce Claude Code's cwd→slug transformation: the sessionId is unique,
    /// so we just look for that filename under any project subdir. Cached once
    /// resolved (a session's transcript never moves).
    private func transcriptPath(forSessionId sessionId: String) -> String? {
        if let cached = transcriptPathCache[sessionId] { return cached }
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return nil }
        let filename = "\(sessionId).jsonl"
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                transcriptPathCache[sessionId] = candidate.path
                return candidate.path
            }
        }
        return nil
    }

    // How much of the transcript's tail to inspect for a failed tool. Kept in
    // lockstep with pet_hook_status.py's constants so the in-app path and the
    // hook agree on what counts as "failed". Transcripts reach tens of MB, so
    // this is seeked from the end rather than read from the top.
    private static let transcriptTailBytes: UInt64 = 256 * 1024
    private static let transcriptTailLines = 80

    /// True when the most recent tool result in the transcript is an error.
    /// Ported from `last_tool_errored` in pet_hook_status.py — called only at the
    /// busy→idle edge (once per turn), so it never runs on the hot poll path.
    ///
    /// Only the *last* tool result counts: a tool that failed and was then
    /// retried successfully isn't a failure worth showing; a turn whose final
    /// tool errored is. The transcript is read (not the session file) because
    /// that's the only place the error lands — matching the hook's reasoning.
    private func lastToolErrored(transcriptPath: String?) -> Bool {
        guard let path = transcriptPath,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let data: Data
        do {
            let end = try handle.seekToEnd()
            let start = end > Self.transcriptTailBytes ? end - Self.transcriptTailBytes : 0
            try handle.seek(toOffset: start)
            data = handle.readDataToEndOfFile()
        } catch {
            return false
        }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        // The first line after an arbitrary seek is usually a partial record;
        // dropping it (matching the hook's `[1:]`) is why we require >1 line.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > 1 else { return false }
        lines.removeFirst()
        if lines.count > Self.transcriptTailLines {
            lines = Array(lines.suffix(Self.transcriptTailLines))
        }
        for raw in lines.reversed() {
            guard let lineData = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content.reversed() where (block["type"] as? String) == "tool_result" {
                return (block["is_error"] as? Bool) ?? false
            }
        }
        return false
    }

    private struct SessionInfo {
        let name: String?
        let cwd: String?
        let busyIdleState: String
        let updatedAt: Double
        let alive: Bool
    }

    private func parseSessionFile(at fileURL: URL) -> (sessionId: String, info: SessionInfo)? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let root = rawObject as? [String: Any],
            let sessionId = root["sessionId"] as? String,
            let pid = (root["pid"] as? NSNumber)?.int32Value
        else { return nil }

        // Skip sessions whose process has already exited — Claude Code itself
        // lazily garbage-collects these files, so a stale one can briefly
        // linger after the CLI quits without cleaning up.
        let alive = kill(pid_t(pid), 0) == 0

        // Claude Code's own live status (v2.1.197): "busy" during a turn,
        // "waiting" while blocked on the user (with `waitingFor`, e.g.
        // "permission prompt"), "idle" between turns. Maps straight onto the
        // same working/blocked/idle vocabulary Orca uses. `waitingFor` isn't
        // needed for the mapping — any "waiting" is an actionable 얼음 — but a
        // richer state could key off it later.
        let status = root["status"] as? String
        let busyIdleState: String
        switch status {
        case "busy":    busyIdleState = "working"
        case "waiting": busyIdleState = "blocked"
        default:        busyIdleState = "idle"
        }

        let updatedAt = (root["statusUpdatedAt"] as? NSNumber)?.doubleValue
            ?? (root["updatedAt"] as? NSNumber)?.doubleValue
            ?? (Date().timeIntervalSince1970 * 1000)

        return (sessionId, SessionInfo(
            name: root["name"] as? String,
            cwd: root["cwd"] as? String,
            busyIdleState: busyIdleState,
            updatedAt: updatedAt,
            alive: alive
        ))
    }

    private func publish(entries: [AgentStatusEntry]) {
        let now = Date().timeIntervalSince1970 * 1000
        let decayed = decayStaleStates(entries, now: now)
        let suppressed = suppressAcknowledgedDone(decayed, acknowledgedAtMs: acknowledgedAtMs)
        var result = agentStateAnimation(entries: suppressed, retainedCount: 0, now: now)
        result.gainedTokens = tokenReader.accrued(for: entries)
        if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
            FileHandle.standardError.write("[connor-pet] claude-code: \(entries.count) session(s) -> \(result.animation), +\(Int(result.gainedTokens)) tokens\n".data(using: .utf8)!)
            for line in result.trace { FileHandle.standardError.write("  \(line.line)\n".data(using: .utf8)!) }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
    }
}
