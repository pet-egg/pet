import Foundation

/// Headless integration test for the LAN battle handshake, run via
/// `CONNORPET_SELFTEST=battle swift run`. Spins up two `BattleService`s in one
/// process (as if two Macs on the same Wi-Fi), has A discover B over Bonjour,
/// challenge it, B auto-accept, and then asserts both sides computed the *same*
/// battle (agreeing winner, opposite roles, correct opponent pet).
///
/// 그다음 2단계로 **세대가 다른 상대**를 붙인다. 결과를 각자 계산하던 시절에는
/// 한쪽만 업데이트해도 같은 시드에서 서로 다른 승자가 나와 두 화면에 동시에 WIN 이
/// 떴다. 지금은 규칙이 다르면 아예 시작하지 않아야 하고, 그것을 여기서 확인한다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runBattleSelfTest() -> Never {
    print("[selftest] starting LAN battle handshake test…")

    let serviceA = BattleService(displayName: "TesterA", petSlug: "totodile")
    let serviceB = BattleService(displayName: "TesterB", petSlug: "charmander")

    var resultA: (role: BattleRole, outcome: BattleOutcome, oppName: String, oppPet: String)?
    var resultB: (role: BattleRole, outcome: BattleOutcome, oppName: String, oppPet: String)?
    var challenged = false
    var phase1Done = false
    var peerB: BattlePeer?

    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    func evaluate() {
        guard let a = resultA, let b = resultB else { return }

        var problems: [String] = []
        if a.role != .challenger { problems.append("A should be challenger, got \(a.role)") }
        if b.role != .accepter { problems.append("B should be accepter, got \(b.role)") }
        if a.outcome != b.outcome { problems.append("outcomes differ (seed desync)") }
        if a.outcome.winner != b.outcome.winner { problems.append("winners disagree: \(a.outcome.winner) vs \(b.outcome.winner)") }
        if a.oppName != "TesterB" { problems.append("A sees wrong opponent name: \(a.oppName)") }
        if b.oppName != "TesterA" { problems.append("B sees wrong opponent name: \(b.oppName)") }
        if a.oppPet != "charmander" { problems.append("A sees wrong opponent pet: \(a.oppPet)") }
        if b.oppPet != "totodile" { problems.append("B sees wrong opponent pet: \(b.oppPet)") }

        guard problems.isEmpty else { fail(problems.joined(separator: "; ")) }

        let winnerName = a.outcome.winner == .challenger ? "TesterA" : "TesterB"
        print("[selftest] both sides agree: \(a.outcome.rounds.count) rounds, winner = \(a.outcome.winner) (\(winnerName))")

        // A 는 파워 1.0, B 는 0 이다. 파워가 실제로 전달돼 계산에 들어갔다면 A 가 이긴다 —
        // 파워 전달이 끊기면 양쪽 0 이 되어 승률이 반반으로 떨어지고 여기서 걸린다.
        guard a.outcome.winner == .challenger else {
            fail("파워 1.0 인 도전자가 졌다 — 파워가 전달되지 않은 것 같다")
        }

        phase1Done = true

        // 1.5단계: 노려보기가 실제로 상대에게 닿는지 본다. 예전에는 보내는 쪽
        // 커넥션이 곧바로 해제돼 아무것도 가지 않았고, 상대 화면은 조용했다.
        guard let b = peerB else { fail("peerB 를 못 찾았다") }
        var stareArrived = false
        serviceB.onStare = { fromName, fromPet in
            print("[selftest] B 가 노려보기를 받았다: \(fromName)/\(fromPet)")
            guard fromName == "TesterA" else { fail("노려본 사람 이름이 틀렸다: \(fromName)") }
            guard fromPet == "totodile" else { fail("노려본 펫이 틀렸다: \(fromPet)") }
            stareArrived = true
            serviceA.stop()
            serviceB.stop()
            runVersionSkewPhase(fail: fail)
        }
        print("[selftest] phase 1.5: A 가 B 를 노려본다…")
        serviceA.stare(at: b)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if !stareArrived { fail("노려보기가 10초 안에 상대에게 닿지 않았다") }
        }
    }

    serviceB.onIncomingChallenge = { fromName, respond in
        print("[selftest] B received challenge from \(fromName) → accepting")
        respond(true)
    }
    // 성장 파워를 서로 다르게 준다. 결과를 각자 계산하는 코드로 되돌아가면
    // 파워가 어긋난 순간 outcome 비교에서 걸린다.
    serviceA.localPower = { 1.0 }
    serviceB.localPower = { 0.0 }

    serviceA.onBattleStart = { role, outcome, oppName, oppPet in
        print("[selftest] A battle start: role=\(role) opp=\(oppName)/\(oppPet)")
        resultA = (role, outcome, oppName, oppPet)
        evaluate()
    }
    serviceB.onBattleStart = { role, outcome, oppName, oppPet in
        print("[selftest] B battle start: role=\(role) opp=\(oppName)/\(oppPet)")
        resultB = (role, outcome, oppName, oppPet)
        evaluate()
    }
    serviceA.onPeersChanged = { peers in
        guard !challenged, let b = peers.first(where: { $0.id == serviceB.instanceID }) else { return }
        challenged = true
        peerB = b
        print("[selftest] A discovered B (\(b.name)) → challenging")
        serviceA.challenge(b) { result in
            print("[selftest] A challenge result: \(result)")
            if case .failed = result { fail("challenge failed at transport layer") }
        }
    }

    serviceA.start()
    serviceB.start()

    // Hard timeout: if discovery or the handshake never completes, don't hang CI.
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        guard !phase1Done else { return }   // 2단계로 넘어갔으면 이 타이머는 남의 일이다
        fail("timed out after 20s (resultA=\(resultA != nil), resultB=\(resultB != nil), challenged=\(challenged))")
    }

    dispatchMain()
}

/// 2단계: 세대가 다른 두 앱을 붙여 **대전이 시작되지 않는지** 본다.
///
/// 실제로 났던 사고를 그대로 재현한다 — 한쪽만 업데이트한 상태에서 대전을 걸면
/// 각자 자기 규칙으로 계산해 두 화면에 서로 다른 승자가 떴다. 지금은 어느 쪽에서
/// 걸든 전투가 열리지 않고 "버전이 다르다" 로 끝나야 한다.
private func runVersionSkewPhase(fail: @escaping (String) -> Never) {
    // ── 전적 저장 ──
    //
    // 사용자의 실제 전적은 건드리지 않는다 — 검증용 저장소에 대고 돌린다.
    let recordSuite = "connor-pet.selftest.record"
    UserDefaults().removePersistentDomain(forName: recordSuite)
    guard let store = UserDefaults(suiteName: recordSuite) else { fail("검증용 저장소 실패") }

    guard BattleRecord.load(from: store) == BattleRecord(wins: 0, losses: 0) else {
        fail("처음 전적이 0승 0패가 아니다")
    }
    // 한 판도 안 했으면 승률이 없어야 한다. 0% 로 보여 주면 "다 졌다" 로 읽힌다.
    guard BattleRecord.load(from: store).winRate == nil else { fail("무기록인데 승률이 있다") }
    print("[selftest] 무기록: \(BattleRecord.load(from: store).summary)")

    for _ in 0..<3 { BattleRecord.record(won: true, in: store) }
    for _ in 0..<2 { BattleRecord.record(won: false, in: store) }
    let record = BattleRecord.load(from: store)
    guard record.wins == 3, record.losses == 2, record.total == 5 else {
        fail("전적이 틀렸다: \(record)")
    }
    guard let rate = record.winRate, abs(rate - 0.6) < 0.0001 else {
        fail("승률이 틀렸다: \(record.winRate ?? -1)")
    }
    guard record.summary == "3승 2패 · 승률 60%" else { fail("문구가 틀렸다: \(record.summary)") }
    print("[selftest] 3승 2패 → \(record.summary)")

    // 앱을 껐다 켠 것과 같은 상황 — 값은 UserDefaults 에 남아야 한다.
    guard let reopened = UserDefaults(suiteName: recordSuite),
          BattleRecord.load(from: reopened) == record else {
        fail("다시 읽으니 전적이 사라졌다")
    }
    print("[selftest] 다시 읽어도 그대로 (로컬에 저장됨)")

    BattleRecord.reset(in: store)
    guard BattleRecord.load(from: store).total == 0 else { fail("초기화가 안 된다") }
    UserDefaults().removePersistentDomain(forName: recordSuite)
    print("[selftest] 초기화 확인 · 보상 \(Int(BattleRecord.winReward)) EXP")

    print("[selftest] phase 2: 세대가 다른 상대와 붙여 본다…")

    let current = BattleService(displayName: "TesterNew", petSlug: "squirtle")
    let legacy = BattleService(displayName: "TesterOld", petSlug: "geodude")
    legacy.protocolVersion = battleProtocolVersion - 1   // 업데이트 전 앱을 흉내 낸다

    var noticedByCurrent = false      // 구버전이 걸어왔을 때 현재 버전이 알아챘는가
    var currentGotIncompatible = false // 현재 버전이 걸었을 때 대전이 열리지 않았는가
    var battleOpened = false
    var challengedBoth = false

    func evaluate() {
        guard noticedByCurrent && currentGotIncompatible else { return }
        // 콜백이 늦게 오는 전투 창을 놓치지 않으려고 잠깐 기다렸다가 판정한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if battleOpened { fail("세대가 다른데도 전투가 열렸다") }
            print("[selftest] 양방향 모두 대전을 시작하지 않았다")
            print("SELFTEST PASS")
            exit(0)
        }
    }



    // 어느 쪽에서든 전투가 열리면 그 자체가 실패다.
    current.onBattleStart = { _, _, _, _ in battleOpened = true }
    legacy.onBattleStart = { _, _, _, _ in battleOpened = true }
    current.onIncomingChallenge = { _, respond in respond(true) }
    legacy.onIncomingChallenge = { _, respond in respond(true) }

    current.onIncompatiblePeer = { name in
        print("[selftest] current 가 구버전 도전을 막았다: \(name)")
        noticedByCurrent = true
        evaluate()
    }

    // (2) 구버전 → 현재 버전. 받는 쪽이 막고 onIncompatiblePeer 를 띄워야 한다.
    // 핸들러는 start() 전에 걸어 둔다 — 탐색이 먼저 끝나면 나중에 걸어 봐야 안 불린다.
    var legacyChallenged = false
    legacy.onPeersChanged = { peers in
        guard !legacyChallenged, let now = peers.first(where: { $0.id == current.instanceID }) else { return }
        legacyChallenged = true
        legacy.challenge(now) { result in
            print("[selftest] legacy → current 결과: \(result)")
        }
    }

    // (1) 현재 버전 → 구버전. 상대의 accept 를 받아들이지 않아야 한다.
    current.onPeersChanged = { peers in
        guard !challengedBoth, let old = peers.first(where: { $0.id == legacy.instanceID }) else { return }
        challengedBoth = true
        // (1) 현재 버전 → 구버전. 상대의 accept 세대가 낮아 incompatible 이어야 한다.
        // 여기서 검사하는 것은 "전투가 열리지 않는다" 이지 결과 이름이 아니다.
        // 구버전 대역도 결국 우리 코드라서 세대 가드를 갖고 있어 decline 을 먼저
        // 보낸다. 가드가 없던 진짜 구버전이라면 그냥 수락하고 결과 없는 accept 를
        // 보내와서 우리 쪽 accept 가드에 걸려 incompatible 이 된다. 둘 다 통과다 —
        // 전투를 열지 않는다는 점이 같다.
        current.challenge(old) { result in
            print("[selftest] current → legacy 결과: \(result)")
            if case .accepted = result {
                fail("세대가 다른 상대에게 걸었는데 대전이 수락됐다")
            }
            currentGotIncompatible = true
            evaluate()
        }
    }

    current.start()
    legacy.start()

    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        fail("phase 2 시간 초과 (막힘 감지=\(noticedByCurrent), 거절 수신=\(currentGotIncompatible))")
    }
}
