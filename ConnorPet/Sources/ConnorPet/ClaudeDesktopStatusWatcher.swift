import AppKit
import ApplicationServices
import Foundation

/// Inputs to the Claude *desktop app* animation decision — deliberately a plain
/// value type so the mapping is unit-testable without any process/AX access.
struct ClaudeDesktopInput: Equatable {
    /// The Claude.app process is running at all.
    let running: Bool
    /// Claude.app is the frontmost (Dock-selected) app right now.
    let frontmost: Bool
    /// A response is actively streaming (a "Stop response" control is present in
    /// the accessibility tree).
    let generating: Bool
    /// A turn is paused waiting for the user to approve a tool/permission — the
    /// accessibility tree shows an approval card (an Allow *and* a Deny button).
    let awaitingApproval: Bool
    /// A completion notification arrived that the user hasn't acknowledged
    /// (by hovering the pet) yet.
    let donePending: Bool
}

/// Maps the Claude desktop app's observable state to a pet animation. Priority,
/// highest first — this is the whole behavioral contract, kept pure on purpose:
///
/// 1. not running            → 잠듬 (idle)          — nothing to react to
/// 2. awaiting approval      → 얼음 (waiting)        — paused, needs your Allow/Deny
/// 3. generating             → 달리기 (running)      — response streaming now
/// 4. done, unacknowledged   → 헤롱헤롱 (review)      — "go look, it finished"
/// 5. running, backgrounded  → 얼음 (waiting)        — left on ice, not looking
/// 6. running, frontmost/idle→ 잠듬 (idle)           — you're here, nothing doing
///
/// `awaitingApproval` outranks `generating` on purpose: the "Stop response"
/// button (our generating signal) stays visible while a turn is paused on an
/// approval card, so both read true at once — the approval is what the user has
/// to act on, so it wins. It also outranks `donePending` and the backgrounded
/// 얼음, and must win even when Claude is frontmost.
func claudeDesktopAnimation(_ input: ClaudeDesktopInput) -> PetAnimationName {
    guard input.running else { return .idle }
    if input.awaitingApproval { return .waiting }
    if input.generating { return .running }
    if input.donePending { return .review }
    if !input.frontmost { return .waiting }
    return .idle
}

/// Drives the pet from the Claude *desktop app* (not the CLI). Unlike the CLI,
/// the desktop app writes no per-turn status to disk (conversation state lives in
/// Electron LevelDB/IndexedDB, and it actively refuses to launch with a debugging
/// or network-override switch, so CDP/proxy inspection is out). The one external
/// surface that carries real, per-conversation status is the **Accessibility
/// tree** — Electron/Chromium only builds it for its web content once an external
/// process sets `AXManualAccessibility=true` on the app element (this is why an
/// unforced probe sees only native menus). Once forced, the streaming state shows
/// up as a "Stop response" button in the focused conversation window; it vanishes
/// the instant the turn completes. See `ClaudeAXProbe`.
///
/// - Signal 1 — "is it generating": presence of a stop-response control in the
///   AX tree. Its *falling edge* (control disappeared) doubles as our most
///   reliable "a turn just finished" signal → 헤롱헤롱. Needs the Accessibility
///   permission; without it we degrade to running/frontmost + notification only.
/// - Signal 2 — "did it finish": a new Claude notification in macOS's
///   Notification Center DB (`NotificationCenterDB`), which needs Full Disk
///   Access. The desktop app only posts these for longer/agentic work, so this is
///   a *confirming* done signal layered on top of the AX falling edge — either
///   one raises 헤롱헤롱.
///
/// "Done" (from either signal) latches until the user acknowledges it by
/// hovering the pet (`acknowledgeDone()`), or a safety timeout elapses, or a new
/// turn starts — mirroring the Claude Code watcher's review behavior.
final class ClaudeDesktopStatusWatcher: AgentStatusWatching {
    static let bundleID = "com.anthropic.claudefordesktop"

    private let pollInterval: TimeInterval
    private let notifCheckInterval: TimeInterval
    /// Keep 달리기 latched for this many polls after the last "generating" sample,
    /// so a brief gap in the stop-button (e.g. between thinking and streaming, or
    /// during a tool call) doesn't flicker the pet back to idle.
    private let busyStickyPolls: Int
    /// A generating stretch must last at least this many polls before its end
    /// counts as a finished turn — a cheap guard against a single spurious poll.
    private let minGeneratingPollsForDone: Int
    /// How long an AX-detected "done" stays latched if the user never hovers.
    private let reviewTimeout: TimeInterval

    private let probe = ClaudeAXProbe()
    private let notifDB = NotificationCenterDB()

    private var timer: Timer?
    private var busyLatch = 0
    private var wasGenerating = false
    private var generatingRun = 0
    private var pendingDoneFromAX = false
    private var pendingDoneDeadline: Date?
    private var loggedAXUnavailable = false

    // Notification bookkeeping (Cocoa-epoch seconds). `latest` is the newest
    // notification we've seen; `acknowledged` is the newest the user has
    // dismissed via hover. donePending == latest > acknowledged.
    private var latestNotifDate: Double = 0
    private var acknowledgedNotifDate: Double = 0
    private var notifBaselineSet = false
    private var notifCheckDeadline: Date = .distantPast
    private var loggedNotifUnavailable = false

    private var lastPublished: PetAnimationName?

    var onUpdate: ((AgentStateAnimationResult) -> Void)?

    init(
        pollInterval: TimeInterval = 0.5,
        notifCheckInterval: TimeInterval = 1.0,
        busyStickyPolls: Int = 3,
        minGeneratingPollsForDone: Int = 2,
        reviewTimeout: TimeInterval = 300
    ) {
        self.pollInterval = pollInterval
        self.notifCheckInterval = notifCheckInterval
        self.busyStickyPolls = busyStickyPolls
        self.minGeneratingPollsForDone = minGeneratingPollsForDone
        self.reviewTimeout = reviewTimeout
    }

    func start() {
        lastPublished = nil
        busyLatch = 0
        wasGenerating = false
        generatingRun = 0
        pendingDoneFromAX = false
        pendingDoneDeadline = nil
        // Ask for the Accessibility grant up front (shows the system prompt once
        // if not yet trusted). We keep running either way — see poll().
        probe.ensurePermissionPrompted()
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
        // Everything seen so far is now "seen" — donePending clears until a
        // strictly newer notification lands or a new turn finishes.
        acknowledgedNotifDate = max(acknowledgedNotifDate, latestNotifDate)
        pendingDoneFromAX = false
        pendingDoneDeadline = nil
    }

    private func poll() {
        let now = Date()

        let running = Self.isClaudeRunning()
        let frontmost = Self.isClaudeFrontmost()

        refreshNotificationsIfNeeded(now: now)

        // Only probe AX while Claude is alive. `nil` == couldn't tell (no
        // permission yet, or the web tree hasn't finished building) → treat as
        // "not generating" but don't fabricate a falling-edge done from it.
        let axSample = running ? probe.sample() : nil
        if running, axSample == nil { logAXUnavailableOnce() }
        let sampledGenerating = axSample?.generating ?? false
        let awaitingApproval = axSample?.awaitingApproval ?? false

        if sampledGenerating {
            busyLatch = busyStickyPolls
        } else if busyLatch > 0 {
            busyLatch -= 1
        }
        let generating = busyLatch > 0

        // Signal 1's falling edge = a turn just finished. Only count it if the
        // generating stretch was sustained, and let a fresh turn supersede a
        // stale pending-done. A pause *for approval* is not a finished turn, so
        // don't let that falling edge fabricate a done.
        if generating {
            generatingRun += 1
            pendingDoneFromAX = false
            pendingDoneDeadline = nil
        } else {
            if wasGenerating, generatingRun >= minGeneratingPollsForDone, !awaitingApproval {
                pendingDoneFromAX = true
                pendingDoneDeadline = now.addingTimeInterval(reviewTimeout)
            }
            generatingRun = 0
        }
        wasGenerating = generating
        if let deadline = pendingDoneDeadline, now >= deadline {
            pendingDoneFromAX = false
            pendingDoneDeadline = nil
        }

        // Done = either signal, cleared once acknowledged/expired above.
        let donePending = pendingDoneFromAX || (latestNotifDate > acknowledgedNotifDate)

        let input = ClaudeDesktopInput(
            running: running,
            frontmost: frontmost,
            generating: generating,
            awaitingApproval: awaitingApproval,
            donePending: donePending
        )
        publish(claudeDesktopAnimation(input), input: input)
    }

    private func refreshNotificationsIfNeeded(now: Date) {
        guard now >= notifCheckDeadline else { return }
        notifCheckDeadline = now.addingTimeInterval(notifCheckInterval)

        // Gate the baseline on *readability*, not on whether any notification
        // exists yet. An unreadable DB means no Full Disk Access, so we log once
        // and hold off — deliberately leaving the baseline unset so that if the
        // DB becomes readable later it baselines against whatever's actually
        // there. (A readable-but-empty DB must still baseline, at 0, so the very
        // first real completion notification fires 헤롱헤롱 instead of being
        // swallowed as the baseline.)
        guard let db = notifDB, db.isReadable else {
            logNotifUnavailableOnce()
            return
        }

        // May be nil when access is granted but Claude hasn't posted any
        // notification yet — that's a valid "baseline is none (0)" state.
        let latest = db.latestNotificationDate(bundleID: Self.bundleID)

        if !notifBaselineSet {
            // First readable poll: treat whatever's already there (possibly
            // nothing) as already-seen, so a days-old notification doesn't
            // trigger 헤롱헤롱 the moment we launch.
            notifBaselineSet = true
            acknowledgedNotifDate = latest ?? 0
        }
        if let latest { latestNotifDate = latest }
    }

    private func logAXUnavailableOnce() {
        guard !loggedAXUnavailable else { return }
        loggedAXUnavailable = true
        FileHandle.standardError.write(
            "[connor-pet] claude-desktop: Accessibility tree not readable — 생성 중 감지가 꺼집니다. macOS 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 ConnorPet을 켜 주세요(권한 부여 후 자동 반영).\n"
                .data(using: .utf8)!
        )
    }

    private func logNotifUnavailableOnce() {
        guard !loggedNotifUnavailable else { return }
        loggedNotifUnavailable = true
        FileHandle.standardError.write(
            "[connor-pet] claude-desktop: Notification Center DB not readable — falling back to AX-only done detection. For notification-based 헤롱헤롱, grant Full Disk Access via the menu bar item \"전체 디스크 접근 권한 (헤롱헤롱 알림)\" and relaunch.\n"
                .data(using: .utf8)!
        )
    }

    private func publish(_ animation: PetAnimationName, input: ClaudeDesktopInput) {
        let debug = ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil
        if debug {
            let line = String(
                format: "[connor-pet] claude-desktop: run=%@ front=%@ gen=%@ appr=%@ done=%@ ax=%@ -> %@\n",
                d(input.running), d(input.frontmost), d(input.generating), d(input.awaitingApproval),
                d(input.donePending), probe.lastReadable ? "Y" : "N", animation.rawValue
            )
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }

        guard animation != lastPublished else { return }
        lastPublished = animation

        let result = AgentStateAnimationResult(
            animation: animation,
            trace: [AgentStateAnimationTrace(line: "claude-desktop -> \(animation.rawValue)")]
        )
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
    }

    private func d(_ b: Bool) -> String { b ? "Y" : "N" }

    // MARK: - Frontmost / running (no special permission needed)

    private static func isClaudeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private static func isClaudeFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }
}

/// Reads Claude Desktop's live turn state from its Accessibility tree. Electron
/// only exposes its web content to AX after an external process sets
/// `AXManualAccessibility=true` on the application element, so we do that once
/// per process and then look for two localized controls:
///   • the "Stop response" button that exists only while a turn streams
///     (→ generating), and
///   • a tool/permission approval card, recognized by having *both* an Allow and
///     a Deny button (→ awaiting approval).
final class ClaudeAXProbe {
    /// One AX read of Claude's live turn state.
    struct Sample {
        /// A "Stop response" control is present — a turn is streaming.
        let generating: Bool
        /// An approval card is up (Allow + Deny buttons) — paused for the user.
        let awaitingApproval: Bool
    }
    /// The process we last forced `AXManualAccessibility` on. Re-forced whenever
    /// Claude relaunches (new pid), which resets the web AX tree.
    private var forcedPid: pid_t = 0
    /// Whether the last probe could read the AX tree at all (used for debug log).
    private(set) var lastReadable = false

    /// Bound on how many nodes we descend per poll — the stop button lives near
    /// the composer, so we never need to walk the whole document. Also keeps the
    /// synchronous AX IPC cheap enough to run at 2 Hz without bothering Claude.
    private let maxNodes = 4000

    /// The stop-response control's label, per account language. These come from
    /// the remote claude.ai web app (not the local app bundle), so the set is
    /// locale-dependent — extend as needed. Matched case-insensitively via
    /// `contains`, against AXTitle/AXDescription/AXValue.
    private let stopResponseLabels = [
        "응답 중단", "응답 중지", "생성 중지", "생성 중단",   // ko
        "stop response", "stop generating",                    // en
    ]

    // A tool/permission approval card is detected by the *co-presence* of an
    // allow-type and a deny-type button (matched case-insensitively via
    // `contains`, already lowercased). Requiring both avoids false positives from
    // an "허용"/"allow" toggle that happens to sit in settings — an approval card
    // is the only place both appear together. "허용" matches "한 번만 허용"/"항상
    // 허용"; we deliberately leave out "승인" (it appears in the "도구 호출 승인
    // 프로토콜 설정" sidebar entry).
    private let approvalAllowLabels = ["허용", "allow"]
    private let approvalDenyLabels  = ["거부", "거절", "deny", "reject"]

    /// If the app isn't trusted for Accessibility yet, show the system prompt
    /// once. Safe to call repeatedly; only prompts while untrusted.
    func ensurePermissionPrompted() {
        guard !AXIsProcessTrusted() else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// A `Sample` when we can read the tree; `nil` when we can't tell (no
    /// Accessibility permission, Claude not running, or the web tree hasn't been
    /// built yet). A `nil` must never be turned into a "turn finished" edge.
    func sample() -> Sample? {
        guard AXIsProcessTrusted() else { lastReadable = false; return nil }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == ClaudeDesktopStatusWatcher.bundleID
        }) else {
            forcedPid = 0
            lastReadable = false
            return nil
        }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        if pid != forcedPid {
            // (Re)force the web accessibility tree for this (possibly new)
            // process. Chromium builds it asynchronously, so the next poll or two
            // may still see nothing — that's a `nil`, not "not generating".
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            forcedPid = pid
        }

        // Only scan the app's windows (skips the ~200-item menu bar). If we can't
        // even read the window list, AX isn't ready/available → nil.
        guard let windows = copyChildren(axApp, attribute: kAXWindowsAttribute), !windows.isEmpty else {
            lastReadable = false
            return nil
        }
        lastReadable = true

        var visited = 0
        var found = Buttons()
        for window in windows {
            scan(window, visited: &visited, found: &found)
            if found.allSeen { break }
        }
        return Sample(generating: found.stop, awaitingApproval: found.allow && found.deny)
    }

    /// The button kinds we're hunting for in one tree walk.
    private struct Buttons {
        var stop = false, allow = false, deny = false
        var allSeen: Bool { stop && allow && deny }
    }

    private func scan(_ element: AXUIElement, visited: inout Int, found: inout Buttons) {
        if visited > maxNodes || found.allSeen { return }
        visited += 1

        classify(element, into: &found)
        guard let children = copyChildren(element, attribute: kAXChildrenAttribute) else { return }
        for child in children {
            scan(child, visited: &visited, found: &found)
            if found.allSeen { return }
        }
    }

    private func classify(_ element: AXUIElement, into found: inout Buttons) {
        guard let role = copyString(element, kAXRoleAttribute), role.contains("Button") else { return }
        let label = [
            copyString(element, kAXTitleAttribute),
            copyString(element, kAXDescriptionAttribute),
            copyString(element, kAXValueAttribute),
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !label.isEmpty else { return }
        if !found.stop, stopResponseLabels.contains(where: { label.contains($0.lowercased()) }) { found.stop = true }
        if !found.allow, approvalAllowLabels.contains(where: { label.contains($0) }) { found.allow = true }
        if !found.deny, approvalDenyLabels.contains(where: { label.contains($0) }) { found.deny = true }
    }

    // MARK: - AX attribute helpers

    private func copyChildren(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
