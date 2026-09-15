import Foundation

/// 펫마다 붙인 이름. 안 지으면 도감 이름(파이리 등)을 그대로 쓴다.
///
/// **기본형 slug 로 저장한다.** 파이리에 "불꽃이" 를 지어 두면 리자드·리자몽으로
/// 진화해도 같은 이름이어야 한다 — 진화는 같은 펫이 자란 것이지 다른 펫이 아니다.
enum PetNames {
    private static let key = "petNames"
    /// 이름 길이 상한. 말풍선과 설정 행에 들어가야 하고, 알림 문구가 두 줄을 넘기면
    /// 창이 이상해진다.
    static let maxLength = 12

    static func all(in defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    /// `slug` 에 지어 준 이름. 없으면 nil.
    static func name(for slug: String, in defaults: UserDefaults = .standard) -> String? {
        let value = all(in: defaults)[slug]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// 화면에 쓸 이름. 지어 준 이름이 없으면 `fallback`(도감 이름)을 쓴다.
    static func display(for slug: String, fallback: String,
                        in defaults: UserDefaults = .standard) -> String {
        name(for: slug, in: defaults) ?? fallback
    }

    /// 이름을 정한다. 빈 값이면 지운다 — 지우면 도감 이름으로 돌아간다.
    static func set(_ raw: String?, for slug: String, in defaults: UserDefaults = .standard) {
        var names = all(in: defaults)
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: slug)
        } else {
            names[slug] = String(trimmed.prefix(maxLength))
        }
        defaults.set(names, forKey: key)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// 한국어 조사 고르기.
///
/// 이름을 사용자가 짓게 되면서 필요해졌다. 예전에는 도감 이름만 썼고 "파이리가" 처럼
/// 모음으로 끝나는 것이 많아 `가` 를 박아 두었는데, "불꽃" 처럼 받침으로 끝나는 이름을
/// 지으면 "불꽃가 노려봅니다" 가 된다.
enum KoreanParticle {
    /// 받침이 있으면 `이`, 없으면 `가`.
    static func subject(after word: String) -> String {
        hasFinalConsonant(word) ? "이" : "가"
    }

    /// 방향/수단의 `로`·`으로`. 받침이 없거나 받침이 `ㄹ` 이면 `로`.
    ///
    /// `ㄹ` 만 예외인 것이 이 조사의 특징이다 — "서울로"(O) "서울으로"(X).
    static func direction(after word: String) -> String {
        guard let last = word.unicodeScalars.last else { return "로" }
        let value = last.value
        guard (0xAC00...0xD7A3).contains(value) else { return "로" }
        let jongseong = (value - 0xAC00) % 28
        // 종성 8번이 ㄹ 이다.
        return (jongseong == 0 || jongseong == 8) ? "로" : "으로"
    }

    /// 받침이 있으면 `은`, 없으면 `는`.
    static func topic(after word: String) -> String {
        hasFinalConsonant(word) ? "은" : "는"
    }

    /// 마지막 글자에 받침이 있는가.
    ///
    /// 한글 음절은 유니코드에서 `가`(0xAC00)부터 28개 단위로 종성이 돌아간다 —
    /// 나머지가 0 이면 받침이 없다. 한글이 아닌 글자(영문·숫자)로 끝나면 판단할
    /// 근거가 없으므로 받침 없음으로 본다. "Pika가" 가 "Pika이" 보다 덜 어색하다.
    static func hasFinalConsonant(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last else { return false }
        let value = last.value
        guard (0xAC00...0xD7A3).contains(value) else { return false }
        return (value - 0xAC00) % 28 != 0
    }
}
