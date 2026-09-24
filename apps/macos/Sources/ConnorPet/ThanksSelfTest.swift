import AppKit

/// `CONNORPET_SELFTEST=thanks swift run`. 경험치 감사 인사의 두 가지를 확인한다.
///
/// 1. **언제 말하는가** — `ThanksThrottle` 에 시각을 넣어 가며 본다. 실제 5분을
///    기다리지 않는다.
/// 2. **어떻게 보이는가** — 경험치 말풍선을 실제로 그려 PNG 로 떨어뜨린다.
///    `CONNORPET_THANKS_SHOT=<파일>` 을 주면 저장한다. 흰 바탕에 초록 강조가
///    맞는지는 자동 검사로 알 수 없어 눈으로 봐야 한다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runThanksSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let step = ThanksThrottle.interval
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var throttle = ThanksThrottle()

    // 첫 호출은 시계만 맞춘다.
    guard throttle.add(1_000, now: t0) == nil else { fail("첫 호출에서 인사했다") }
    print("[selftest] 첫 호출: 시계만 맞추고 조용")

    // 간격 전에는 아무리 쌓여도 조용하다.
    guard throttle.add(2_000, now: t0 + step / 2) == nil else { fail("간격 전에 인사했다") }
    print("[selftest] 간격 전: 조용")

    // 간격이 지나면 그동안 모인 것을 한 번에 말한다 — 첫 호출분까지 포함해야 한다.
    guard let first = throttle.add(3_000, now: t0 + step) else { fail("간격이 지났는데 조용하다") }
    guard first == 6_000 else { fail("모인 양이 틀렸다: \(first) (1000+2000+3000 이어야 한다)") }
    print("[selftest] 간격 후: 모인 6,000 을 한 번에")

    // 말한 뒤에는 초기화된다 — 같은 양을 두 번 세면 안 된다.
    guard throttle.add(0, now: t0 + step * 2) == nil else { fail("쌓인 게 없는데 또 인사했다") }
    print("[selftest] 말한 뒤 초기화 · 쌓인 게 없으면 조용")

    // 오래 조용하다가 다시 쌓이면 그때 말한다.
    guard let second = throttle.add(500, now: t0 + step * 5) else { fail("다시 쌓였는데 조용하다") }
    guard second == 500 else { fail("두 번째 양이 틀렸다: \(second)") }
    print("[selftest] 다시 쌓이면 그때 인사")

    // 1 미만은 말하지 않는다 — "+0 EXP" 라고 인사하면 이상하다.
    var tiny = ThanksThrottle()
    _ = tiny.add(0, now: t0)
    guard tiny.add(0.4, now: t0 + step) == nil else { fail("1 미만인데 인사했다") }
    print("[selftest] 1 미만은 조용")

    // 모양 — 실제 말풍선을 그려서 남긴다.
    guard let out = ProcessInfo.processInfo.environment["CONNORPET_THANKS_SHOT"] else {
        print("SELFTEST PASS")
        exit(0)
    }
    let bubble = SpeechBubbleWindow()
    let anchor = NSRect(x: 400, y: 400, width: 120, height: 120)
    bubble.show(text: "와~! 고마워! 잘 먹었어\n+1,284,932 EXP",
                above: anchor, duration: 30, style: .reward)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        guard let view = bubble.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fail("말풍선을 그리지 못했다")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fail("PNG 로 바꾸지 못했다")
        }
        try? png.write(to: URL(fileURLWithPath: out))
        print("[selftest] 경험치 말풍선을 \(out) 에 그렸다")
        print("SELFTEST PASS")
        exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { fail("시간 초과") }
    RunLoop.main.run()
    fatalError("실행 루프가 끝났다")
}
