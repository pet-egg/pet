import Foundation

/// `CONNORPET_SELFTEST=quest swift run`. 퀘스트 지급 규칙과 실제 조회를 확인한다.
///
/// 1단계는 지급 규칙만 본다 — 최초 실행은 기준선만 잡고 지급하지 않는지, 새로 끝난
/// 것만 세는지, 같은 것을 다시 봐도 두 번 주지 않는지. **사용자의 실제 지급 기록을
/// 건드리지 않도록** 별도 UserDefaults 저장소에 대고 돌린다.
///
/// 2단계는 GitHub 를 실제로 조회한다. 네트워크와 `gh` 로그인에 기대므로, 둘이 없으면
/// 실패가 아니라 건너뛴 것으로 알린다 — CI 나 오프라인에서 빨간불이 뜰 일이 아니다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runQuestSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let suiteName = "connor-pet.selftest.quest"
    guard let store = UserDefaults(suiteName: suiteName) else { fail("검증용 저장소를 못 만들었다") }
    store.removePersistentDomain(forName: suiteName)
    let service = QuestService(defaults: store)

    func quest(_ id: String, _ name: String, minutesAgo: Double) -> Quest {
        Quest(id: id, source: .githubPR, name: name, title: "제목",
              completedAt: Date().addingTimeInterval(-minutesAgo * 60))
    }

    // 1단계 ── 지급 규칙
    print("[selftest] phase 1: 지급 규칙")

    let seed = [quest("gh:a#1", "a#1", minutesAgo: 300), quest("gh:a#2", "a#2", minutesAgo: 200)]
    let first = service.creditNew(seed)
    guard first.isEmpty else {
        fail("최초 실행에서 \(first.count)건을 지급했다 — 기준선만 잡아야 한다")
    }
    print("[selftest] 최초 실행: 2건을 기준선으로만 기록, 지급 0")

    let again = service.creditNew(seed)
    guard again.isEmpty else { fail("같은 것을 다시 봤는데 \(again.count)건을 지급했다") }
    print("[selftest] 같은 목록 재조회: 지급 0")

    let withNew = seed + [quest("gh:a#3", "a#3", minutesAgo: 10)]
    let second = service.creditNew(withNew)
    guard second.count == 1, second[0].id == "gh:a#3" else {
        fail("새로 끝난 1건만 나와야 하는데 \(second.map(\.id))")
    }
    print("[selftest] 새 1건만 지급: \(second[0].name)")

    let third = service.creditNew(withNew)
    guard third.isEmpty else { fail("이미 준 것을 또 줬다: \(third.map(\.id))") }
    print("[selftest] 지급한 것 재조회: 지급 0 (중복 방지)")

    // 여러 건이 한 번에 잡히면 오래된 순서로 나와야 말풍선의 "외 N건" 이 앞뒤가 맞는다.
    let burst = withNew + [quest("gh:a#5", "a#5", minutesAgo: 1), quest("gh:a#4", "a#4", minutesAgo: 5)]
    let fourth = service.creditNew(burst)
    guard fourth.map(\.name) == ["a#4", "a#5"] else {
        fail("여러 건이 오래된 순이 아니다: \(fourth.map(\.name))")
    }
    print("[selftest] 여러 건 동시 지급: 오래된 순 \(fourth.map(\.name))")

    // 초기화하면 기준선도 사라져, 다음 조회가 다시 기준선 잡기부터 시작해야 한다.
    QuestService.resetHistory(defaults: store)
    let afterReset = service.creditNew(burst)
    guard afterReset.isEmpty else {
        fail("초기화 직후인데 \(afterReset.count)건을 지급했다 — 기준선부터 다시 잡아야 한다")
    }
    print("[selftest] 초기화 후: 기준선부터 다시 시작")

    let reward = Int(QuestService.rewardPerQuest)
    guard reward == 300_000 else { fail("건당 보상이 \(reward) 이다") }
    print("[selftest] 건당 보상 \(reward) EXP · 주기 \(Int(QuestService.pollInterval))초")

    // 축하 문구 ── 하나씩 나뉘어야 말풍선이 겹치지 않는다.
    let one = AppDelegate.celebrationTexts(for: [quest("gh:b#1", "b#1", minutesAgo: 1)])
    guard one.count == 1, one[0].contains("300,000 EXP"), one[0].contains("b#1") else {
        fail("1건 축하 문구가 이상하다: \(one)")
    }
    let two = AppDelegate.celebrationTexts(for: fourth)
    guard two.count == 2, two[0].contains("a#4"), two[1].contains("a#5"),
          two.allSatisfy({ $0.contains("300,000 EXP") }) else {
        fail("2건이 각각 한 줄씩 나와야 하는데: \(two)")
    }
    // 스무 건이 한꺼번에 잡혀도 말풍선이 2분 넘게 이어지면 안 된다.
    let flood = (1...20).map { quest("gh:c#\($0)", "c#\($0)", minutesAgo: Double(30 - $0)) }
    let folded = AppDelegate.celebrationTexts(for: flood)
    guard folded.count == 5, folded.last?.contains("그 밖에 16건") == true,
          folded.last?.contains("4,800,000 EXP") == true else {
        fail("20건이 접히지 않았다: \(folded.count)개 / \(folded.last ?? "없음")")
    }
    let seconds = Double(folded.count) * (PetView.celebrationDuration + PetView.celebrationGap)
    guard seconds <= 40 else { fail("축하가 \(seconds)초나 이어진다") }
    for line in two + [folded.last ?? ""] {
        print("[selftest] 축하 문구: \(line.replacingOccurrences(of: "\n", with: " / "))")
    }
    print("[selftest] 20건 → 말풍선 \(folded.count)개, 총 \(Int(seconds))초")

    store.removePersistentDomain(forName: suiteName)

    // 2단계 ── 실제 조회
    print("[selftest] phase 2: 실제 조회")
    let since = Date().addingTimeInterval(-7 * 86_400)

    let prs = service.fetchGitHubPRs(since: since)
    if prs.isEmpty {
        print("[selftest] GitHub: 0건 — gh 미설치·미로그인이거나 최근 7일 PR 이 없음 (건너뜀)")
    } else {
        for p in prs.prefix(3) { print("[selftest] GitHub: \(p.id)  \(p.title.prefix(30))") }
        guard prs.allSatisfy({ $0.id.hasPrefix("gh:") && !$0.name.isEmpty }) else {
            fail("PR 퀘스트의 id·이름 형식이 어긋난다")
        }
        guard Set(prs.map(\.id)).count == prs.count else { fail("PR 퀘스트에 중복 id 가 있다") }
        print("[selftest] GitHub \(prs.count)건, id 형식·중복 없음 확인")
    }

    // 키체인은 **읽지 않는다**. 항목은 만든 바이너리의 코드 서명에 묶이고 ad-hoc
    // 서명은 빌드마다 바뀌므로, 검증용 빌드가 읽으려 하면 암호 창이 뜬다 — 헤드리스
    // 실행에서는 아무도 못 누르는 창을 기다리며 영구히 멈춘다(실제로 그랬다).
    // 저장 여부 플래그만 보고, 실제 호출은 명시적으로 요청할 때만 한다.
    let wantsLinear = ProcessInfo.processInfo.environment["CONNORPET_SELFTEST_LINEAR"] != nil
    if !LinearKeychain.isStored {
        print("[selftest] Linear: 저장된 키가 없어 건너뜀 (설정 창에서 넣을 수 있다)")
    } else if !wantsLinear {
        print("[selftest] Linear: 키는 있지만 건너뜀 — 읽으면 키체인 암호 창이 떠 멈춘다."
              + " 확인하려면 CONNORPET_SELFTEST_LINEAR=1 로 돌리고 창에서 허용할 것")
    } else {
        let issues = service.fetchLinearIssues(since: since)
        for i in issues.prefix(3) { print("[selftest] Linear: \(i.id)  \(i.title.prefix(30))") }
        guard issues.allSatisfy({ $0.id.hasPrefix("linear:") }) else {
            fail("티켓 퀘스트의 id 형식이 어긋난다")
        }
        print("[selftest] Linear \(issues.count)건 확인")
    }

    print("SELFTEST PASS")
    exit(0)
}
