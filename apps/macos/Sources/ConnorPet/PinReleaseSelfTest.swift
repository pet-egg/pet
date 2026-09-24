import AppKit

/// `CONNORPET_SELFTEST=pin swift run`. 우클릭 메뉴로 지시한 모션이 정해진 시간 뒤
/// **스스로 풀려 에이전트 상태로 돌아가는지** 확인한다.
///
/// 예전에는 고정이 영구적이라, 한 번 눌러 둔 자세로 펫이 굳어 있어도 알아채기
/// 어려웠다. 작업이 돌아가는지 보려고 띄워 둔 물건인데 상태를 안 보여 주게 된다.
///
/// 60초를 기다리지 않도록 `CONNORPET_PIN_SECONDS` 로 유지 시간을 줄여서 돈다.
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runPinReleaseSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let hold = PetView.pinDuration
    print("[selftest] 고정 유지 시간 \(hold)초로 확인한다…")

    guard let sheet = try? AppDelegate.loadSpriteSheet(slug: "charmander") else {
        fail("스프라이트시트를 못 읽었다")
    }
    let view = PetView(spriteSheet: sheet)
    view.setBaseAnimation(.idle)

    guard view.pinnedMotion == nil else { fail("시작부터 고정돼 있다") }

    view.pin(.runningRight)
    guard view.pinnedMotion == .runningRight else {
        fail("지시했는데 고정되지 않았다: \(String(describing: view.pinnedMotion))")
    }
    print("[selftest] 모션을 고정했다: runningRight")

    // 중간에 아직 살아 있는지 한 번 본다 — 곧바로 풀려 버리면 지시가 무의미하다.
    DispatchQueue.main.asyncAfter(deadline: .now() + hold / 2) {
        guard view.pinnedMotion == .runningRight else { fail("절반 시점에 이미 풀렸다") }
        print("[selftest] 절반 시점: 아직 고정 유지 중")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + hold + 1.0) {
        guard view.pinnedMotion == nil else {
            fail("\(hold)초가 지났는데 고정이 풀리지 않았다: \(String(describing: view.pinnedMotion))")
        }
        print("[selftest] 시간이 지나 저절로 풀렸다 → 에이전트 상태로 복귀")

        // 손으로 "자동" 을 고르면 기다리지 않고 즉시 풀려야 한다.
        view.pin(.runningLeft)
        guard view.pinnedMotion == .runningLeft else { fail("두 번째 지시가 안 먹었다") }
        view.pin(nil)
        guard view.pinnedMotion == nil else { fail("\"자동\" 을 골랐는데 고정이 남았다") }
        print("[selftest] \"자동\" 선택 시 즉시 해제도 확인")

        print("SELFTEST PASS")
        exit(0)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + hold + 20) {
        fail("시간 초과")
    }
    // Timer 는 실행 루프가 있어야 돈다 — dispatchMain 만으로는 뛰지 않는다.
    RunLoop.main.run()
    fatalError("실행 루프가 끝났다")
}
