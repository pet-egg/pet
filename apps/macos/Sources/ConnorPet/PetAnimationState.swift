import Foundation

/// Mirrors Orca's `pet-agent-state.ts` PetAnimationName union.
enum PetAnimationName: String, CaseIterable {
    case idle
    case running
    case waiting
    case review
    case jumping
    case waving
    case failed
    /// 속성기. 매니페스트에 그 행이 없는 펫에서는 메뉴가 비활성된다.
    /// 한 펫에 하나만 있으므로 단축키를 공유해도 부딪히지 않는다.
    case fireBreath = "fire-breath"
    case waterGun = "water-gun"
    case runningRight = "running-right"
    case runningLeft = "running-left"

    /// 속성기인가 — 한 펫에 최대 하나뿐이고, 브리핑 체크포인트를 찍는다.
    var isSkill: Bool {
        skillNoun != nil
    }

    /// 브리핑 문구에 쓰는 한 글자 이름. "불 뿜은 뒤로…" / "물 뿜은 뒤로…" 처럼
    /// 지금 그 펫이 쓴 기술에 맞춰 말하기 위한 것이다. 속성기가 아니면 nil.
    var skillNoun: String? {
        switch self {
        case .fireBreath: return "불"
        case .waterGun:   return "물"
        default:          return nil
        }
    }

    /// 우클릭 메뉴에서 고정 재생이 아니라 **한 번 실행되는 동작**인 모션과, 메뉴가
    /// 열린 상태에서 누를 단축키. 나머지는 골라 두면 그 자세로 고정된다.
    var menuShortcut: String? {
        switch self {
        case .fireBreath, .waterGun: return "a"
        case .waving:     return "s"
        default:          return nil
        }
    }

    /// Korean label for the right-click motion menu.
    ///
    /// 이름은 상태가 아니라 **눈에 보이는 동작**을 가리킨다. running 계열 세 개는
    /// Orca 펫 포맷에서 물려받은 이름이라 rawValue 는 그대로 두지만, 실제로는
    /// 달리는 그림이 아니다 — running 은 제자리에서 위아래로 흔들리는 서 있는
    /// 자세이고, running-left/right 는 좌우를 바라보는 방향 전환이다.
    var koreanLabel: String {
        switch self {
        case .idle:         return "잠듦 (Zzz)"
        case .running:      return "서있기"
        case .waiting:      return "얼음"
        case .review:       return "하트"
        case .jumping:      return "점프"
        case .waving:       return "말하기 — 클로드 세션 진행상황"
        case .failed:       return "실패"
        case .fireBreath:   return "불뿜기 — 여기까지 정리, 이후 작업만 브리핑"
        case .waterGun:     return "물뿜기 — 여기까지 정리, 이후 작업만 브리핑"
        case .runningRight: return "오른쪽보기"
        case .runningLeft:  return "왼쪽보기"
        }
    }
}

enum PetDragDirection {
    case right
    case left
}

/// Common interface for the two interchangeable status sources the menu-bar
/// picker can select between (Orca's last-status.json vs. Claude Code's own
/// session files) — AppDelegate holds exactly one active instance at a time.
protocol AgentStatusWatching: AnyObject {
    var onUpdate: ((AgentStateAnimationResult) -> Void)? { get set }
    func start()
    func stop()
    /// Called when the user notices the pet (currently: on hover) — suppresses
    /// any "done"/review state observed *before* this call until a newer one
    /// arrives, so review doesn't linger forever once you've actually seen it.
    func acknowledgeDone()
}

/// One entry read from `last-status.json`'s `entries` map — a single agent pane,
/// which may belong to any Orca project/worktree currently open.
struct AgentStatusEntry {
    let paneKey: String
    let state: String // "working" | "blocked" | "waiting" | "done" | "failed"
    let workingMode: String?
    let worktreeId: String?
    let updatedAt: Double // ms epoch
    /// Path to this pane/session's Claude Code transcript JSONL, when known —
    /// the only on-disk source of token usage (see TranscriptTokenReader).
    /// Orca supplies it directly (`providerSession.transcriptPath`); the Claude
    /// Code source resolves it by globbing on sessionId. `var` with a default
    /// so existing call sites that don't set it keep compiling.
    var transcriptPath: String? = nil
}

/// Freshness gate, ported from `agent-status-types.ts` (`AGENT_STATUS_STALE_AFTER_MS`).
let agentStatusStaleAfterMs: Double = 30 * 60 * 1000

/// How long each transient state stays meaningful before it decays (see
/// `decayStaleStates`). These live here, not in the hook script, because a
/// hook only fires while a session is alive — once the last one exits nothing
/// writes the file again, so anything time-based has to be judged by the
/// reader. The watchers already poll, so they get this for free.
enum AgentStatusDecay {
    /// A failed tool is worth a glance, not a permanent mood.
    static let failedMs: Double = 30 * 1000
    /// "작업 끝" 이후 이만큼 지나면 잠든다 — 유휴 5분.
    static let doneMs: Double = 5 * 60 * 1000
    /// Normal work keeps firing hooks every few seconds; this much silence
    /// means the session is wedged or died without a SessionEnd, so stop
    /// showing it as busy.
    static let workingMs: Double = 15 * 60 * 1000
}

/// Ages transient states down a step, so the pet settles by itself instead of
/// holding whatever the last hook wrote forever.
///
///   failed  → done   (after 30s)
///   done    → idle   (after 5m)
///   working → idle   (after 15m)
///
/// Written as a pure transform over entries — same shape as
/// `suppressAcknowledgedDone` — so both status sources share it and it can be
/// reasoned about without a live file or a running session.
func decayStaleStates(_ entries: [AgentStatusEntry], now: Double) -> [AgentStatusEntry] {
    entries.map { entry in
        let age = now - entry.updatedAt
        let decayed: String
        switch entry.state {
        case "failed"  where age > AgentStatusDecay.failedMs + AgentStatusDecay.doneMs: decayed = "idle"
        case "failed"  where age > AgentStatusDecay.failedMs:                           decayed = "done"
        case "done"    where age > AgentStatusDecay.doneMs:                             decayed = "idle"
        case "working" where age > AgentStatusDecay.workingMs:                          decayed = "idle"
        default: return entry
        }
        return AgentStatusEntry(
            paneKey: entry.paneKey,
            state: decayed,
            workingMode: entry.workingMode,
            worktreeId: entry.worktreeId,
            updatedAt: entry.updatedAt
        )
    }
}

func isEntryFresh(_ entry: AgentStatusEntry, now: Double, staleAfterMs: Double = agentStatusStaleAfterMs) -> Bool {
    now - entry.updatedAt <= staleAfterMs
}

struct AgentStateAnimationTrace {
    let line: String
}

struct AgentStateAnimationResult {
    let animation: PetAnimationName
    let trace: [AgentStateAnimationTrace]
    /// Aggregate token usage across all live panes/sessions, filled in by each
    /// watcher's `publish` (0 when no transcript is readable). Drives the XP
    /// bar + evolution — see XPModel. Defaulted so `agentStateAnimation`'s
    /// return sites don't need to thread it through.
    /// 마지막 폴링 이후 새로 쌓인 토큰. 누적 합계가 아니라 증가분이다 —
    /// 경험치는 지금 화면에 있는 펫에게만 들어가므로 호출부가 직접 누적한다.
    var gainedTokens: Double = 0
}

/// Ported verbatim (in spirit) from `pet-agent-state.ts`'s `agentStateAnimation()`.
/// Scans every open agent pane across every project; the single most-urgent
/// state wins, short-circuiting the instant a blocked/waiting pane is found.
func agentStateAnimation(
    entries: [AgentStatusEntry],
    retainedCount: Int,
    now: Double,
    staleAfterMs: Double = agentStatusStaleAfterMs
) -> AgentStateAnimationResult {
    var trace: [AgentStateAnimationTrace] = []
    var hasWorking = false
    var hasDone = false
    var hasFailed = false

    for entry in entries {
        guard isEntryFresh(entry, now: now, staleAfterMs: staleAfterMs) else {
            trace.append(.init(line: "\(entry.paneKey): stale → skipped"))
            continue
        }
        if entry.state == "blocked" || entry.state == "waiting" {
            trace.append(.init(line: "\(entry.paneKey): \(entry.state) → top-priority rule, short-circuit"))
            return AgentStateAnimationResult(animation: .waiting, trace: trace)
        }
        // "failed" is not one of Orca's own states — it is an extension for the
        // Claude Code bridge, which reports a tool that came back with an error.
        // It ranks below waiting (which needs the user to act right now) but
        // above working, so a failure is not hidden by other panes still running.
        if entry.state == "failed" {
            hasFailed = true
            trace.append(.init(line: "\(entry.paneKey): failed → candidate"))
        } else if entry.state == "working", entry.workingMode != "monitoring" {
            hasWorking = true
            trace.append(.init(line: "\(entry.paneKey): working → candidate"))
        } else if entry.state == "done" {
            hasDone = true
            trace.append(.init(line: "\(entry.paneKey): done → candidate"))
        }
    }

    if hasFailed {
        return AgentStateAnimationResult(animation: .failed, trace: trace)
    }
    if hasWorking {
        return AgentStateAnimationResult(animation: .running, trace: trace)
    }
    if hasDone || retainedCount > 0 {
        return AgentStateAnimationResult(animation: .review, trace: trace)
    }
    return AgentStateAnimationResult(animation: .idle, trace: trace)
}

/// Downgrades "done" entries the user has already acknowledged (see
/// `AgentStatusWatching.acknowledgeDone()`) to "idle" so review doesn't
/// reappear on the next poll purely because the underlying source (Orca's
/// file, or our own hook-authored one) hasn't moved past "done" yet — it only
/// comes back once a *newer* done event lands (updatedAt > acknowledgedAtMs).
func suppressAcknowledgedDone(_ entries: [AgentStatusEntry], acknowledgedAtMs: Double) -> [AgentStatusEntry] {
    entries.map { entry in
        guard entry.state == "done", entry.updatedAt <= acknowledgedAtMs else { return entry }
        return AgentStatusEntry(
            paneKey: entry.paneKey,
            state: "idle",
            workingMode: entry.workingMode,
            worktreeId: entry.worktreeId,
            updatedAt: entry.updatedAt
        )
    }
}

/// Ported from `usePetPointerInteraction.ts` / `nextPetDragAnimation`.
func nextPetDragAnimation(current: PetDragDirection?, deltaX: CGFloat) -> (direction: PetDragDirection?, accepted: Bool) {
    if deltaX >= 4 { return (.right, true) }
    if deltaX <= -4 { return (.left, true) }
    return (current, false)
}
