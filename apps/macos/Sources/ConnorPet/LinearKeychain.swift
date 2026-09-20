import Foundation
import Security

/// Linear 개인 API 키 보관소. 키는 로그인 키체인에만 두고 UserDefaults 로는 절대
/// 내려가지 않는다.
///
/// 설계는 같은 저자의 linear-peek(`~/Documents/linear-peek`)에서 가져왔다. 거기서
/// 값을 치르고 배운 것이 둘 있다.
///
/// **하나, 실행당 한 번만 읽는다.** 키체인 항목은 만든 바이너리의 코드 서명에 묶이고,
/// ad-hoc 서명은 빌드마다 바뀐다. 서명이 어긋난 항목은 읽을 때마다 암호 창을 띄우므로,
/// 호출할 때마다 읽으면 그 횟수만큼 창이 뜬다 — 5분마다 퀘스트를 훑는 이 앱에서는
/// 5분마다 암호를 묻는 셈이었다.
///
/// **둘, 갱신하지 않고 지웠다 다시 넣는다.** 기존 항목의 접근 권한은 그것을 만든
/// 빌드의 것이라 update 는 또 암호를 묻는다. 새로 넣으면 지금 실행 중인 바이너리가
/// 주인이 된다.
enum LinearKeychain {
    /// 키체인에서 찾을 이름. README 가 안내한 `security` 명령과 같아야 한다 —
    /// 터미널로 넣어 둔 사람의 키가 그대로 읽혀야 하기 때문이다.
    static var service = "connor-pet-linear"
    static let account = "linear"

    /// 키가 있는지 여부만 따로 적어 둔다. 설정 창을 열 때 "저장됨" 을 보여 주려고
    /// 키체인을 읽으면 그 순간 암호 창이 뜬다 — 값이 아니라 유무만 알면 되는 자리다.
    private static let storedFlagKey = "linearAPIKeyStored"

    static var isStored: Bool {
        get { UserDefaults.standard.bool(forKey: storedFlagKey) }
        set { UserDefaults.standard.set(newValue, forKey: storedFlagKey) }
    }

    private static let lock = NSLock()
    /// 바깥 옵셔널은 "아직 안 읽었다", 안쪽은 "읽었고 없을 수도 있다".
    private static var cached: String??

    static func read() -> String? {
        lock.lock()
        if let cached { lock.unlock(); return cached }
        lock.unlock()

        let value = readFromKeychain()

        lock.lock()
        cached = value
        lock.unlock()
        // 플래그가 생기기 전에 터미널로 넣어 둔 키도 여기서 한 번에 맞춰진다.
        isStored = (value != nil)
        return value
    }

    /// 다음 읽기가 키체인을 다시 보게 한다.
    static func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }
        guard let data = trimmed.data(using: .utf8) else { return false }

        SecItemDelete(baseQuery as CFDictionary)
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { return false }

        lock.lock()
        cached = trimmed
        lock.unlock()
        isStored = true
        return true
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        lock.lock()
        cached = .some(nil)
        lock.unlock()
        isStored = false
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func readFromKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// 캐시를 그대로 둔 채 키체인 항목만 지운다. 자체검증이 캐시가 실제로 도는지
    /// 보려고 쓴다 — 평소 경로에서는 부를 이유가 없다.
    static func deleteBypassingCacheForTest() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
