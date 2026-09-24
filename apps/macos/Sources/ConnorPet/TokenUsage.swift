import Foundation

/// Reads real cumulative token usage out of a Claude Code transcript JSONL and
/// converts it into an "experience"/level curve for the pet's XP bar and
/// evolution. Both status sources feed this the same way:
///
///  - Claude Code: each live session's transcript at
///    `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` (resolved by globbing
///    on sessionId, so we don't have to reproduce Claude Code's cwd→slug rule).
///  - Orca: each entry in `last-status.json` already carries the exact path in
///    `providerSession.transcriptPath`.
///
/// The transcript is the *only* on-disk place Claude Code records per-turn
/// `usage` (input/output/cache tokens); the session file and Orca's status file
/// never contain token counts themselves.

/// Sums token usage from transcript JSONL files, caching per-file results by
/// modification time so the hot polling path only re-reads a transcript that
/// actually grew. Not thread-safe on its own — each watcher owns one instance
/// and only touches it from its own poll (main run loop).
final class TranscriptTokenReader {
    private var cache: [String: (mtime: Date, tokens: Double)] = [:]

    /// Cumulative "tokens used" for one transcript. We sum, across every
    /// assistant message, `input + output + cache_creation` — the non-cached
    /// (roughly "billed new work") tokens. cache_read is deliberately excluded:
    /// it re-counts the whole prompt context every turn and would balloon the
    /// number an order of magnitude without reflecting extra work done.
    func tokens(atPath path: String) -> Double {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if let mtime, let cached = cache[path], cached.mtime == mtime {
            return cached.tokens
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return cache[path]?.tokens ?? 0 // transient read miss — keep last known
        }
        let total = Self.sumTokens(in: data)
        cache[path] = (mtime ?? Date(), total)
        return total
    }

    /// Total tokens across a set of entries, deduping by transcript path so two
    /// panes pointed at the same session aren't counted twice.
    func total(for entries: [AgentStatusEntry]) -> Double {
        let paths = Set(entries.compactMap { $0.transcriptPath })
        return paths.reduce(0) { $0 + tokens(atPath: $1) }
    }

    /// 마지막 호출 이후 **새로 쌓인** 토큰만 돌려준다.
    ///
    /// `total(for:)` 은 지금 살아 있는 세션들의 합이라 세션이 끝나면 줄어든다.
    /// 경험치를 펫별로 나누려면 "누가 화면에 있는 동안 얼마나 일했나"를 세야 하고,
    /// 그러려면 감소하지 않는 값이 필요하다. 트랜스크립트 파일 하나하나는 늘어나기만
    /// 하므로, 파일별 증가분을 더한다.
    ///
    /// 처음 보는 트랜스크립트는 **현재 값으로 등록만 하고 증가분에 넣지 않는다.**
    /// 안 그러면 앱을 켜거나 펫을 바꾼 직후에 이미 진행 중이던 세션의 과거 사용량이
    /// 통째로 그 펫에게 쏟아진다.
    func accrued(for entries: [AgentStatusEntry]) -> Double {
        let paths = Set(entries.compactMap { $0.transcriptPath })
        var gained: Double = 0
        for path in paths {
            let now = tokens(atPath: path)
            if let seen = accrualBaseline[path] {
                // 파일이 줄어드는 일은 없어야 하지만(추가 전용), 트랜스크립트가
                // 교체·재작성되는 경우를 대비해 음수는 버리고 기준선만 낮춘다.
                if now > seen { gained += now - seen }
            }
            accrualBaseline[path] = now
        }
        return gained
    }

    private var accrualBaseline: [String: Double] = [:]

    /// Parses each JSONL line and adds up `message.usage`. Loose parsing per
    /// line so one malformed line can't zero the whole file (same defensive
    /// stance as `parseAgentStatusEntries`).
    static func sumTokens(in data: Data) -> Double {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        var total: Double = 0
        text.enumerateLines { line, _ in
            guard
                let lineData = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let message = obj["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { return }
            let input = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
            let output = (usage["output_tokens"] as? NSNumber)?.doubleValue ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            total += input + output + cacheCreation
        }
        return total
    }
}

/// Maps a raw cumulative-token count to the pet's XP bar fill (0...1) and its
/// evolution stage. Tuned low on purpose — this is a proof of concept, so the
/// pet should visibly evolve within a single real working session rather than
/// after hours of use.
enum XPModel {
    /// 진화 지점 — **비율이 아니라 실제 토큰 수**다.
    ///
    /// 예전에는 "바 만렙 100만 토큰의 10%/30%" 였는데, 실측 하루 사용량이
    /// (입력+출력+캐시생성 기준) 1,500만이라 앱을 켜자마자 바가 가득 차고
    /// 1차 진화를 건너뛰어 곧장 2차로 갔다. 1차 진화형을 볼 수가 없었다.
    static let stageTokens: [Double] = [200_000_000, 500_000_000]

    /// 바가 가득 차는 기준. 마지막 진화 지점과 같게 두어, 바가 꽉 차는 순간이
    /// 최종 진화 시점이 되게 한다.
    static var maxTokens: Double { stageTokens.last ?? 1 }

    /// 다음 진화까지의 진행 상황. 바와 호버 문구가 같은 값을 쓰도록 한곳에서 만든다.
    ///
    /// 기준이 **다음 진화 지점**인 이유: 예전에는 바가 최종 진화(5억) 기준이라
    /// 1단계를 갓 지난 시점에도 40%에 머물러 있어서, 다음 진화가 얼마나 남았는지
    /// 읽히지 않았다. 단계가 오를 때마다 바가 다시 차오르는 편이 알아보기 쉽다.
    struct Progress {
        let percent: Double      // 0...1, 다음 진화 지점 기준
        let tokens: Double       // 지금까지 쌓은 토큰
        let target: Double?      // 다음 진화 지점. 최종 단계면 nil
    }

    static func progress(tokens: Double) -> Progress {
        guard let target = stageTokens.first(where: { tokens < $0 }) else {
            return Progress(percent: 1, tokens: tokens, target: nil)
        }
        return Progress(percent: min(1, max(0, tokens / target)), tokens: tokens, target: target)
    }

    static func percent(tokens: Double) -> Double {
        progress(tokens: tokens).percent
    }

    /// 0 = 기본형, 1 = 1차 진화, 2 = 2차 진화.
    static func stage(tokens: Double) -> Int {
        stageTokens.reduce(0) { $0 + (tokens >= $1 ? 1 : 0) }
    }
}
