import AppKit

/// 펫의 성별. 포켓몬 본가의 성비(gender rate)를 그대로 따른다.
///
/// 수컷은 파랑 `♂`, 암컷은 분홍 `♀`(전투 화면 UI 와 같은 색). 메타몽처럼 성별이
/// 없는 종은 `genderless` 라 기호를 안 붙인다.
enum PetGender: String {
    case male
    case female
    case genderless

    /// 이름 오른쪽에 붙일 기호. 무성이면 nil(아무것도 안 붙임).
    var symbol: String? {
        switch self {
        case .male: return "♂"
        case .female: return "♀"
        case .genderless: return nil
        }
    }

    /// 기호 색. 수컷=파랑, 암컷=분홍.
    var color: NSColor? {
        switch self {
        case .male: return NSColor(calibratedRed: 0.26, green: 0.56, blue: 1.00, alpha: 1)
        case .female: return NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.70, alpha: 1)
        case .genderless: return nil
        }
    }
}

/// 성별 배정·저장. **부화(처음 키우기 시작)할 때 한 번만** 확률로 정하고, 그 뒤로는
/// 바뀌지 않는다. 진화해도 같은 성별이어야 하므로 **기본형 slug 로 저장한다**
/// (이름 저장과 같은 규칙 — `PetNames` 참고).
///
/// 경험치(`petTokens`)와 **완전히 별도 키**라, 이미 키우던 펫도 업데이트하면 경험치는
/// 그대로 유지되고 성별만 새로 배정된다.
enum PetGenders {
    /// 암컷이 나올 확률을 8분위로 적은 값(PokeAPI `gender_rate` 와 같은 표기).
    /// `-1` = 무성. **기본형 slug 기준**이며 진화형은 기본형 값을 그대로 물려받는다.
    ///
    /// 포켓몬 본가 성비(**미진화 기본형 기준** — 진화형은 이 값을 물려받음):
    /// - 스타터·단일계열 9종(불/물/풀 스타터·이브이·토게피·뚜꾸리·먹고자) = 1/8 암컷(♂ 87.5%).
    /// - 데구리·고오스·디그다·피츄·애버라스·미뇽 계열 = 4/8(50:50).
    /// - 메타몽 = 무성.
    /// - 비숑(포켓몬 아님)은 본가 성비가 없어 50:50 으로 둔다.
    static let femaleRateByBase: [String: Int] = [
        "totodile": 1,
        "charmander": 1,
        "squirtle": 1,
        "eevee": 1,
        "chikorita": 1,
        "torchic": 1,
        "togepi": 1,
        "tepig": 1,
        "munchlax": 1,   // 먹고자→잠만보 계열(잠만보 본가 성비 1/8)
        "geodude": 4,
        "gastly": 4,     // 고오스→고우스트→팬텀 계열
        "diglett": 4,
        "pichu": 4,      // 피츄→피카츄→라이츄 계열
        "larvitar": 4,
        "dratini": 4,
        "ditto": -1,
        "bichon": 4,
        "pinkbean": -1,   // 유일 초월자(메이플) — 본가 성비가 없어 무성으로 둔다(메타몽과 같게).
    ]

    private static let key = "petGenders"

    /// 모르는 펫은 50:50 으로 본다(표에 빠뜨려도 무성이 되진 않게).
    static func femaleRate(for base: String) -> Int {
        femaleRateByBase[base] ?? 4
    }

    static func all(in defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    /// 이미 배정된 성별. 아직 안 정했으면 nil.
    static func stored(for base: String, in defaults: UserDefaults = .standard) -> PetGender? {
        all(in: defaults)[base].flatMap(PetGender.init(rawValue:))
    }

    /// 확률에 따라 성별 하나를 뽑는다(저장은 안 함). 테스트가 난수원을 주입할 수 있게 분리.
    static func roll(for base: String, rng: () -> Int = { Int.random(in: 0..<8) }) -> PetGender {
        let rate = femaleRate(for: base)
        if rate < 0 { return .genderless }
        return rng() < rate ? .female : .male
    }

    /// 화면에 쓸 성별. **처음 물어볼 때 확률로 정하고 저장**하며, 그 뒤로는 저장값을
    /// 그대로 돌려준다 — "부화 시 한 번만 결정" 규칙의 실제 구현부다.
    @discardableResult
    static func resolve(for base: String, in defaults: UserDefaults = .standard,
                        rng: () -> Int = { Int.random(in: 0..<8) }) -> PetGender {
        if let existing = stored(for: base, in: defaults) { return existing }
        let rolled = roll(for: base, rng: rng)
        var map = all(in: defaults)
        map[base] = rolled.rawValue
        defaults.set(map, forKey: key)
        return rolled
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
