import AppKit

/// `CONNORPET_SELFTEST=overlay swift run`. 말풍선·경험치 문구가 **다른 앱 위에서만**
/// 안 보이던 문제를 재는 검사.
///
/// 펫 창은 `NSWindow`, 나머지 오버레이는 `NSPanel` 이다. 패널은 `.nonactivatingPanel`
/// 을 주면 `isFloatingPanel` 이 켜지고, 그러면 AppKit 이 패널의 순서를 **앱 활성화에
/// 묶어** 관리한다. 이 앱은 `.accessory` 라 거의 활성 상태가 아니어서, 패널만 다른 앱
/// 창 뒤로 내려간다 — 바탕화면 위에서는 가릴 것이 없어 멀쩡히 보인다.
///
/// 눈으로는 "어떤 앱에서만" 이라 재현이 어려우므로, 다른 앱을 앞으로 보낸 뒤
/// **윈도우 서버가 매긴 레이어**(`kCGWindowLayer`)를 직접 읽는다. 펫과 같은 층이어야
/// 같이 보인다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runOverlayLayerSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let runner = OverlayLayerRunner(fail: fail)
    app.delegate = runner
    app.run()
    fatalError("앱이 끝났다")
}

private final class OverlayLayerRunner: NSObject, NSApplicationDelegate {
    private let fail: (String) -> Never
    private var kept: [NSWindow] = []

    init(fail: @escaping (String) -> Never) { self.fail = fail }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let anchor = NSRect(x: 300, y: 300, width: 120, height: 120)

        let pet = PetWindow(contentRect: anchor)
        pet.orderFrontRegardless()

        let bubble = SpeechBubbleWindow()
        bubble.show(text: "레이어 확인", above: anchor, duration: 60)

        let xp = XPDetailWindow()
        xp.show(text: "EXP 1 / 2 - 50%", below: anchor)

        kept = [pet, bubble, xp]

        // 다른 앱을 앞으로 보내 실제 상황을 만든다. 우리가 활성인 채로 재면
        // 패널도 멀쩡히 위에 있어서 문제가 재현되지 않는다.
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.finder" }?
            .activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let mine = Self.layers(forPID: ProcessInfo.processInfo.processIdentifier)
            // 창이 어느 스페이스에 있는지도 본다. 전체 화면 앱 위에서 안 보인다면
            // 층이 아니라 스페이스 문제일 수 있다.
            for w in self.kept {
                print("[selftest]   \(type(of: w)) onActiveSpace=\(w.isOnActiveSpace)"
                      + " visible=\(w.isVisible) 층=\(w.level.rawValue)"
                      + " 패널=\((w as? NSPanel)?.isFloatingPanel.description ?? "-")"
                      + " 비활성시숨김=\(w.hidesOnDeactivate)")
            }
            print("[selftest] 우리 앱이 앞에 있나: \(NSApp.isActive)")
            for (num, layer) in mine.sorted(by: { $0.key < $1.key }) {
                print("[selftest]   창 \(num) → 레이어 \(layer)")
            }

            func layer(of window: NSWindow) -> Int? { mine[Int(window.windowNumber)] }
            guard let petLayer = layer(of: pet) else { self.fail("펫 창을 못 찾았다") }
            guard let bubbleLayer = layer(of: bubble) else { self.fail("말풍선 창을 못 찾았다") }
            guard let xpLayer = layer(of: xp) else { self.fail("경험치 문구 창을 못 찾았다") }
            print("[selftest] 펫 \(petLayer) · 말풍선 \(bubbleLayer) · 경험치문구 \(xpLayer)")

            // 핵심: 펫과 같은 층이어야 같은 앱들 위에서 함께 보인다.
            guard bubbleLayer == petLayer, xpLayer == petLayer else {
                self.fail("펫(\(petLayer))과 층이 다르다 — 말풍선 \(bubbleLayer), 경험치문구 \(xpLayer)."
                          + " 낮은 쪽은 다른 앱 창 뒤로 내려간다")
            }
            print("[selftest] 세 창이 같은 층 — 다른 앱 위에서 함께 보인다")

            // 클릭을 통과시키는 오버레이는 펫과 **같은 종류**여야 한다.
            //
            // 층·스페이스가 같아도 몇몇 앱 위에서만 안 보인다는 제보가 있었고, 그때
            // 남아 있던 유일한 차이가 NSPanel 이었다. 클릭을 통과시키니 패널로 얻을
            // 것도 없다. 다시 패널로 돌아가면 여기서 걸린다.
            for window in [pet as NSWindow, bubble as NSWindow, xp as NSWindow] {
                if window is NSPanel {
                    self.fail("\(type(of: window)) 이 NSPanel 이다 — 펫과 같은 NSWindow 여야 한다")
                }
                // 펫은 드래그를 받아야 해서 key 가 될 수 있다. 나머지는 안 된다.
                if !(window is PetWindow), window.canBecomeKey || window.canBecomeMain {
                    self.fail("\(type(of: window)) 이 포커스를 가져갈 수 있다 — 타이핑을 뺏는다")
                }
            }
            print("[selftest] 클릭 통과 오버레이가 모두 펫과 같은 NSWindow · 포커스 안 뺏음")

            print("SELFTEST PASS")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.fail("시간 초과") }
    }

    /// 윈도우 서버가 우리 프로세스의 창들에 매긴 레이어. 창 번호 → 레이어.
    private static func layers(forPID pid: Int32) -> [Int: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var out: [Int: Int] = [:]
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int else { continue }
            out[number] = layer
        }
        return out
    }
}
