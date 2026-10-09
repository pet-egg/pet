import Foundation

/// `CONNORPET_SELFTEST=evolution swift run`. 요구 2·3 의 회귀 방지 테스트:
///
///  - **모든 펫은 진화 수와 무관하게 같은 EXP 눈금을 쓴다.** 진화가 없거나(0진화)
///    1진화뿐인 펫도 stage 1(2억)·stage 2(5억) 임계치를 그대로 밟고, 최대경험치(5억)에
///    도달한다. XPModel 은 펫을 인자로 받지 않으므로 이는 구조적으로 보장되지만, 누가
///    실수로 "진화 사슬 길이에 맞춰 눈금을 자르는" 코드를 넣으면 깨지므로 못 박아 둔다.
///  - **대전 진화보너스도 진화 수와 무관하다.** `battlePower(tokens:stage:)` 역시 펫을
///    모르고 stage 만 본다 — 0진화 펫도 stage 2 에서 +30%(파워 1.0)를 받는다.
///  - 새로 바뀐 진화 사슬(pichu→pikachu→raichu, gastly→haunter→gengar,
///    munchlax→snorlax, tepig→pignite→emboar)의 표시형 매핑이 맞는지도 확인한다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runEvolutionXPSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    let full = XPModel.maxTokens   // 5억 = 최종 진화 지점 = 바 만렙

    // ── 1) EXP 눈금은 펫·진화 수와 무관 ──
    // 임계치(2억/5억)와 만렙 판정은 토큰만 본다. 어떤 펫이든 같은 값이 나와야 한다.
    guard XPModel.stage(tokens: 0) == 0,
          XPModel.stage(tokens: 199_999_999) == 0,
          XPModel.stage(tokens: 200_000_000) == 1,
          XPModel.stage(tokens: 499_999_999) == 1,
          XPModel.stage(tokens: 500_000_000) == 2 else {
        fail("stage 임계치(2억→1, 5억→2)가 틀렸다")
    }
    // 최대경험치에서 바가 가득(퍼센트 1.0) 차는가 — 0/1/2 진화 무관하게 같다.
    guard near(XPModel.percent(tokens: full), 1.0),
          near(XPModel.percent(tokens: full * 2), 1.0) else {
        fail("최대경험치에서 바가 가득 차지 않는다")
    }
    print("[selftest] EXP 눈금: 0·2억·5억 → stage 0·1·2, 5억에서 바 만렙 (펫·진화 수 무관)")

    // ── 2) 대전 진화보너스도 진화 수와 무관 ──
    // battlePower 는 pet 을 모른다. stage 만 올리면 파워가 오르고, 최종(만렙×stage2)은
    // 정확히 1.0 이어야 한다 — 진화 사슬이 비어 있는 펫(메타몽 등)도 동일하게 받는다.
    guard near(battlePower(tokens: full, stage: 2), 1.0) else {
        fail("최대경험치 + stage 2 의 파워가 1.0 이 아니다")
    }
    let p0 = battlePower(tokens: full, stage: 0)
    let p1 = battlePower(tokens: full, stage: 1)
    let p2 = battlePower(tokens: full, stage: 2)
    guard p0 < p1, p1 < p2 else { fail("stage 가 오르는데 파워가 안 오른다 (\(p0)·\(p1)·\(p2))") }
    // 곱연산 보너스: stage1 = +15%, stage2 = +30% (1.0/1.30, 1.15/1.30, 1.30/1.30).
    guard near(p0, 1.0 / 1.30), near(p1, 1.15 / 1.30), near(p2, 1.0) else {
        fail("진화 단계 보너스가 +15%/+30% 가 아니다")
    }
    print("[selftest] 진화보너스: stage 0·1·2 → 파워 \(String(format: "%.3f", p0))·\(String(format: "%.3f", p1))·\(String(format: "%.3f", p2)) (무진화 펫도 동일)")

    // ── 3) 새 진화 사슬 표시형 매핑 ──
    // (base, stage) → 화면에 그릴 slug. 진화가 적은 펫은 마지막 진화형에 머문다(캡).
    let cases: [(base: String, stage: Int, want: String)] = [
        ("pichu", 0, "pichu"), ("pichu", 1, "pikachu"), ("pichu", 2, "raichu"),
        ("gastly", 1, "haunter"), ("gastly", 2, "gengar"),
        ("munchlax", 1, "snorlax"), ("munchlax", 2, "snorlax"),   // 1진화 — stage2 여도 캡
        ("tepig", 1, "pignite"), ("tepig", 2, "emboar"),
        ("togepi", 1, "togetic"), ("togepi", 2, "togekiss"),       // 토게피 사슬 추가
        ("ditto", 2, "ditto"),                                     // 무진화 — 항상 기본형
    ]
    for c in cases {
        let got = AppDelegate.displaySlugForTest(base: c.base, stage: c.stage)
        guard got == c.want else { fail("표시형 틀림: \(c.base) stage \(c.stage) → \(got), \(c.want) 여야 한다") }
    }
    print("[selftest] 진화 사슬: pichu·gastly·munchlax·tepig·togepi·ditto 표시형 매핑 정상")

    // ── 4) 이브이 분기 진화 ──
    // 고른 진화형이 없으면 스테이지가 올라도 이브이를 유지(사용자가 말풍선에서 고를 때까지).
    // 고르면 그 진화형으로. 8종 각각이 역매핑에서 1단계로 잡혀야 대전 파워도 맞는다.
    guard AppDelegate.displaySlugForTest(base: "eevee", stage: 2, eeveeChoice: nil) == "eevee" else {
        fail("이브이: 미선택이면 스테이지가 올라도 이브이여야 한다")
    }
    guard AppDelegate.displaySlugForTest(base: "eevee", stage: 0, eeveeChoice: "jolteon") == "eevee" else {
        fail("이브이: 선택해도 stage 0 이면 이브이여야 한다")
    }
    for forme in AppDelegate.eeveelutionSlugs {
        guard AppDelegate.displaySlugForTest(base: "eevee", stage: 1, eeveeChoice: forme) == forme else {
            fail("이브이 선택형 표시 틀림: \(forme)")
        }
        guard AppDelegate.stage(ofDisplaySlug: forme) == 1 else {
            fail("이브이 진화형 역매핑 틀림(1단계 아님): \(forme)")
        }
    }
    print("[selftest] 이브이 분기 진화: 미선택 유지 + 8종 선택/역매핑 정상")

    print("SELFTEST PASS")
    exit(0)
}
