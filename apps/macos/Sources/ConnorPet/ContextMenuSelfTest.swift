import AppKit

/// `CONNORPET_SELFTEST=contextmenu swift run`. 펫 우클릭 메뉴에 **대전·노려보기**가
/// 들어가는지, 그 하위 항목을 누르면 실제로 신청·노려보기 동작이 불리는지 확인한다.
///
/// 상대 목록과 동작은 AppDelegate 몫이라, 여기서는 그 자리에 가짜 항목을 꽂아
/// PetView 가 받아 넣는 자리·순서·활성 상태를 본다. 실제 앱 배선은
/// `CONNORPET_DEBUG_CONTEXTMENU=1 swift run` 출력으로 확인한다.
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runContextMenuSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    final class Probe: NSObject {
        var fired: [String] = []
        @objc func hit(_ sender: NSMenuItem) { fired.append(sender.representedObject as? String ?? "?") }
    }
    let probe = Probe()

    func social(_ title: String, peer: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let leaf = NSMenuItem(title: "\(peer) — \(title)", action: #selector(Probe.hit(_:)), keyEquivalent: "")
        leaf.target = probe
        leaf.representedObject = "\(title):\(peer)"
        sub.addItem(leaf)
        item.submenu = sub
        return item
    }

    guard let sheet = try? AppDelegate.loadSpriteSheet(slug: "charmander") else {
        fail("스프라이트시트를 못 읽었다")
    }
    let view = PetView(spriteSheet: sheet)
    view.setBaseAnimation(.idle)

    // 1) 연결 전 — 대전·노려보기 없이도 메뉴가 만들어져야 한다(셀프테스트·초기화 순서).
    let bare = view.makeContextMenu().items.map(\.title)
    guard !bare.contains("대전"), !bare.contains("노려보기") else { fail("연결 전에 대전 항목이 있다: \(bare)") }
    guard bare.contains("방해금지 모드"), bare.contains("나가") else { fail("기본 항목이 빠졌다: \(bare)") }

    // 2) 연결 후 — 모션 목록 다음, 방해금지 바로 앞에 대전·노려보기.
    var builds = 0
    view.onBuildSocialMenuItems = {
        builds += 1
        return [social("대전", peer: "연습상대"), social("노려보기", peer: "연습상대")]
    }
    let menu = view.makeContextMenu()
    let titles = menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    print("[selftest] 메뉴: \(titles.joined(separator: " | "))")
    guard let battle = titles.firstIndex(of: "대전"),
          let stare = titles.firstIndex(of: "노려보기"),
          let dnd = titles.firstIndex(of: "방해금지 모드"),
          let settings = titles.firstIndex(of: "설정…") else {
        fail("대전·노려보기·방해금지·설정 중 빠진 것이 있다")
    }
    guard titles[battle - 1] == "---", stare == battle + 1, dnd == stare + 1 else {
        fail("구분선 | 대전 | 노려보기 | 방해금지 순서가 아니다")
    }
    guard titles[settings - 1] == "---", settings == dnd + 2 else { fail("방해금지와 설정 사이 구분선이 없다") }
    // 모션 묶음이 그 위에 그대로 있어야 한다.
    guard titles.firstIndex(of: "자동 (에이전트 상태 따르기)").map({ $0 < battle }) == true else {
        fail("모션 목록이 대전 위에 있지 않다")
    }
    guard menu.items[battle].isEnabled, menu.items[stare].isEnabled else { fail("대전·노려보기가 잠겨 있다") }
    print("[selftest] 위치: 모션 목록 → 구분선 → 대전 · 노려보기 · 방해금지 → 구분선 → 설정 · 나가")

    // 3) 하위 항목을 누르면 신청·노려보기 동작이 실제로 불린다.
    for i in [battle, stare] {
        guard let sub = menu.items[i].submenu, sub.numberOfItems == 1 else { fail("\(titles[i]) 하위 메뉴가 없다") }
        sub.performActionForItem(at: 0)
    }
    guard probe.fired == ["대전:연습상대", "노려보기:연습상대"] else { fail("하위 항목이 동작을 부르지 않았다: \(probe.fired)") }
    print("[selftest] 하위 항목 클릭 → \(probe.fired.joined(separator: ", "))")

    // 4) 메뉴를 열 때마다 새로 만든다 — 상대 목록이 바뀌어도 낡은 목록이 뜨지 않게.
    _ = view.makeContextMenu()
    guard builds == 2 else { fail("메뉴를 열 때마다 항목을 새로 만들지 않는다 (\(builds)회)") }
    print("[selftest] 메뉴를 열 때마다 상대 목록을 새로 읽는다")

    print("SELFTEST PASS")
    exit(0)
}
