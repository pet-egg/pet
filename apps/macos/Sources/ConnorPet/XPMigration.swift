import Foundation

/// 예전 실행 방식에서 쌓아 둔 경험치를 지금 도메인으로 옮긴다.
///
/// 경험치는 `UserDefaults` 에 있고, `UserDefaults` 가 어느 파일을 쓰는지는 **번들
/// 식별자**가 정한다. 그래서 실행 방식이 바뀌면 저장소가 통째로 갈린다 — 파일 경로나
/// 앱 이름 때문이 아니다. 실제로 이 앱은 세 갈래를 만들었다.
///
/// | 실행 방식 | 도메인 |
/// |---|---|
/// | `swift run` | `ConnorPet` (번들이 없어 프로세스 이름을 쓴다) |
/// | 예전 `make_app.sh` | `io.github.pet-egg.connorpet` |
/// | 배포 dmg | `io.github.pet-egg.pet` |
///
/// dmg 로 갈아탄 사용자에게는 경험치가 통째로 사라진 것처럼 보였다. 값은 예전 도메인에
/// 그대로 남아 있었다.
///
/// 지금은 번들 식별자를 하나로 모았지만(`make_app.sh` 도 dmg 와 같은 값을 쓴다), 이미
/// 갈라진 사람들의 값은 옮겨 줘야 한다.
enum XPMigration {
    /// 예전에 쓰던 도메인들. 뒤로 갈수록 오래된 것이다.
    static let legacyDomains = ["io.github.pet-egg.connorpet", "ConnorPet"]

    private static let doneKey = "xpMigratedFromLegacyDomain"
    private static let tokensKey = "petTokens"
    private static let questIDsKey = "questCreditedIDs"
    private static let questBaselineKey = "questBaselineTaken"

    /// 설정 창에 "구 버전에서 경험치 가져오기" 를 어떻게 보여 줄지.
    ///
    /// 처음에는 "늘어날 게 없으면 행을 숨긴다" 로 만들었는데, 그러면 기능이 아예
    /// 없는 것처럼 보인다 — 예전 기록을 이미 가져온 사람이 "가져오기가 어디 있나"
    /// 하고 찾게 된다. 예전 기록이 하나라도 있으면 행은 늘 보여 주고, 가져올 게
    /// 없을 때는 그 사실을 문구로 밝힌다.
    enum LegacyStatus: Equatable {
        /// 예전 기록이 아예 없다. 이때만 행을 감춘다 — 보여 줄 것이 없다.
        case none
        /// 가져오면 늘어난다. `gain` 은 펫마다 늘어날 양.
        case importable(found: [String: Double], gain: [String: Double])
        /// 예전 기록은 있지만 지금이 더 많거나 같다.
        case alreadyMerged(found: [String: Double])

        var found: [String: Double] {
            switch self {
            case .none: return [:]
            case .importable(let found, _), .alreadyMerged(let found): return found
            }
        }
    }

    /// 예전 기록과 지금 경험치를 견줘 상태를 정한다. 화면 코드가 이 값만 보고 그린다.
    static func status(current: [String: Double],
                       legacy: [String: Double]) -> LegacyStatus {
        guard !legacy.isEmpty else { return .none }
        var gain: [String: Double] = [:]
        for (pet, value) in legacy {
            let delta = value - (current[pet] ?? 0)
            if delta > 0 { gain[pet] = delta }
        }
        return gain.isEmpty ? .alreadyMerged(found: legacy) : .importable(found: legacy, gain: gain)
    }

    /// 예전 도메인에 남아 있는 경험치를 훑는다. 설정 창이 "가져올 게 있는지" 를
    /// 보여 주고, 손으로 가져오기를 누를 때 재료로 쓴다.
    ///
    /// 같은 펫이 여러 도메인에 있으면 가장 많이 쌓인 값을 남긴다.
    static func legacyTokens(from domains: [String] = legacyDomains) -> [String: Double] {
        var tokens: [String: Double] = [:]
        for domain in domains {
            guard let old = UserDefaults(suiteName: domain) else { continue }
            for (pet, value) in (old.dictionary(forKey: tokensKey) as? [String: Double] ?? [:])
            where value > 0 {
                tokens[pet] = max(tokens[pet] ?? 0, value)
            }
        }
        return tokens
    }

    /// 예전 도메인의 퀘스트 지급 기록. 경험치를 가져올 때 함께 합쳐야 한다 — 안 그러면
    /// 예전에 올린 PR·티켓이 다시 새것으로 잡혀 경험치가 두 번 들어간다.
    static func legacyQuestIDs(from domains: [String] = legacyDomains) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for domain in domains {
            guard let old = UserDefaults(suiteName: domain) else { continue }
            for id in (old.stringArray(forKey: questIDsKey) ?? []) where !seen.contains(id) {
                seen.insert(id)
                ids.append(id)
            }
        }
        return ids
    }

    /// 가져온 퀘스트 기록을 지금 도메인에 합친다. 경험치 자체는 호출부(AppDelegate)가
    /// 자기 메모리 상태와 함께 다뤄야 한다 — 여기서 UserDefaults 만 고치면 앱이
    /// 다음 저장 때 예전 값으로 덮어쓴다(실제로 그렇게 한 번 날렸다).
    static func mergeQuestIDs(into target: UserDefaults = .standard,
                              from domains: [String] = legacyDomains) -> Int {
        let incoming = legacyQuestIDs(from: domains)
        guard !incoming.isEmpty else { return 0 }
        var ids = target.stringArray(forKey: questIDsKey) ?? []
        var seen = Set(ids)
        var added = 0
        for id in incoming where !seen.contains(id) {
            seen.insert(id)
            ids.append(id)
            added += 1
        }
        target.set(ids, forKey: questIDsKey)
        target.set(true, forKey: questBaselineKey)
        return added
    }

    /// 손으로 가져온 뒤에는 자동 이관이 다시 돌 이유가 없다.
    static func markDone(in target: UserDefaults = .standard) {
        target.set(true, forKey: doneKey)
    }

    /// 필요하면 한 번만 옮긴다. 무엇을 옮겼는지 한 줄로 돌려준다(아무것도 안 했으면 nil).
    ///
    /// **이미 쌓인 값이 있으면 손대지 않는다.** 옮기는 것은 "이 도메인에는 경험치가
    /// 아예 없다" 일 때뿐이라, 멀쩡히 쓰던 사람의 값을 덮어쓸 일이 없다.
    @discardableResult
    static func runIfNeeded(into target: UserDefaults = .standard,
                            from domains: [String] = legacyDomains) -> String? {
        guard !target.bool(forKey: doneKey) else { return nil }
        target.set(true, forKey: doneKey)   // 성공하든 아니든 한 번만 시도한다

        let existing = target.dictionary(forKey: tokensKey) as? [String: Double] ?? [:]
        guard existing.values.allSatisfy({ $0 <= 0 }) else { return nil }

        var tokens: [String: Double] = [:]
        var questIDs: [String] = []
        var seen = Set<String>()
        var found: String?

        for domain in domains {
            guard let old = UserDefaults(suiteName: domain) else { continue }
            for (pet, value) in (old.dictionary(forKey: tokensKey) as? [String: Double] ?? [:]) {
                // 같은 펫이 여러 도메인에 있으면 가장 많이 쌓인 쪽을 남긴다.
                tokens[pet] = max(tokens[pet] ?? 0, value)
                if found == nil { found = domain }
            }
            // 이미 지급한 퀘스트 기록도 함께 가져온다. 안 그러면 예전에 올린 PR·티켓이
            // 다시 새것으로 잡혀 경험치가 두 번 들어간다.
            for id in (old.stringArray(forKey: questIDsKey) ?? []) where !seen.contains(id) {
                seen.insert(id)
                questIDs.append(id)
            }
        }

        guard !tokens.isEmpty else { return nil }
        target.set(tokens, forKey: tokensKey)
        if !questIDs.isEmpty {
            target.set(questIDs, forKey: questIDsKey)
            target.set(true, forKey: questBaselineKey)
        }

        let total = Int(tokens.values.reduce(0, +))
        return "예전 기록에서 경험치 \(total) 을 가져왔어요 (\(found ?? "?"))"
    }
}
