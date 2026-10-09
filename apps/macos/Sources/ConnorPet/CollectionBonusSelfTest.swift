import Foundation

/// `CONNORPET_SELFTEST=collection swift run`. 완전체 수집 보너스 규칙을 확인한다.
///
/// 요구는 "1마리 5% · 5마리 25% · 10마리 50%" 였다. 그 세 점을 그대로 검사하고, 규칙에
/// 적히지 않은 두 가지(자기 자신은 빼는가, 10마리를 넘으면 어떻게 되나)를 이 앱이 정한
/// 대로 지키는지 본다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runCollectionBonusSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    let full = XPModel.maxTokens

    // ── 요구된 세 점 ──
    for (count, want) in [(0, 0.0), (1, 0.05), (5, 0.25), (10, 0.50)] {
        let got = CollectionBonus.bonus(forCompleteCount: count)
        guard near(got, want) else { fail("완전체 \(count)마리 → \(got), \(want) 여야 한다") }
    }
    print("[selftest] 0마리 0% · 1마리 5% · 5마리 25% · 10마리 50%")

    // ── 상한 ──
    guard near(CollectionBonus.bonus(forCompleteCount: 11), 0.50),
          near(CollectionBonus.bonus(forCompleteCount: 36), 0.50) else {
        fail("10마리를 넘으면 50% 에서 멈춰야 한다")
    }
    print("[selftest] 11마리·36마리 → 50% (상한)")

    // ── 완전체 판정 ──
    guard CollectionBonus.isComplete(tokens: full),
          CollectionBonus.isComplete(tokens: full + 1),
          !CollectionBonus.isComplete(tokens: full - 1) else {
        fail("완전체 경계가 틀렸다 (기준 \(Int(full)))")
    }
    print("[selftest] 완전체 = 경험치 \(Int(full)) 이상")

    // ── "다른" 펫만 센다 ──
    let tokens: [String: Double] = [
        "charmander": full,         // 완전체(2진화)
        "squirtle": full * 2,       // 완전체(넘어서도 완전체)
        "ditto": full,              // 완전체 — 진화 없는 펫도 완전체가 된다(요구 2·3)
        "munchlax": full - 1,       // 하나 모자람(1진화)
        "pichu": 0,
    ]
    guard CollectionBonus.completeCount(in: tokens) == 3 else {
        fail("전체 완전체 수가 틀렸다: \(CollectionBonus.completeCount(in: tokens))")
    }
    // 완전체로 나가면 자기는 빠진다.
    guard CollectionBonus.completeCount(in: tokens, excluding: "charmander") == 2 else {
        fail("자기 자신을 셌다")
    }
    // 덜 자란 펫으로 나가면 셋 다 센다.
    guard CollectionBonus.completeCount(in: tokens, excluding: "munchlax") == 3 else {
        fail("덜 자란 펫으로 나갈 때 완전체를 빠뜨렸다")
    }
    // 진화 없는 메타몽도 완전체로 센다 — 진화 수와 무관하게 최대경험치에 도달한다(요구 2·3).
    guard CollectionBonus.isComplete(tokens: tokens["ditto"]!) else {
        fail("진화 없는 펫(메타몽)이 완전체로 안 잡힌다")
    }
    print("[selftest] 완전체 3마리 — 파이리로 나가면 2마리(+10%), 먹고자로 나가면 3마리(+15%) · 메타몽(무진화)도 완전체")

    // ── 파워에 얹기 ──
    guard near(CollectionBonus.apply(0.25, to: 0.4), 0.5) else { fail("0.4 × 1.25 가 0.5 가 아니다") }
    guard near(CollectionBonus.apply(0.50, to: 0.9), 1.0) else { fail("파워가 1 을 넘었다") }
    guard near(CollectionBonus.apply(0.50, to: 0), 0) else { fail("파워 0 에 보너스가 붙었다") }
    print("[selftest] 파워 0.4 +25% → 0.5 · 0.9 +50% → 1.0(상한) · 0 은 그대로 0")

    // 실제 대전에서 보너스가 차이를 만드는지 — 같은 시드로 보너스 전후를 겨룬다.
    let base = battlePower(tokens: full * 0.4, stage: 1)
    let boosted = CollectionBonus.apply(CollectionBonus.bonus(forCompleteCount: 10), to: base)
    var winsBase = 0, winsBoosted = 0
    for seed in UInt64(1)...UInt64(400) {
        if simulateBattle(seed: seed, powers: [.challenger: base, .accepter: base]).winner == .challenger { winsBase += 1 }
        if simulateBattle(seed: seed, powers: [.challenger: boosted, .accepter: base]).winner == .challenger { winsBoosted += 1 }
    }
    print("[selftest] 같은 펫끼리 승률 \(winsBase * 100 / 400)% → 보너스 +50% 받으면 \(winsBoosted * 100 / 400)%"
          + " (파워 \(String(format: "%.2f", base)) → \(String(format: "%.2f", boosted)))")
    guard winsBoosted > winsBase else { fail("보너스를 받아도 승률이 오르지 않는다") }

    // ── 작은 보너스도 실제로 작동하는가 ──
    //
    // 예전 피해식은 보너스를 그냥 반올림해서 파워가 0.125·0.375·0.625·0.875 경계를
    // 넘을 때만 피해가 달라졌다. 그래서 +5%(1마리)가 대부분의 파워에서 전투 결과를 한 판도
    // 바꾸지 못했는데, 위 검사는 +50% 만 봐서 통과시켰다(외부 리뷰가 잡았다).
    //
    // 1) 평균 피해가 파워에 정비례하는가 — 피해 = 1~2 굴림 + 4×파워(확률적 반올림)이므로
    //    한 방의 평균은 1.5 + 4×파워 여야 한다.
    func meanHit(_ power: Double, seeds: ClosedRange<UInt64>) -> Double {
        var total = 0, count = 0
        for seed in seeds {
            let o = simulateBattle(seed: seed, powers: [.challenger: power, .accepter: 0])
            for r in o.rounds where r.attacker == .challenger && !r.missed {
                total += r.damage; count += 1
            }
        }
        return Double(total) / Double(max(count, 1))
    }
    for p in [0.2, 0.35, 0.5, 0.7] {
        let got = meanHit(p, seeds: 1...6000)
        let want = 1.5 + 4 * p
        guard abs(got - want) < 0.06 else {
            fail("파워 \(p) 의 평균 피해 \(String(format: "%.3f", got)) — \(String(format: "%.3f", want)) 여야 한다(정비례가 깨졌다)")
        }
    }
    print("[selftest] 평균 피해 = 1.5 + 4×파워 (파워 0.2·0.35·0.5·0.7 에서 오차 0.06 이내)")

    // 2) +5%·+25% 가 넓은 파워 구간에서 승률을 실제로 올리는가. 구간마다 따로 보면 판 수가
    //    적어 흔들리므로 구간을 모두 합쳐 본다.
    func totalWins(boost: Double) -> Int {
        var wins = 0
        for step in 1...18 {
            let p = Double(step) * 0.05
            let mine = CollectionBonus.apply(boost, to: p)
            for seed in UInt64(1)...UInt64(600) {
                if simulateBattle(seed: seed, powers: [.challenger: mine, .accepter: p]).winner == .challenger { wins += 1 }
            }
        }
        return wins
    }
    let w0 = totalWins(boost: 0), w5 = totalWins(boost: 0.05), w25 = totalWins(boost: 0.25)
    let games = 18 * 600
    print("[selftest] 파워 0.05~0.90 전 구간 합산 승률: 보너스 없음 \(w0 * 1000 / games / 10)% · +5% \(w5 * 1000 / games / 10)% · +25% \(w25 * 1000 / games / 10)%")
    guard w5 > w0 else { fail("+5% 가 승률을 올리지 못한다 (\(w0) → \(w5))") }
    guard w25 > w5 else { fail("+25% 가 +5% 보다 승률이 높지 않다 (\(w5) → \(w25))") }

    // 3) 파워 1.0 은 여전히 한 방이어야 한다 — 확률적 반올림이 이 약속을 깨면 안 된다.
    for seed in UInt64(1)...UInt64(500) {
        let o = simulateBattle(seed: seed, powers: [.challenger: 1.0, .accepter: 0])
        for r in o.rounds where r.attacker == .challenger && !r.missed {
            guard r.damage >= 5 else { fail("파워 1.0 의 적중이 \(r.damage) — 한 방(5 이상)이어야 한다") }
        }
    }
    print("[selftest] 파워 1.0 의 적중은 500판 모두 5 이상 (한 방 유지)")

    // ── 마우스 오버 별 ──
    guard CollectionBonus.stars(forCompleteCount: 0) == "" else { fail("완전체 0마리인데 별이 있다") }
    guard CollectionBonus.stars(forCompleteCount: 1) == "⭐️" else { fail("1마리 → 별 하나여야 한다") }
    guard CollectionBonus.stars(forCompleteCount: 3) == "⭐️⭐️⭐️" else { fail("3마리 → 별 셋이어야 한다") }
    guard CollectionBonus.stars(forCompleteCount: 10) == String(repeating: "⭐️", count: 10) else {
        fail("10마리까지는 하나씩 늘어놓아야 한다")
    }
    guard CollectionBonus.stars(forCompleteCount: 13) == "⭐️×13" else {
        fail("10마리를 넘으면 ⭐️×N 으로 줄여야 한다: \(CollectionBonus.stars(forCompleteCount: 13))")
    }
    print("[selftest] 별: 0 → 없음 · 1 → ⭐️ · 3 → ⭐️⭐️⭐️ · 10 → 열 개 · 13 → ⭐️×13")

    print("SELFTEST PASS")
    exit(0)
}
