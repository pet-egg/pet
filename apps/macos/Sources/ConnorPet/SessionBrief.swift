import Foundation

/// One recent Claude Code session, condensed to a single line the pet can say.
struct SessionBrief {
    let id: String            // sessionId — 요약 캐시가 같은 세션 묶음인지 판별하는 키
    let project: String       // cwd's last path component
    let branch: String?       // gitBranch at the time the session started
    let text: String          // already truncated to the caller's char budget
    /// 이 방에서 **정해진 시간 안에 오간 대화**. 요약기가 쓰는 재료다.
    ///
    /// 예전에는 세션 첫 메시지(목표)와 마지막 요청 몇 개만 담았는데, 세션이 며칠
    /// 이어지면 첫 메시지는 한참 전 이야기고 마지막 몇 개만으로는 그사이 무엇이
    /// 끝났는지가 빠졌다. 창 안의 대화를 통째로 주면 요약기가 직접 판단한다.
    let conversation: [Turn]
    let updatedAt: Date
    let isDesktop: Bool       // claude-desktop vs cli, for the "어디서" hint

    /// 대화 한 마디. 누가 말했는지가 있어야 "무엇을 시켰나" 와 "무엇이 됐나" 가 갈린다.
    struct Turn {
        let isUser: Bool
        let text: String
    }
}

/// Reads recent session activity straight out of Claude Code's own transcript
/// directory, `~/.claude/projects/<slugified-cwd>/<sessionId>.jsonl`.
///
/// Why this directory: **both** Claude Code entrypoints write here — the `claude`
/// CLI and the desktop app — and each assistant record carries an `entrypoint`
/// field ("cli" / "claude-desktop") that tells them apart. So one reader covers
/// both without shelling out to either.
///
/// Why only the head of each file: transcripts get big (a 31MB session was
/// observed live) and this runs on a click, so reading them whole would stall
/// the UI. Everything needed is near the top — the session's opening user
/// message is what states the task, and it landed within the first 8KB in every
/// recent transcript checked. `readHeadBytes` caps the read well above that.
enum SessionBriefReader {
    private static let readHeadBytes = 128 * 1024
    /// 최근 대화는 파일 끝에서 읽는다. 헤드와 같은 이유로 통째로 읽지 않는다.
    ///
    /// 24시간 창을 다 담기에는 모자랄 수 있다 — 바쁜 세션은 하루에 이보다 훨씬
    /// 많이 쌓인다. 그때는 창 안에서 **가장 최근** 대화만 잡히는데, 어디까지
    /// 진행됐는지를 보는 용도라 그쪽이 필요한 부분이다.
    private static let readTailBytes = 512 * 1024
    /// 요약기에 넘길 최대 대화 수. 프롬프트가 무한정 길어지지 않게 막는다.
    private static let maxTurns = 16
    private static let turnChars = 220

    static var transcriptsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Most-recently-active sessions first.
    ///
    /// - Parameters:
    ///   - withinHours: only sessions touched this recently are considered.
    ///   - limit: how many briefs to return.
    ///   - perBriefChars: hard cap on each brief's own text.
    ///   - conversationHours: 각 방에서 **얼마 전까지의 대화**를 재료로 삼을지.
    ///     세션을 고르는 창(`withinHours`)과는 별개다 — 3시간 안에 만진 방이라도
    ///     요약 재료는 하루치를 본다.
    static func recent(
        withinHours: Double = 6,
        limit: Int = 5,
        perBriefChars: Int = 100,
        conversationHours: Double = 24,
        now: Date = Date()
    ) -> [SessionBrief] {
        let cutoff = now.addingTimeInterval(-withinHours * 3600)
        let conversationCutoff = now.addingTimeInterval(-conversationHours * 3600)
        let files = recentTranscripts(since: cutoff)

        var bySession: [String: SessionBrief] = [:]
        var order: [String] = []

        for file in files {
            // Scanning stops once enough sessions survive filtering. Files are
            // already newest-first, so the ones dropped here are always older
            // than everything kept.
            if bySession.count >= limit { break }
            guard let (sessionId, brief) = parse(file: file.url, modifiedAt: file.modifiedAt,
                                                 perBriefChars: perBriefChars,
                                                 conversationCutoff: conversationCutoff) else { continue }
            // The same session id can appear under two project folders (observed
            // when a session's cwd changed). Keep the more recently written copy.
            if let existing = bySession[sessionId], existing.updatedAt >= brief.updatedAt { continue }
            if bySession[sessionId] == nil { order.append(sessionId) }
            bySession[sessionId] = brief
        }

        return order.compactMap { bySession[$0] }
    }

    // MARK: - File discovery

    private struct Transcript {
        let url: URL
        let modifiedAt: Date
    }

    private static func recentTranscripts(since cutoff: Date) -> [Transcript] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: transcriptsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [Transcript] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard !isSelfGenerated(url) else { continue }
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true,
                let modified = values.contentModificationDate,
                modified >= cutoff
            else { continue }
            found.append(Transcript(url: url, modifiedAt: modified))
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 요약기가 돌린 `claude -p` 세션의 트랜스크립트인가.
    ///
    /// 그 호출도 Claude Code 세션이라 트랜스크립트를 남긴다. 걸러 내지 않으면
    /// 다음 브리핑에 "펫이 자기 요약을 요약한 내용"이 섞인다. 요약기는 전용
    /// 작업 디렉터리에서 돌고, Claude Code 는 cwd 를 슬러그화해 폴더 이름으로
    /// 쓰므로 폴더 이름만 봐도 구분된다.
    private static func isSelfGenerated(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent.contains("ConnorPet")
    }

    // MARK: - Parsing

    private static func parse(file: URL, modifiedAt: Date, perBriefChars: Int,
                              conversationCutoff: Date) -> (String, SessionBrief)? {
        guard let head = readHead(of: file) else { return nil }

        var sessionId: String?
        var cwd: String?
        var branch: String?
        var isDesktop = false
        var opening: String?

        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let record = object as? [String: Any]
            else { continue }

            sessionId = sessionId ?? record["sessionId"] as? String
            cwd = cwd ?? record["cwd"] as? String
            branch = branch ?? (record["gitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let entrypoint = record["entrypoint"] as? String, entrypoint.contains("desktop") {
                isDesktop = true
            }

            if opening == nil,
               record["type"] as? String == "user",
               (record["isSidechain"] as? Bool) != true,
               let text = userText(in: record),
               let cleaned = clean(text) {
                opening = cleaned
            }

            // The opening message is the goal statement; metadata is on the same
            // or an earlier record, so there is nothing left to learn after it.
            if opening != nil, sessionId != nil, cwd != nil { break }
        }

        guard let id = sessionId, let text = opening else { return nil }
        let conversation = self.conversation(in: file, since: conversationCutoff)
        // 창 안에 사용자 발화가 있으면 그중 첫 줄이 "지금 하던 일" 에 더 가깝다.
        // 세션 첫 메시지는 며칠 전 목표일 수 있어 요약기 없이 그릴 때 어색하다.
        let headline = conversation.first(where: { $0.isUser })?.text ?? text
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
        return (id, SessionBrief(
            id: id,
            project: project,
            branch: branch,
            text: truncate(headline, to: perBriefChars),
            conversation: conversation,
            updatedAt: modifiedAt,
            isDesktop: isDesktop
        ))
    }

    /// 파일 끝에서 `since` 이후의 대화를 오래된 순서대로 뽑는다.
    ///
    /// 사용자 발화와 응답을 **둘 다** 담는다. 어디까지 진행됐는지는 무엇을 시켰는지
    /// 만으로는 알 수 없고, 그것이 어떻게 됐는지가 있어야 판단된다.
    ///
    /// 시각이 없는 레코드는 버린다. 창 밖인지 안인지 알 수 없는 것을 넣으면
    /// "24시간 이내" 라는 약속이 깨진다.
    private static func conversation(in url: URL, since: Date) -> [SessionBrief.Turn] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(readTailBytes) ? size - UInt64(readTailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }

        // 임의 위치에서 잘라 읽었으므로 첫 줄은 대개 반쪽짜리다. 그래서 1부터.
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        // 뒤에서부터 모아 maxTurns 를 채우면 멈춘다 — 창이 넓어도 프롬프트는 짧게.
        var turns: [SessionBrief.Turn] = []
        for line in lines.reversed() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let record = object as? [String: Any],
                (record["isSidechain"] as? Bool) != true,
                let stamp = record["timestamp"] as? String,
                let at = parseTimestamp(stamp)
            else { continue }
            // 파일은 시간순이라, 창을 벗어난 줄을 만나면 그 앞은 전부 더 오래됐다.
            guard at >= since else { break }

            switch record["type"] as? String {
            case "assistant":
                // 도구 호출만 있는 응답은 건너뛴다. 텍스트가 있는 것만 남긴다.
                if let text = assistantText(in: record), text.count >= 12 {
                    turns.append(.init(isUser: false, text: truncate(text, to: turnChars)))
                }
            case "user":
                if let raw = userText(in: record), let cleaned = clean(raw) {
                    turns.append(.init(isUser: true, text: truncate(cleaned, to: turnChars)))
                }
            default:
                break
            }
            if turns.count >= maxTurns { break }
        }
        return turns.reversed()
    }

    /// 트랜스크립트의 `timestamp` 는 밀리초가 붙은 ISO8601 이다(예:
    /// `2026-09-04T07:52:37.676Z`). 밀리초가 없는 형식도 함께 받아 둔다.
    private static func parseTimestamp(_ raw: String) -> Date? {
        if let date = isoWithFraction.date(from: raw) { return date }
        return isoPlain.date(from: raw)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()


    /// assistant 레코드의 텍스트 블록만 이어 붙인다(도구 호출 블록은 뺀다).
    private static func assistantText(in record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func readHead(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: readHeadBytes)
    }

    /// A user record's content is either a plain string or an array of typed
    /// blocks; only the `text` blocks are the human's own words.
    private static func userText(in record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Drops the records that are technically "user" messages but are not the
    /// human describing a task: slash-command envelopes, the expanded body of a
    /// skill or command, injected reminders, and one-word throwaways like the
    /// "repeat hi" smoke-test sessions found in the live transcripts.
    private static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let rejectedPrefixes = [
            "<command-name>", "<command-message>", "<local-command",
            "<system-reminder>", "<user-prompt-submit-hook>",
            "Caveat:", "#",
            // 스킬을 부르면 그 본문이 user 레코드로 들어온다. 사람이 시킨 말이
            // 아니라서 브리핑에 나오면 "Base directory for this skill: /private/…"
            // 같은 줄이 그대로 읽힌다.
            "Base directory for this skill",
        ]
        for prefix in rejectedPrefixes where text.hasPrefix(prefix) { return nil }

        // Collapse newlines/tabs so the bubble lays out as one flowing line.
        text = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }

        return text.count >= 12 ? text : nil
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
