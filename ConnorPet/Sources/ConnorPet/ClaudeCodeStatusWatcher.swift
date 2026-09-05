import Darwin
import Foundation

/// Polls Claude Code's own on-disk status for live agent activity and
/// republishes the aggregate pet animation whenever it changes. Mirrors
/// `OrcaStatusWatcher`'s shape so the menu-bar source picker can swap between
/// the two transparently.
///
/// Two sources are merged every poll, but with a strict hierarchy — the
/// session file is authoritative, the hook file is only an overlay:
///
/// 1. `~/.claude/sessions/<pid>.json` — one file per running CLI process
///    (the same files backing `claude agents`/`claude agents --json`).
///    Confirmed live fields (v2.1.197): `sessionId`, `cwd`, `name`, and a
///    `status` that Claude Code keeps *level-triggered* — always the current
///    truth: "busy" while a turn is in flight, "waiting" (with `waitingFor`,
///    e.g. "permission prompt") while blocked on the user, "idle" between
///    turns. This alone covers working/blocked/idle, so it — not the hooks —
///    is the source of truth for those three. Because it's PID-keyed and we
///    gate on `kill(pid, 0)`, a dead session can never linger as a ghost.
///
/// 2. `~/.claude/pet-status.json` — written by our own Claude Code hooks
///    (`scripts/pet_hook_status.py`, wired into `Stop`/`SessionEnd` in the
///    user's `~/.claude/settings.json` — see README "Claude Code 훅으로
///    헤롱헤롱/실패까지 보기"). Optional, and now used *only* for the two states
///    the session file cannot express: "done" (턴 종료, 리뷰 대기 → 하트) and
///    "failed" (마지막 툴이 에러 → 실패). Shaped like Orca's last-status.json,
///    so it reuses `parseAgentStatusEntries` unchanged.
///
/// Merge rule (see `poll()`): the session file decides working/blocked/idle;
/// the hook file may only *upgrade* an otherwise-idle session to done/failed.
/// A stale hook entry can therefore never mask a live session — that hook-wins
/// inversion was the old "frozen on 얼음 mid-session" bug.
final class ClaudeCodeStatusWatcher: AgentStatusWatching {
    private let sessionsDir: URL
    private let hookStatusFileURL: URL
    private let projectsDir: URL
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastFingerprint: [String: Date] = [:]
    private var acknowledgedAtMs: Double = 0

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

        var entries: [AgentStatusEntry] = []
        for (sessionId, session) in sessionsById {
            guard session.alive else { continue }
            let label = "claude-code:\(session.name ?? sessionId)"
            let transcriptPath = transcriptPath(forSessionId: sessionId)

            // The session file is authoritative for working/blocked/idle (it's
            // live and level-triggered). The hook file may only *upgrade* an
            // otherwise-idle session to the two states it alone knows about —
            // done (리뷰 대기) and failed — using the hook's own timestamp so
            // decayStaleStates ages them from when the hook fired. It can never
            // force blocked/working, so a stale hook can't freeze a live pet.
            var state = session.busyIdleState
            var updatedAt = session.updatedAt
            if session.busyIdleState == "idle",
               let hookEntry = hookEntriesById[sessionId],
               hookEntry.state == "done" || hookEntry.state == "failed" {
                state = hookEntry.state
                updatedAt = hookEntry.updatedAt
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
