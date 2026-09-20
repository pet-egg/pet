import AppKit

/// `CONNORPET_SELFTEST=bundle swift run`. 지금 `.app` 번들로 도는지 판별이 맞는지 본다.
///
/// 이 판별이 전체 디스크 접근 안내를 가른다. `swift run` 은 번들 없는 맨 실행 파일을
/// 띄우는데, 그런 프로세스가 보호된 자원을 요구하면 macOS 는 권한을 **띄운 앱**에
/// 귀속시킨다 — 그래서 권한 목록에 "ConnorPet" 대신 그 앱의 버전 문자열이 뜬다.
/// 그 상태에서 설정 창을 열어 줘 봐야 체크할 항목이 없다.
///
/// 두 가지 상태를 모두 확인하려면 두 번 돌린다.
///
///   CONNORPET_SELFTEST=bundle CONNORPET_EXPECT_BUNDLE=0 swift run
///   CONNORPET_SELFTEST=bundle CONNORPET_EXPECT_BUNDLE=1 \
///     ~/Applications/ConnorPet.app/Contents/MacOS/ConnorPet
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runBundleSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let path = Bundle.main.bundlePath
    let isBundle = FullDiskAccess.isAppBundle
    print("[selftest] 실행 위치: \(path)")
    print("[selftest] .app 번들인가: \(isBundle)")

    if let expect = ProcessInfo.processInfo.environment["CONNORPET_EXPECT_BUNDLE"] {
        let want = (expect == "1")
        guard isBundle == want else {
            fail("번들 여부가 기대와 다르다 — 기대 \(want), 실제 \(isBundle)")
        }
        print("[selftest] 기대와 일치")
    }

    // 번들이 아닐 때만 안내 명령이 쓰인다. 저장소 안에서 돌고 있으면 진짜 스크립트를
    // 가리켜야 한다 — 엉뚱한 경로를 복사해 주면 붙여 넣어도 실행이 안 된다.
    let command = FullDiskAccess.makeAppCommand()
    print("[selftest] 안내 명령: \(command)")
    if !isBundle {
        guard command.contains("make_app.sh") else { fail("안내 명령에 스크립트가 없다") }
        // "bash <경로> && open ..." 에서 경로만 떼어 실제로 있는지 본다.
        let parts = command.split(separator: " ")
        if parts.count >= 2, parts[0] == "bash" {
            let script = String(parts[1])
            if script.hasPrefix("/") {
                guard FileManager.default.isReadableFile(atPath: script) else {
                    fail("안내 명령이 없는 파일을 가리킨다: \(script)")
                }
                print("[selftest] 안내 명령이 실제 스크립트를 가리킨다")
            } else {
                print("[selftest] 저장소를 못 찾아 상대 경로로 안내한다(설치본에서 정상)")
            }
        }
    }

    print("SELFTEST PASS")
    exit(0)
}
