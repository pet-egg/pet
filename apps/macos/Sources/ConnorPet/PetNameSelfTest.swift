import Foundation

/// `CONNORPET_SELFTEST=petname swift run`. 펫 이름 저장과 한국어 조사 선택을 확인한다.
///
/// 조사를 따로 보는 이유: 예전에는 도감 이름만 썼고 "파이리가" 처럼 모음으로 끝나는
/// 것이 많아 `가` 를 문구에 박아 두었다. 사용자가 이름을 짓게 되면 "불꽃" 처럼 받침으로
/// 끝나는 이름이 들어오고, 그대로 두면 "불꽃가 노려봅니다" 가 된다.
///
/// **사용자가 지어 둔 이름은 건드리지 않는다** — 검증용 저장소에 대고 돌린다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runPetNameSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let suite = "connor-pet.selftest.names"
    UserDefaults().removePersistentDomain(forName: suite)
    guard let store = UserDefaults(suiteName: suite) else { fail("검증용 저장소를 못 만들었다") }
    func cleanup() { UserDefaults().removePersistentDomain(forName: suite) }
    func failClean(_ why: String) -> Never { cleanup(); fail(why) }

    // ── 저장 ──
    guard PetNames.name(for: "charmander", in: store) == nil else { failClean("처음부터 이름이 있다") }
    guard PetNames.display(for: "charmander", fallback: "파이리", in: store) == "파이리" else {
        failClean("이름이 없을 때 도감 이름으로 안 떨어진다")
    }
    print("[selftest] 이름 없음 → 도감 이름 사용")

    PetNames.set("불꽃이", for: "charmander", in: store)
    guard PetNames.name(for: "charmander", in: store) == "불꽃이" else { failClean("저장이 안 된다") }
    guard PetNames.display(for: "charmander", fallback: "파이리", in: store) == "불꽃이" else {
        failClean("지어 준 이름보다 도감 이름이 이긴다")
    }
    // 펫마다 따로다 — 하나를 지었다고 다른 펫까지 바뀌면 안 된다.
    guard PetNames.name(for: "squirtle", in: store) == nil else { failClean("다른 펫까지 이름이 붙었다") }
    print("[selftest] 펫마다 따로 저장됨")

    // 공백만 넣으면 지운 것과 같아야 한다 — 입력란을 비우고 Return 을 누른 경우.
    PetNames.set("   ", for: "charmander", in: store)
    guard PetNames.name(for: "charmander", in: store) == nil else { failClean("공백이 이름으로 남았다") }
    print("[selftest] 공백만 입력 = 이름 지움")

    // 너무 긴 이름은 잘라 둔다. 알림 문구가 두 줄을 넘기면 창이 이상해진다.
    PetNames.set(String(repeating: "가", count: 40), for: "charmander", in: store)
    let long = PetNames.name(for: "charmander", in: store) ?? ""
    guard long.count == PetNames.maxLength else {
        failClean("길이 제한이 안 걸렸다: \(long.count)자")
    }
    print("[selftest] 긴 이름은 \(PetNames.maxLength)자로 자름")

    // 앱을 껐다 켠 것과 같은 상황.
    PetNames.set("꼬북이", for: "squirtle", in: store)
    guard let reopened = UserDefaults(suiteName: suite),
          PetNames.name(for: "squirtle", in: reopened) == "꼬북이" else {
        failClean("다시 읽으니 이름이 사라졌다")
    }
    print("[selftest] 다시 읽어도 그대로")

    // ── 조사 ──
    let cases: [(String, String)] = [
        ("불꽃", "이"),     // 받침 있음(ㅊ)
        ("불꽃이", "가"),   // 이름이 "이" 로 끝나면 받침이 없다 — "불꽃이가" 가 맞다
        ("파이리", "가"),   // 받침 없음
        ("꼬부기", "가"),
        ("잠만보", "가"),
        ("팬텀", "이"),
        ("리자몽", "이"),
        ("Pika", "가"),     // 한글이 아니면 받침을 알 수 없다 — 덜 어색한 쪽
        ("", "가"),         // 빈 문자열에도 터지지 않아야 한다
    ]
    for (word, want) in cases {
        let got = KoreanParticle.subject(after: word)
        guard got == want else {
            failClean("\"\(word)\" 뒤 조사가 \(got) 다 — \(want) 여야 한다")
        }
    }
    print("[selftest] 조사: " + cases.map { "\($0.0)\($0.1)" }.joined(separator: " · "))

    guard KoreanParticle.topic(after: "불꽃") == "은",
          KoreanParticle.topic(after: "파이리") == "는" else {
        failClean("은/는 선택이 틀렸다")
    }
    print("[selftest] 은/는도 확인")

    cleanup()
    // 사용자 저장소를 건드리지 않았는지 확인한다.
    guard UserDefaults().persistentDomain(forName: suite) == nil else {
        fail("검증용 저장소가 남았다")
    }
    print("[selftest] 검증용 저장소 정리 완료 (사용자 이름은 그대로)")

    print("SELFTEST PASS")
    exit(0)
}
