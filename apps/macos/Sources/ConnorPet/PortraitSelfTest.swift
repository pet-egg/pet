import AppKit

/// `CONNORPET_SELFTEST=portrait swift run`. 노려보기 알림에 뜨는 펫 얼굴을 확인한다.
///
/// 번들에 있는 **모든** 펫에 대해 초상이 나오는지, 정사각형인지, 알파 경계를 실제로
/// 좁혀 냈는지(원본 프레임보다 작아졌는지) 본다. 크롭 규칙은 펫마다 손으로 좌표를
/// 적지 않고 알파 경계와 머리 위치로 정하므로, 새 펫이 들어와도 여기서 걸린다.
///
/// `CONNORPET_PORTRAIT_OUT=<디렉터리>` 를 주면 각 초상을 PNG 로 떨어뜨린다 — 눈으로
/// 확인할 때 쓴다. 자동 검사만으로는 "얼굴이 나왔는지" 를 알 수 없다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runPortraitSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let slugs = AppDelegate.bundledPetSlugs
    guard slugs.count >= 5 else { fail("번들 펫을 \(slugs.count)종만 찾았다 — 리소스 탐색이 깨졌다") }
    print("[selftest] 번들 펫 \(slugs.count)종")

    let outDir = ProcessInfo.processInfo.environment["CONNORPET_PORTRAIT_OUT"]
    var failures: [String] = []
    var sizes: [String] = []

    for slug in slugs {
        guard let face = PetPortrait.face(of: slug) else {
            failures.append("\(slug): 초상이 안 나왔다")
            continue
        }
        let w = Int(face.size.width), h = Int(face.size.height)
        if w != h { failures.append("\(slug): 정사각형이 아니다 (\(w)x\(h))") }
        if w < 16 { failures.append("\(slug): 너무 작다 (\(w)px)") }

        // 프레임 통째로가 아니라 알파 경계를 좁혀 냈는지. 규칙이 무력화되면 여기서 걸린다.
        if let sheet = try? AppDelegate.loadSpriteSheet(slug: slug),
           let frame = (sheet.resolvedAnimation(for: .idle) ?? sheet.animation(named: "idle"))?.images.first {
            let full = Int(min(frame.size.width, frame.size.height))
            if w >= full { failures.append("\(slug): 프레임(\(full))보다 안 좁혀졌다 (\(w))") }
        }
        sizes.append("\(slug) \(w)")

        if let outDir, let tiff = face.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(slug).png")
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir),
                                                     withIntermediateDirectories: true)
            try? png.write(to: url)
        }
    }

    guard failures.isEmpty else { fail(failures.joined(separator: "; ")) }
    print("[selftest] 전부 정사각형이고 알파 경계로 좁혀졌다")
    print("[selftest] 크기: \(sizes.prefix(8).joined(separator: ", "))\(sizes.count > 8 ? " …" : "")")

    // 우리 번들에 없는 펫(상대가 더 최신 버전일 때)은 nil 이어야 한다 — 문구만 뜬다.
    guard PetPortrait.face(of: "그런펫없음") == nil else {
        fail("없는 펫에 초상이 나왔다")
    }
    print("[selftest] 모르는 펫은 nil (문구만 뜨는 경로)")

    if let outDir { print("[selftest] PNG 를 \(outDir) 에 떨어뜨렸다") }
    print("SELFTEST PASS")
    exit(0)
}
