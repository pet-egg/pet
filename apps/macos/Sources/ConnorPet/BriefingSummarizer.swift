import Foundation

/// Turns the raw session transcripts into a short spoken briefing by asking the
/// `claude` CLI to summarise them.
///
/// Why it is cached rather than called on the click: a `claude -p` round trip
/// measured ~10s against real session data, and the pet has to answer a click
/// immediately. So the click always renders whatever is already on disk (or the
/// raw fallback), and a refresh runs in the background for the *next* click.
///
/// Why it runs in its own working directory: the CLI call is itself a Claude
/// Code session and writes its own transcript. Left alone it would show up in
/// the next briefing — the pet summarising its own summarising. Running under
/// `agentWorkingDirectory` puts those transcripts in a project folder the
/// reader skips (see `SessionBriefReader.isSelfGenerated`).
enum BriefingSummarizer {
    /// Older than this and the cache is refreshed on the next click.
    static let cacheTTL: TimeInterval = 10 * 60
    /// A summarise run that hangs must not leak a process forever.
    private static let timeout: TimeInterval = 90

    struct Cached {
        let text: String
        let generatedAt: Date
        /// Which sessions it covered. If the set has moved on, the summary is
        /// stale even when it is younger than the TTL.
        let fingerprint: String
    }

    // MARK: - Paths

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ConnorPet")
    }

    static var agentWorkingDirectory: URL {
        supportDirectory.appendingPathComponent("agent")
    }

    private static var cacheURL: URL {
        supportDirectory.appendingPathComponent("briefing-cache.json")
    }

    // MARK: - Cache

    static func cached() -> Cached? {
        guard
            let data = try? Data(contentsOf: cacheURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = object["text"] as? String, !text.isEmpty,
            let at = object["generatedAt"] as? Double
        else { return nil }
        return Cached(
            text: text,
            generatedAt: Date(timeIntervalSince1970: at),
            fingerprint: object["fingerprint"] as? String ?? ""
        )
    }

    private static func write(text: String, fingerprint: String) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "text": text,
            "generatedAt": Date().timeIntervalSince1970,
            "fingerprint": fingerprint,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: cacheURL)
    }

    /// 어떤 세션 묶음을 요약한 것인지 식별한다. 세션이 바뀌면(새 세션이 뜨거나
    /// 하나가 창에서 빠지면) 캐시는 무효다.
    ///
    /// 세션 **id 만** 쓴다. 처음에는 파일 수정 시각도 넣었는데, 살아 있는 세션은
    /// 몇 초마다 트랜스크립트가 갱신돼서 지문이 매번 달라졌고 캐시가 한 번도
    /// 맞지 않았다. 같은 세션의 새 활동을 언제까지 무시할지는 TTL 이 정한다.
    static func fingerprint(_ briefs: [SessionBrief]) -> String {
        briefs.map(\.id).sorted().joined(separator: "|")
    }

    // MARK: - Refresh

    private static var isRefreshing = false

    /// Kicks off a summarise run unless one is already in flight. Returns
    /// immediately; `completion` lands on the main queue when the cache is new.
    static func refresh(briefs: [SessionBrief], perBriefChars: Int, windowHours: Double,
                        completion: (() -> Void)? = nil) {
        guard !isRefreshing, !briefs.isEmpty else { return }
        guard let claude = claudeExecutable() else { return }
        isRefreshing = true

        let prompt = buildPrompt(briefs: briefs, perBriefChars: perBriefChars, windowHours: windowHours)
        let mark = fingerprint(briefs)

        DispatchQueue.global(qos: .utility).async {
            defer {
                isRefreshing = false
                DispatchQueue.main.async { completion?() }
            }
            guard let output = run(claude: claude, prompt: prompt), !output.isEmpty else { return }
            let lines = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("·") }
            guard !lines.isEmpty else { return }
            // 줄 사이를 한 줄 띄운다. 말풍선에서 줄바꿈이 일어나면 어디서 한
            // 세션이 끝나는지 구분이 안 된다.
            write(text: lines.joined(separator: "\n\n"), fingerprint: mark)
        }
    }

    private static func buildPrompt(briefs: [SessionBrief], perBriefChars: Int,
                                    windowHours: Double) -> String {
        let window = windowHours >= 1
            ? "\(Int(windowHours.rounded()))시간"
            : "\(Int((windowHours * 60).rounded()))분"
        var out = """
        아래는 작업방 여러 개에서 최근 \(window) 동안 오간 대화다. 방마다
        **어디까지 진행됐는지** 한 줄로 적어라. 무슨 주제인지가 아니라 진행 상태가 필요하다.

        - 방 하나당 정확히 한 줄, \(perBriefChars)자 이내 한국어
        - 형식은 "· [프로젝트명] 진행상태" 이고 다른 말은 절대 붙이지 않는다
        - 방 순서를 그대로 유지한다
        - "무엇을 하는 중" 같은 주제 설명이 아니라, 무엇까지 끝났고 지금 무엇이
          걸려 있는지를 적는다. 대화 전체가 판단 근거이고, 특히 뒤쪽이 현재 상태다
        - 여러 갈래를 했으면 마지막에 붙잡고 있던 것을 쓴다
        - 다음에 이어서 하려면 무엇을 봐야 하는지가 드러나면 가장 좋다

        """
        for (i, brief) in briefs.enumerated() {
            out += "\n[\(i + 1)번 방 프로젝트=\(brief.project)]\n"
            guard !brief.conversation.isEmpty else {
                out += "요청: \(brief.text)\n"
                continue
            }
            for turn in brief.conversation {
                out += turn.isUser ? "나: \(turn.text)\n" : "클로드: \(turn.text)\n"
            }
        }
        return out
    }

    private static func run(claude: URL, prompt: String) -> String? {
        try? FileManager.default.createDirectory(at: agentWorkingDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = claude
        process.arguments = ["-p", prompt]
        process.currentDirectoryURL = agentWorkingDirectory
        // stdin must be closed, or the CLI waits on it before starting.
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `claude` is usually not on the PATH a GUI app inherits, so the common
    /// install locations are checked directly before giving up.
    private static func claudeExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
