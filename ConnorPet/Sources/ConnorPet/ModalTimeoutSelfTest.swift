import AppKit

/// `CONNORPET_SELFTEST=modal swift run` 으로 도는 헤드리스 검증. 대전 수락/거절
/// 모달에 건 자동 닫힘 타이머가 **모달 실행 중에도 실제로 발화하는지**를 확인한다.
/// NSApp.runModal 은 런루프를 `.modalPanel` 모드로 돌리는데, 기본 `.default` 모드에
/// 건 타이머는 그동안 안 뜬다 — 그래서 타이머를 `.modalPanel` 에 넣었고, 이 테스트가
/// 그 배선이 맞는지(=버튼을 누르지 않아도 timeout 으로 닫히는지) 지킨다.
func runModalTimeoutSelfTest() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    let timeout: TimeInterval = 1.5
    FileHandle.standardError.write("[selftest] 모달 자동 닫힘 테스트 (timeout=\(timeout)s, 버튼 안 누름)…\n".data(using: .utf8)!)

    let start = Date()
    let choice = BattleDialog.challenge(fromName: "테스터", timeout: timeout)
    let elapsed = Date().timeIntervalSince(start)

    var timedOut = false
    if case .timedOut = choice { timedOut = true }
    let label: String
    switch choice {
    case .accept: label = "accept"
    case .decline: label = "decline"
    case .timedOut: label = "timedOut"
    }

    // 타이머가 아예 안 떴다면 모달이 무한정 떠 있어 여기 도달하지도 못한다. 도달했다면
    // timeout 근처에서 닫혔는지(너무 이르지도, 두 배 넘게 늦지도 않게) 함께 본다.
    let onTime = elapsed >= timeout - 0.3 && elapsed <= timeout * 2.5
    let ok = timedOut && onTime
    FileHandle.standardError.write("[selftest] 결과: choice=\(label) elapsed=\(String(format: "%.2f", elapsed))s\n".data(using: .utf8)!)
    print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
    exit(ok ? 0 : 1)
}
