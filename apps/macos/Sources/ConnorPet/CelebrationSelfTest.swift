import AppKit

/// `CONNORPET_SELFTEST=celebrate swift run`. 퀘스트 축하 말풍선이 **겹치지 않고 하나씩**
/// 뜨는지 확인한다.
///
/// 예전에는 한 번에 잡힌 퀘스트를 "외 N건" 으로 접어 한 번만 말했다. 하나씩 띄우도록
/// 바꾸면서 생기는 위험은 전부 타이밍이다 — 동시에 부르면 같은 자리에 겹쳐 뒤엣것만
/// 읽히고, 간격이 0 이면 사라지는 프레임과 뜨는 프레임이 겹친다.
///
/// 그래서 `onSpeak` 호출 시각을 재서 **간격이 노출 시간만큼 벌어져 있는지** 본다.
/// 6초씩 기다리지 않도록 `CONNORPET_CELEBRATION_SECONDS` 로 줄여서 돈다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
private func isReward(_ style: BubbleStyle) -> Bool {
    if case .reward = style { return true }
    return false
}

func runCelebrationSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let hold = PetView.celebrationDuration
    let gap = PetView.celebrationGap
    print("[selftest] 노출 \(hold)초 · 간격 \(gap)초로 확인한다…")

    guard let sheet = try? AppDelegate.loadSpriteSheet(slug: "charmander") else {
        fail("스프라이트시트를 못 읽었다")
    }
    let view = PetView(spriteSheet: sheet)
    view.setBaseAnimation(.idle)

    let start = ProcessInfo.processInfo.systemUptime
    var shown: [(text: String, at: Double, style: BubbleStyle)] = []
    view.onSpeak = { text, _, style in
        shown.append((text, ProcessInfo.processInfo.systemUptime - start, style))
    }

    let texts = ["첫 번째", "두 번째", "세 번째"]
    for text in texts { view.enqueueCelebration(text) }

    // 세 개를 한꺼번에 넣었는데 첫 개만 즉시 떠야 한다. 나머지는 줄에 남는다.
    guard shown.count == 1, shown[0].text == "첫 번째" else {
        fail("한꺼번에 넣자 \(shown.count)개가 동시에 떴다: \(shown.map(\.text))")
    }
    guard view.pendingCelebrations == 2 else {
        fail("줄에 2개가 남아야 하는데 \(view.pendingCelebrations)개다")
    }
    print("[selftest] 3개를 동시에 넣어도 처음 1개만 떴다 (줄에 2개 대기)")

    DispatchQueue.main.asyncAfter(deadline: .now() + (hold + gap) * 3 + 2) {
        guard shown.count == 3 else {
            fail("3개가 다 뜨지 않았다: \(shown.count)개 \(shown.map(\.text))")
        }
        guard shown.map(\.text) == texts else {
            fail("넣은 순서와 다르다: \(shown.map(\.text))")
        }
        // 핵심 검사 — 앞엣것이 사라진 뒤에 다음이 떠야 한다.
        for i in 1..<shown.count {
            let apart = shown[i].at - shown[i - 1].at
            guard apart >= hold else {
                fail("\(i)번째와 \(i + 1)번째가 \(String(format: "%.2f", apart))초 만에 이어졌다"
                     + " — 노출 \(hold)초보다 짧아 겹친다")
            }
        }
        // 축하는 경험치 말풍선 모양이어야 한다 — 브리핑과 같은 회색으로 뜨면 무엇이
        // 올랐는지 눈에 안 들어온다.
        for entry in shown where !isReward(entry.style) {
            fail("축하가 경험치 말풍선이 아니다: \(entry.text)")
        }
        let spacing = (1..<shown.count).map { String(format: "%.1f", shown[$0].at - shown[$0 - 1].at) }
        print("[selftest] 순서대로 3개 · 간격 \(spacing.joined(separator: ", "))초 (겹침 없음)")
        guard view.pendingCelebrations == 0 else { fail("줄이 비지 않았다") }

        print("SELFTEST PASS")
        exit(0)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + (hold + gap) * 3 + 25) { fail("시간 초과") }
    RunLoop.main.run()
    fatalError("실행 루프가 끝났다")
}
