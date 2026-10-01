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
        "charmander": full,         // 완전체
        "squirtle": full * 2,       // 완전체(넘어서도 완전체)
        "pikachu": full,            // 완전체
        "eevee": full - 1,          // 하나 모자람
        "ditto": 0,
    ]
    guard CollectionBonus.completeCount(in: tokens) == 3 else {
        fail("전체 완전체 수가 틀렸다: \(CollectionBonus.completeCount(in: tokens))")
    }
    // 완전체로 나가면 자기는 빠진다.
    guard CollectionBonus.completeCount(in: tokens, excluding: "charmander") == 2 else {
        fail("자기 자신을 셌다")
    }
    // 덜 자란 펫으로 나가면 셋 다 센다.
    guard CollectionBonus.completeCount(in: tokens, excluding: "eevee") == 3 else {
        fail("덜 자란 펫으로 나갈 때 완전체를 빠뜨렸다")
    }
    print("[selftest] 완전체 3마리 — 파이리로 나가면 2마리(+10%), 이브이로 나가면 3마리(+15%)")

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
