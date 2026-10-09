import AppKit

/// `CONNORPET_SELFTEST=gender swift run`. 성별 배정·저장·고정 규칙을 확인한다.
///
/// 보는 것:
/// - 무성(메타몽)은 기호 없음, 확률을 돌려도 항상 무성.
/// - 1/8·4/8 확률이 난수에 맞게 수컷/암컷으로 갈린다(난수원 주입).
/// - **부화 시 한 번만 결정** — 처음 resolve 로 정해지면 다시 물어도 그대로다.
/// - 기본형 기준 저장이라 다른 펫엔 안 번진다. 다시 읽어도 유지.
///
/// **사용자 저장소를 건드리지 않는다** — 검증용 suite 에 대고 돌린다.
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runPetGenderSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let suite = "connor-pet.selftest.genders"
    UserDefaults().removePersistentDomain(forName: suite)
    guard let store = UserDefaults(suiteName: suite) else { fail("검증용 저장소를 못 만들었다") }
    func cleanup() { UserDefaults().removePersistentDomain(forName: suite) }
    func failClean(_ why: String) -> Never { cleanup(); fail(why) }

    // ── 무성(메타몽) ──
    guard PetGender.genderless.symbol == nil else { failClean("무성에 기호가 붙는다") }
    // 난수가 뭐가 나오든 무성은 무성.
    for r in 0..<8 {
        guard PetGenders.roll(for: "ditto", rng: { r }) == .genderless else {
            failClean("메타몽이 성별을 갖는다 (rng=\(r))")
        }
    }
    print("[selftest] 메타몽 = 무성, 기호 없음")

    // ── 확률 경계(1/8 = 암컷은 rng<1 일 때만) ──
    guard PetGenders.roll(for: "charmander", rng: { 0 }) == .female,
          PetGenders.roll(for: "charmander", rng: { 1 }) == .male,
          PetGenders.roll(for: "charmander", rng: { 7 }) == .male else {
        failClean("1/8 종(파이리)의 암수 경계가 틀렸다")
    }
    // 4/8 = rng<4 면 암컷.
    guard PetGenders.roll(for: "pichu", rng: { 3 }) == .female,
          PetGenders.roll(for: "pichu", rng: { 4 }) == .male else {
        failClean("4/8 종(피츄)의 암수 경계가 틀렸다")
    }
    print("[selftest] 1/8·4/8 확률 경계 OK")

    // 기호 색이 실제로 들어 있는지(파랑/분홍 구분).
    guard PetGender.male.symbol == "♂", PetGender.female.symbol == "♀",
          PetGender.male.color != nil, PetGender.female.color != nil,
          PetGender.male.color != PetGender.female.color else {
        failClean("성별 기호/색이 비거나 같다")
    }
    print("[selftest] ♂ 파랑 · ♀ 분홍 색 구분 OK")

    // ── 부화 시 한 번만 결정 ──
    // 처음 resolve 는 난수를 쓰지만, 두 번째부터는 저장값이라 난수를 무시해야 한다.
    let first = PetGenders.resolve(for: "squirtle", in: store, rng: { 0 }) // 암컷으로 고정
    guard first == .female else { failClean("처음 배정이 난수를 안 따른다") }
    let again = PetGenders.resolve(for: "squirtle", in: store, rng: { 7 }) // 난수는 수컷이지만…
    guard again == .female else { failClean("부화 뒤에도 성별이 다시 뽑힌다") }
    print("[selftest] 부화 시 한 번만 결정, 그 뒤 고정")

    // 펫마다 따로 — 하나 정했다고 다른 펫까지 정해지면 안 된다.
    guard PetGenders.stored(for: "charmander", in: store) == nil else {
        failClean("다른 펫까지 성별이 붙었다")
    }
    print("[selftest] 펫마다 따로 저장됨")

    // 앱을 껐다 켠 것과 같은 상황 — 다시 읽어도 그대로.
    guard let reopened = UserDefaults(suiteName: suite),
          PetGenders.stored(for: "squirtle", in: reopened) == .female else {
        failClean("다시 읽으니 성별이 사라졌다")
    }
    print("[selftest] 다시 읽어도 그대로")

    cleanup()
    guard UserDefaults().persistentDomain(forName: suite) == nil else {
        fail("검증용 저장소가 남았다")
    }
    print("[selftest] 검증용 저장소 정리 완료 (사용자 성별은 그대로)")

    // 이름표 렌더 검증: 실제 호버 이름표와 같은 attributed 문자열을 PNG 로 떠서,
    // ♂ 파랑·♀ 분홍 색칠이 눈으로 확인되게 한다. 경로를 주면 거기 저장.
    if let out = ProcessInfo.processInfo.environment["CONNORPET_GENDER_RENDER"] {
        renderNameplates(to: out)
        print("[selftest] 이름표 렌더 저장: \(out)")
    }

    print("SELFTEST PASS")
    exit(0)
}

/// 호버 이름표 샘플 3종(수컷/암컷/무성)을 어두운 배경 위에 그려 PNG 로 저장한다.
/// `XPDetailWindow.attributed` 와 똑같은 문자열을 써서 실제 표시와 일치시킨다.
private func renderNameplates(to path: String) {
    let samples = [
        "파이리 ♂\nEXP 15,000,000 / 200,000,000 - 7.50%",
        "망나뇽 ♀\nEXP 480,000,000 / 500,000,000 - 96.0%",
        "메타몽\nEXP 1,200,000 / 200,000,000 - 0.60%",
    ]
    let rowH: CGFloat = 54, w: CGFloat = 320, pad: CGFloat = 12
    let size = NSSize(width: w, height: rowH * CGFloat(samples.count))
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    for (i, text) in samples.enumerated() {
        let attr = XPDetailWindow.attributed(text)
        let y = size.height - CGFloat(i + 1) * rowH + pad / 2
        // 이름표 느낌의 둥근 어두운 칩.
        let chip = NSRect(x: pad, y: y, width: w - pad * 2, height: rowH - pad)
        NSColor(calibratedWhite: 0, alpha: 0.45).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
        attr.draw(in: chip.insetBy(dx: 8, dy: 4))
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}
