import Foundation

/// `CONNORPET_SELFTEST=keychain swift run`. Linear API 키 보관을 확인한다.
///
/// **사용자의 실제 키는 건드리지 않는다** — 검증용 서비스 이름으로 갈아 끼우고 돌리고,
/// 끝나면 지운다. 저장 여부 플래그도 원래 값으로 되돌린다.
///
/// 확인하는 것은 저장·읽기·삭제와, linear-peek 에서 값을 치르고 배운 두 가지다 —
/// 실행당 한 번만 읽는 캐시가 실제로 도는지, 갱신 대신 다시 넣어도 값이 바뀌는지.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runLinearKeychainSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let realService = LinearKeychain.service
    let realFlag = LinearKeychain.isStored
    LinearKeychain.service = "connor-pet-selftest-linear"
    LinearKeychain.invalidateCache()

    func cleanup() {
        LinearKeychain.delete()
        LinearKeychain.service = realService
        LinearKeychain.isStored = realFlag
        LinearKeychain.invalidateCache()
    }
    func failClean(_ why: String) -> Never {
        cleanup()
        fail(why)
    }

    print("[selftest] 검증용 서비스 \(LinearKeychain.service) 로 돌린다 (실제 키는 그대로)")
    LinearKeychain.delete()

    guard LinearKeychain.read() == nil, !LinearKeychain.isStored else {
        failClean("비어 있어야 하는데 값이 있다")
    }
    print("[selftest] 처음: 값 없음 · isStored=false")

    let fake = "lin_api_selftest_0000"
    guard LinearKeychain.save(fake) else { failClean("저장이 실패했다") }
    guard LinearKeychain.read() == fake, LinearKeychain.isStored else {
        failClean("저장한 값이 되읽히지 않는다: \(LinearKeychain.read() ?? "nil")")
    }
    print("[selftest] 저장·되읽기 · isStored=true")

    // 갱신 대신 지웠다 다시 넣는 방식이라, 두 번째 저장도 값이 바뀌어야 한다.
    let second = "lin_api_selftest_1111"
    guard LinearKeychain.save(second), LinearKeychain.read() == second else {
        failClean("덮어쓰기가 안 된다: \(LinearKeychain.read() ?? "nil")")
    }
    print("[selftest] 덮어쓰기(지웠다 다시 넣기)")

    // 캐시 확인 — 항목을 우리 API 밖에서 지워도 읽기는 캐시를 돌려줘야 한다.
    // 이게 없으면 5분마다 키체인을 두드려 그때마다 암호 창이 뜬다.
    LinearKeychain.deleteBypassingCacheForTest()
    guard LinearKeychain.read() == second else {
        failClean("캐시가 안 돈다 — 호출마다 키체인을 읽으면 암호 창이 그만큼 뜬다")
    }
    print("[selftest] 캐시: 항목이 사라져도 실행 중에는 다시 읽지 않는다")

    LinearKeychain.invalidateCache()
    guard LinearKeychain.read() == nil else { failClean("캐시를 비웠는데 값이 남았다") }
    print("[selftest] 캐시 비우면 다시 키체인을 본다")

    guard LinearKeychain.save(fake), LinearKeychain.delete(),
          LinearKeychain.read() == nil, !LinearKeychain.isStored else {
        failClean("삭제가 제대로 안 된다")
    }
    print("[selftest] 삭제 · isStored=false")

    // 빈 문자열 저장은 삭제와 같아야 한다 — 입력란을 비우고 저장을 누른 경우.
    _ = LinearKeychain.save(fake)
    _ = LinearKeychain.save("   ")
    guard LinearKeychain.read() == nil, !LinearKeychain.isStored else {
        failClean("빈 값을 저장했는데 지워지지 않았다")
    }
    print("[selftest] 빈 값 저장 = 삭제")

    cleanup()
    guard LinearKeychain.service == realService, LinearKeychain.isStored == realFlag else {
        fail("원래 설정으로 되돌리지 못했다")
    }
    print("[selftest] 원래 서비스·플래그로 복원")

    print("SELFTEST PASS")
    exit(0)
}
