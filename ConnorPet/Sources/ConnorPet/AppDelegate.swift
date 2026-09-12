import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: PetWindow?
    private var petView: PetView?
    private var statusItem: NSStatusItem?
    // 상태바 메뉴는 **한 번만** 만들어 재사용한다. 예전에는 상태가 바뀔 때마다
    // 새 NSMenu 를 만들어 `statusItem.menu` 에 통째로 갈아 끼웠는데, 메뉴가 열려
    // 추적 중인 순간(메뉴 항목 클릭 처리 도중이나 대전 피어 갱신이 비동기로 끼어들
    // 때)에 갈아 끼우면 AppKit 이 아직 쓰고 있던 옛 메뉴가 해제돼 objc_msgSend 가
    // 죽은 객체를 건드려 크래시 났다("진화 사용" 클릭 시 앱 종료 버그). 이제는 이
    // 인스턴스를 계속 두고, 델리게이트의 menuNeedsUpdate(열리기 직전, 추적 전에
    // 불림)에서만 항목을 다시 채운다.
    private let statusMenu = NSMenu()
    // In-app updater (Sparkle). Only created for packaged builds that carry a
    // SUFeedURL — see UpdaterManager.isConfigured. `updateAvailable`/`updateVersion`
    // are driven by the silent launch check and reflected in the menu.
    private var updater: UpdaterManager?
    private var updateAvailable = false
    private var updateVersion: String?
    private var bubble: SpeechBubbleWindow?
    private var flame: FlameWindow?
    private var xpDetailWindow: XPDetailWindow?
    private var xpHovering = false
    private var flameAspect: CGFloat = 1.47

    // 브리핑 범위는 2단이다.
    //   1순위 — 최근 3시간 안에 쓴 세션. "지금 하던 일"이 이 안에 있다.
    //   2순위 — 1순위가 하나도 없을 때만, 48시간까지 넓혀서 3개.
    // 1순위에 상한 5를 둔 건 말풍선 글자 예산(세션당 100자 / 합계 500자)이
    // 어차피 다섯 줄에서 끊기기 때문이다. 더 뽑아 봐야 버려진다.
    private let briefPrimaryHours: Double = 3
    private let briefPrimaryLimit = 5
    private let briefFallbackHours: Double = 48
    private let briefFallbackLimit = 3
    private let briefCharsPerSession = 100
    /// 각 방에서 **얼마 전까지의 대화**를 요약 재료로 삼을지. 세션을 고르는 창과는
    /// 별개다 — 3시간 안에 만진 방이라도 하루치 대화를 놓고 진행 상태를 판단한다.
    private let briefConversationHours: Double = 24
    private let briefCharBudget = 500
    private var watcher: AgentStatusWatching?

    // LAN battle: discovers other running copies on the same Wi-Fi and runs the
    // challenge/accept handshake. Peers drive the "대전" submenu; an incoming
    // challenge pops an accept/decline alert; an agreed battle opens a window.
    private var battleService: BattleService?
    private var battlePeers: [BattlePeer] = []
    private var battleWindow: BattleWindow?
    private var pendingChallengeAlert = false

    // 대전이 업무를 방해하지 않게, 신청 흐름을 두 단계로 나눈다.
    //   신청한 쪽 — 펫 위에 20초 카운트다운 막대(challengeCountdown)를 띄우고,
    //     그 안에 응답이 없으면 "응답하지 않음" 모달을 띄운다.
    //   신청받은 쪽 — 처음엔 가운데 모달이 아니라 펫 오른쪽 위에 작은 "Challenge"
    //     말풍선(challengeBubble)만 10초 띄우고, 눌러야 예전 수락/거절 모달이 뜬다.
    private var challengeBubble: ChallengeBubbleWindow?
    private var challengeCountdown: ChallengeCountdownWindow?
    // 노려보기를 받았을 때 펫 옆에 뜨는 작은 말풍선(펫 도트 + 문구). 누르면 얼굴이
    // 큼직하게 뜨는 모달로 이어진다. 대전 신청 말풍선과 같은 클릭-가능 패널이다.
    private var stareBubble: StareBubbleWindow?
    private var pendingChallengeBubble = false
    private let challengeWaitSeconds: TimeInterval = 20   // 신청자 카운트다운(막대)
    private let challengeBubbleSeconds: TimeInterval = 10 // 신청받은 쪽 말풍선 노출
    private let challengeModalSeconds: TimeInterval = 10  // 말풍선을 누른 뒤 뜨는 수락/거절 모달

    // 펫 우클릭 › "설정…"으로 여는 창. 메뉴바 아이템에 흩어져 있던 기능을 한 곳에
    // 모아, 메뉴바가 가려 접근 못 하는 사용자도 쓸 수 있게 하는 두 번째 진입점.
    private var settingsController: SettingsWindowController?

    // Orca's own default (PET_SIZE_DEFAULT=180) still read as "big" next to the
    // small nav-badge-style pet icon the user is comparing against — sized
    // near Orca's PET_SIZE_MIN=60 floor instead.
    private let petSize: CGFloat = 90

    // 펫마다 pet.json 의 프레임 크기가 다를 수 있다 — 파이리는 불뿜기 불길이
    // 나갈 자리가 필요해서 320px 를 쓴다(다른 펫은 200px). 창을 petSize 로 고정하면
    // 프레임이 큰 펫만 캐릭터가 작게 그려지므로, 창 크기를 프레임 비율만큼 키워
    // **화면에 찍히는 캐릭터 크기를 펫마다 같게** 맞춘다.
    private static let referenceFrameWidth: CGFloat = 200

    private func windowSize(for sheet: SpriteSheet) -> CGFloat {
        (petSize * CGFloat(sheet.manifest.frame.width) / Self.referenceFrameWidth).rounded()
    }

    // Every bundled pet lives at Resources/pets/<slug>/{spritesheet.png,pet.json}
    // (see scripts/build_sheet.py's PETS list, which is the source of truth for
    // this set). Display names shown in the menu come from each pet's own
    // manifest rather than being duplicated here.
    private static let availablePetSlugs = ["totodile", "ditto", "charmander", "squirtle", "geodude", "eevee", "chikorita", "torchic", "togepi", "tepig", "snorlax", "gengar", "diglett", "pikachu"]

    /// 번들에 들어 있는 **모든** 펫 slug — 메뉴에 안 뜨는 진화형까지. 상대가 진화한
    /// 펫으로 노려볼 수 있으므로 초상 검증은 이 목록 전체를 봐야 한다.
    static var bundledPetSlugs: [String] {
        guard let root = resourceBundle.resourceURL?.appendingPathComponent("pets"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return availablePetSlugs }
        let fm = FileManager.default
        return names.filter {
            fm.fileExists(atPath: root.appendingPathComponent($0)
                .appendingPathComponent("pet.json").path)
        }.sorted()
    }
    private var petDisplayNames: [String: String] = [:]
    private var selectedPetSlug = availablePetSlugs[0]

    // Which live status source drives the pet's animation. "claude-desktop" reads
    // the Claude desktop app's Accessibility tree (+ Notification Center DB) via
    // ClaudeDesktopStatusWatcher; "claude-code" polls ~/.claude/sessions/*.json
    // every 250ms; "orca" polls Orca's last-status.json every 1s. This order is
    // used *everywhere* — menu-bar picker, settings, and the first-run wizard:
    // Claude Desktop, then Claude Code, then Orca. [0] is also the default source.
    private static let availableStatusSources = ["claude-desktop", "claude-code", "orca"]
    private static let statusSourceDisplayNames = [
        "claude-code": "Claude Code",
        "claude-desktop": "Claude Desktop",
        "orca": "Orca",
    ]
    private var selectedStatusSource = availableStatusSources[0]

    // Evolution chains keyed by the base pet the user picks: stage 1 → first
    // evolution, stage 2 → second (see XPModel.stage). The evolved forms are
    // bundled just like the base pets (scripts/build_sheet.py builds them from
    // each next PokéDex form) but aren't offered in the picker — evolution is
    // automatic, driven by token-usage XP. Ditto and Togepi have no evolution.
    private static let evolutionChains: [String: [String]] = [
        "totodile": ["croconaw", "feraligatr"],
        "charmander": ["charmeleon", "charizard"],
        "squirtle": ["wartortle", "blastoise"],
        "geodude": ["graveler", "golem"],
        "chikorita": ["bayleef", "meganium"],
        "torchic": ["combusken", "blaziken"],
        "eevee": ["vaporeon"],
        "diglett": ["dugtrio"],
        "pikachu": ["raichu"],
        "ditto": [],
        "togepi": [],
        "snorlax": [],
        "gengar": [],
    ]

    // Whether the pet evolves at all (menu toggle). When off it stays the base
    // form regardless of XP. Default off.
    private var evolutionEnabled = false

    // Whether the XP bar is always shown vs. only on hover (menu toggle). Default off.
    private var barAlwaysVisible = false

    // 방해금지 모드. 켜지면 같은 Wi-Fi 상대가 거는 대전·노려보기를 받지 않고,
    // 그 사실을 광고해 상대 앱이 신청 버튼을 잠그게 한다. 보내는 쪽(내가 거는 것)은
    // 막지 않는다. Default off. 메뉴바·우클릭·설정창 어디서든 켤 수 있다.
    private var dndEnabled = false
    // Live XP state, so re-selecting a pet re-derives the right evolved form.
    private var currentStage = 0
    private var currentPercent: Double = 0

    /// 펫별 누적 경험치(토큰). 그 펫이 화면에 있는 동안 발생한 토큰만 들어간다.
    private var petTokens: [String: Double] = [:]
    /// 폴링마다 UserDefaults 에 쓰면 초당 몇 번씩 디스크를 건드린다. 값은 메모리에
    /// 두고 주기적으로만 내려쓰고, 종료 시 한 번 더 확실히 쓴다.
    private var tokenSaveTimer: Timer?
    private var questService: QuestService?
    /// Linear 키의 마지막 확인 결과. 설정 창이 보여 준다.
    private var linearStatus: String?

    /// 언제 고맙다고 말할지 정하는 계산기. 규칙과 검증은 `ThanksThrottle` 에 있다.
    private var thanks = ThanksThrottle()
    /// Linear 를 아직 안 붙였을 때 권하는 주기.
    private var linearNudge = PeriodicReminder(interval: ThanksThrottle.interval)
    /// 최근에 깬 퀘스트. 메뉴 목록에만 쓰고, 경험치는 지급 즉시 펫에 들어간다.
    private var recentQuests: [Quest] = []
    private var currentDisplaySlug = ""
    private var sheetCache: [String: SpriteSheet] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar utility, no Dock icon
        // ⌘V 같은 단축키는 메인 메뉴를 뒤져서 처리된다. 이 앱은 메뉴 막대를 그리지
        // 않지만, 메뉴 자체가 없으면 설정 창 입력란에 붙여넣기가 안 된다.
        EditMenu.install()

        for slug in Self.availablePetSlugs {
            if let sheet = try? Self.loadSpriteSheet(slug: slug) {
                petDisplayNames[slug] = sheet.manifest.displayName ?? slug
            }
        }

        selectedPetSlug = Self.savedPetSlug(
            fallback: Self.availablePetSlugs.first ?? "totodile",
            validSlugs: Set(petDisplayNames.keys)
        )
        // Test hook: force a specific pet (two instances share one UserDefaults
        // domain, so this lets a headless battle run mismatched characters).
        if let forced = ProcessInfo.processInfo.environment["CONNORPET_PET"],
           petDisplayNames.keys.contains(forced) {
            selectedPetSlug = forced
        }

        // Which source drives the pet — read now (before the first-run wizard) so
        // that dismissing the wizard keeps this saved/default value.
        selectedStatusSource = Self.savedStatusSource(fallback: Self.availableStatusSources[0])

        // 첫 실행(설치 후 최초 1회, 재실행은 X)에만 뜨는 마법사: ①펫 고르기(이미지)
        // → ②사용하는 앱 고르기. 고른 값을 selectedPetSlug/selectedStatusSource 에
        // 반영·저장하고, 이후엔 저장된 값을 그대로 복원한다.
        maybeRunFirstRunWizard()

        guard let sheet = try? Self.loadSpriteSheet(slug: selectedPetSlug) else {
            fatalError("connor-pet: bundled pet '\(selectedPetSlug)' not found")
        }

        // 창 너비는 그 펫의 프레임 크기에 비례한다(파이리·꼬부기는 400px 프레임이라
        // 다른 펫의 두 배). 높이는 거기에 경험치 바가 앉을 띠를 더한 것이다.
        let size = windowSize(for: sheet)
        let viewHeight = size + PetView.barAreaHeight
        // Why: NSScreen.main resolves from the key window, which doesn't exist
        // yet during applicationDidFinishLaunching — it can silently return an
        // unexpected screen (observed: a stale/secondary one with a negative
        // origin, placing the window off-screen). screens.first is always the
        // primary display, origin (0,0), independent of window/key state.
        let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = CGPoint(x: screenFrame.maxX - size - 48, y: screenFrame.minY + 48)
        let origin = Self.savedOrigin(fallback: defaultOrigin)
        let contentRect = NSRect(x: origin.x, y: origin.y, width: size, height: viewHeight)

        currentDisplaySlug = selectedPetSlug
        sheetCache[selectedPetSlug] = sheet

        let win = PetWindow(contentRect: contentRect)
        let view = PetView(spriteSheet: sheet)
        view.frame = NSRect(x: 0, y: 0, width: size, height: viewHeight)
        barAlwaysVisible = Self.savedBarAlwaysVisible(fallback: false)
        view.setBarAlwaysVisible(barAlwaysVisible)
        dndEnabled = Self.savedDNDEnabled(fallback: false)
        view.dndEnabled = dndEnabled
        evolutionEnabled = Self.savedEvolutionEnabled(fallback: false)
        // 실행 방식이 바뀌면 UserDefaults 도메인이 갈려 경험치가 사라진 것처럼 보인다.
        // 예전 도메인에 값이 남아 있으면 한 번만 가져온다(XPMigration 참고).
        if let moved = XPMigration.runIfNeeded() {
            questLog(moved)
        }
        petTokens = Self.savedPetTokens()
        view.onRequestWindowMove = { [weak win, weak self] newOrigin in
            win?.setFrameOrigin(newOrigin)
            Self.saveOrigin(newOrigin)
            self?.bubble?.hide() // the bubble does not follow a drag; drop it
            self?.flame?.hide()  // 불길도 창을 따라오지 않는다
            self?.xpDetailWindow?.hide()
        }
        view.onClick = { [weak self] in self?.briefingText() }
        view.onSpeak = { [weak self] text, duration, style in
            guard let self, let petFrame = self.window?.frame else { return }
            self.bubble?.show(text: text, above: petFrame, duration: duration, style: style)
        }
        view.onSilence = { [weak self] in self?.bubble?.hide() }
        view.onFlameFrame = { [weak self] mouthInFrame, grow in
            guard let self else { return }
            guard grow > 0, let flame = self.flame, let win = self.window,
                  let sheet = self.petView?.currentSpriteSheet else {
                self.flame?.hide()
                return
            }
            // 매니페스트 좌표는 프레임(예: 200px) 기준이고 창은 pt 단위다.
            // 두 좌표계의 비율로 환산한다. AppKit 의 y 는 위로 자라므로 뒤집는다.
            let scale = win.frame.width / CGFloat(sheet.manifest.frame.width)
            let mouth = CGPoint(
                x: win.frame.minX + mouthInFrame.x * scale,
                y: win.frame.maxY - mouthInFrame.y * scale
            )
            let length = win.frame.width * FlameWindow.lengthMultiplier(forStage: self.currentStage) * grow
            flame.show(mouth: mouth, length: length, aspect: self.flameAspect)
            if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
                FileHandle.standardError.write("[connor-pet] 이펙트 grow=\(grow) 길이=\(Int(length))pt\n".data(using: .utf8)!)
            }
        }
        view.onSkillUsed = { [weak self] in
            Self.saveFireBreathAt(Date())
            guard let self, let petFrame = self.window?.frame else { return }
            // 이 콜백은 속성기를 실제로 쓴 직후에만 불리므로 noun 은 항상 있다.
            let noun = self.currentSkillNoun ?? "한 방"
            self.bubble?.show(text: "\(noun) 뿜었다! 여기까지 정리하고 앞으로 할 일만 볼게.",
                              above: petFrame, duration: 3.5)
        }
        view.onHoverEnter = { [weak self] in
            self?.watcher?.acknowledgeDone()
        }
        view.onOpenSettings = { [weak self] in self?.openSettingsWindow() }
        view.onToggleDND = { [weak self] in self?.toggleDND() }
        view.onHoverChanged = { [weak self] on in
            self?.xpHovering = on
            self?.updateXPDetailWindow()
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)

        window = win
        petView = view
        bubble = SpeechBubbleWindow()
        xpDetailWindow = XPDetailWindow()
        challengeBubble = ChallengeBubbleWindow()
        challengeCountdown = ChallengeCountdownWindow()
        stareBubble = StareBubbleWindow()
        loadSkillEffect(for: sheet)

        setUpStatusItem()
        setUpUpdater()

        // selectedStatusSource was resolved (and possibly set by the first-run
        // wizard) before the window was built — just start its watcher.
        startWatcher(for: selectedStatusSource)

        startBattleService()
        startQuestService()

        // 디버그 전용: 설정창 레이아웃을 PNG 로 떠서 확인하고 곧장 종료한다.
        if let path = ProcessInfo.processInfo.environment["CONNORPET_DEBUG_SETTINGS"] {
            let controller = SettingsWindowController()
            controller.delegate = self
            controller.debugRenderPNG(to: path)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        // 디버그 전용: 노려보기 말풍선(펫 도트 + 문구)을 PNG 로 떠서 확인하고 종료한다.
        // 말풍선 도트는 **노려본 상대의 펫**이므로, 내 펫이 아니라 상대 펫 slug 를
        // 쓴다(CONNORPET_STARE_FROM 으로 지정, 없으면 내 펫으로 대체).
        if let path = ProcessInfo.processInfo.environment["CONNORPET_DEBUG_STARE"] {
            let fromPet = ProcessInfo.processInfo.environment["CONNORPET_STARE_FROM"] ?? selectedPetSlug
            presentStare(fromName: "연습상대", fromPet: fromPet)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if let view = self?.stareBubble?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }

        // 설정 창이 실제로 **눈에 보이게** 뜨는지 확인한다: CONNORPET_SETTINGS_CHECK=1.
        //
        // 창을 만드는 것만으로는 부족하다. 이 앱은 .accessory 라 메뉴 막대 항목을
        // 눌러도 앱이 활성화되지 않을 때가 있고, 그러면 창이 다른 앱 뒤에 깔려
        // "안 뜬" 것처럼 보인다. 실측에서 같은 코드가 실행마다 갈렸다 — 세 번 중
        // 두 번은 포커스를 받고 한 번은 못 받았다. 간헐적이라 눈으로는 못 잡는다.
        //
        // 그래서 다른 앱을 앞으로 보내 실제 조건을 만든 뒤, 메뉴 항목의 동작을
        // 그대로 보내고(사용자가 누르는 것이 그것이다) 결과를 본다. 판정 기준은
        // 포커스가 아니라 **보이느냐**다 — 포커스를 못 받아도 떠 있는 층에 있으면
        // 눈에는 보인다.
        //
        // 자체검증 진입점(main.swift)이 아니라 여기 있는 이유: 설정 창은 진짜
        // AppDelegate 를 위임자로 요구하는데, 그것을 흉내 내면 정작 확인하려는
        // 실제 경로가 아니게 된다.
        if ProcessInfo.processInfo.environment["CONNORPET_SETTINGS_CHECK"] != nil {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.finder" }?
                .activate()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                print("[selftest] 열기 직전 우리 앱이 앞에 있었나: \(NSApp.isActive)")
                guard let menu = self?.statusItem?.menu else {
                    print("SELFTEST FAIL: 메뉴바 메뉴가 없다")
                    exit(1)
                }
                self?.menuNeedsUpdate(menu)
                guard let item = menu.items.first(where: { $0.title == "설정…" }),
                      let action = item.action, item.isEnabled else {
                    print("SELFTEST FAIL: 메뉴바에 쓸 수 있는 \"설정…\" 항목이 없다")
                    exit(1)
                }
                guard NSApp.sendAction(action, to: item.target, from: item) else {
                    print("SELFTEST FAIL: \"설정…\" 동작을 받아 줄 대상이 없다")
                    exit(1)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let win = NSApp.windows.first(where: { $0.title == "ConnorPet 설정" }) else {
                        print("SELFTEST FAIL: 설정 창이 만들어지지 않았다")
                        exit(1)
                    }
                    let key = win.isKeyWindow
                    let floating = win.level.rawValue >= NSWindow.Level.floating.rawValue
                    print("[selftest] 보임=\(win.isVisible) 포커스=\(key) 층=\(win.level.rawValue)")
                    guard win.isVisible, key || floating else {
                        print("SELFTEST FAIL: 포커스도 없고 보통 층이다 — 다른 앱 뒤에 깔린다")
                        exit(1)
                    }
                    print("SELFTEST PASS")
                    exit(0)
                }
            }
        }

        // 첫 클릭이 원문 발췌로 떨어지지 않도록, 뜨자마자 한 번 요약해 둔다.
        // 클릭과 똑같은 선택 로직을 쓴다.
        let warmup = currentBriefs()
        BriefingSummarizer.refresh(briefs: warmup.briefs,
                                   perBriefChars: briefCharsPerSession,
                                   windowHours: warmup.windowHours)

        if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
            let text = briefingText() ?? "(브리핑 없음)"
            FileHandle.standardError.write("[connor-pet] 클릭 브리핑 미리보기 (\(text.count)자):\n\(text)\n".data(using: .utf8)!)
            // 클릭 없이도 말풍선 레이아웃을 눈으로 확인할 수 있게 바로 한 번 띄운다.
            // 불뿜기를 한 번 재생해 불길 창 좌표를 눈으로 확인할 수 있게 한다.
            if ProcessInfo.processInfo.environment["CONNORPET_DEBUG_BREATH"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, let row = self.petView?.currentSpriteSheet.manifest.skill?.row,
                          let name = PetAnimationName(rawValue: row) else {
                        FileHandle.standardError.write("[connor-pet] 이 펫에는 속성기가 없다\n".data(using: .utf8)!)
                        return
                    }
                    let ok = self.petView?.playOnce(name) ?? false
                    FileHandle.standardError.write("[connor-pet] 속성기 \(row) 재생=\(ok) flame창=\(self.flame != nil)\n".data(using: .utf8)!)
                }
            }
            if let petFrame = window?.frame {
                bubble?.show(text: text, above: petFrame, duration: 60)
                // 화면 캡처 권한 없이도 말풍선 레이아웃을 확인할 수 있게, 뷰를 그대로
                // PNG 로 떠서 남긴다. CONNORPET_DEBUG_SHOT 에 경로를 주면 저장된다.
                if let path = ProcessInfo.processInfo.environment["CONNORPET_DEBUG_SHOT"],
                   let view = bubble?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                        FileHandle.standardError.write("[connor-pet] 말풍선 렌더 저장: \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))\n".data(using: .utf8)!)
                    }
                }
            }
        }
    }

    // MARK: - LAN battle wiring

    private func startBattleService() {
        let service = BattleService(petSlug: selectedPetSlug, dndEnabled: dndEnabled)
        service.onPeersChanged = { [weak self] peers in
            self?.battlePeers = peers
            self?.statusDidChange()
            self?.maybeAutoChallenge()
        }
        service.onIncomingChallenge = { [weak self] fromName, respond in
            self?.presentIncomingChallenge(fromName: fromName, respond: respond)
        }
        service.onBattleStart = { [weak self] myRole, outcome, oppName, oppPet in
            self?.presentBattle(myRole: myRole, outcome: outcome, opponentName: oppName, opponentPet: oppPet)
        }
        // 전투 계산에 들어갈 내 성장 파워. 지금 화면에 있는 펫 기준이다.
        service.localPower = { [weak self] in
            guard let self else { return 0 }
            let tokens = self.petTokens[self.selectedPetSlug] ?? 0
            let stage = self.evolutionEnabled ? XPModel.stage(tokens: tokens) : 0
            return battlePower(tokens: tokens, stage: stage)
        }
        service.onStare = { [weak self] fromName, fromPet in
            self?.presentStare(fromName: fromName, fromPet: fromPet)
        }
        service.onIncompatiblePeer = { [weak self] fromName in
            self?.showInfo(title: "버전이 달라요",
                           text: "\(fromName)님이 대전을 걸었지만 앱 버전이 달라 시작하지 못했어요.\n양쪽 모두 최신 버전으로 업데이트해 주세요.")
        }
        service.start()
        battleService = service
    }

    // Test hook: when CONNORPET_BATTLE_AUTOCHALLENGE is set, challenge the first
    // discovered peer automatically (drives two real instances without clicks).
    private func maybeAutoChallenge() {
        guard ProcessInfo.processInfo.environment["CONNORPET_BATTLE_AUTOCHALLENGE"] != nil,
              battleWindow == nil, let peer = battlePeers.first, let service = battleService else { return }
        service.challenge(peer) { _ in }
    }

    @objc private func challengePeer(_ sender: NSMenuItem) {
        guard let peerID = sender.representedObject as? String else { return }
        challenge(peerID: peerID)
    }

    /// 메뉴바·설정창 공통 진입점.
    private func challenge(peerID: String) {
        guard let peer = battlePeers.first(where: { $0.id == peerID }),
              let service = battleService else { return }
        // 방해금지 중인 상대에겐 걸지 않는다(UI 가 이미 잠갔지만 목록이 낡았을 수 있다).
        guard !peer.dnd else { return }
        // Avoid stacking battles / duplicate countdowns.
        guard battleWindow == nil, challengeCountdown?.isShowing != true else { return }
        // 신청자는 20초 카운트다운 막대를 본다. 그 안에 상대가 수락/거절하면 아래
        // 콜백이 먼저 와서 막대를 감추고, 아무 응답이 없으면 네트워크가 시간이 다 돼
        // .failed 를 돌려주고 "응답하지 않음" 모달로 이어진다.
        if let petFrame = window?.frame {
            challengeCountdown?.show(peerName: peer.name, above: petFrame, duration: challengeWaitSeconds)
        }
        service.challenge(peer) { [weak self] result in
            self?.challengeCountdown?.hide()
            switch result {
            case .accepted:
                break // onBattleStart opens the window
            case .declined:
                self?.showInfo(title: "대전 거절됨", text: "\(peer.name)님이 대전을 거절했어요.")
            case .failed:
                    // 무응답(20초 카운트다운 막대가 다 지남)이나 연결 실패는 조용히 끝낸다.
                    // 막대 자체가 이미 진행 상황을 보여줬으므로, 업무 중에 가운데 모달을
                    // 또 띄우지 않는다("업무 방해 없이" 원칙). 막대만 사라진다.
                    break
                case .incompatible:
                    // 이쪽은 알려 준다. 조용히 끝내면 왜 대전이 안 되는지 알 수가 없고,
                    // 양쪽 다 업데이트해야 한다는 것은 사용자가 조치할 수 있는 일이다.
                    self?.showInfo(title: "버전이 달라요",
                                   text: "\(peer.name)님의 앱이 다른 버전이라 대전할 수 없어요.\n양쪽 모두 최신 버전으로 업데이트해 주세요.")
            }
        }
    }

    private func presentIncomingChallenge(fromName: String, respond: @escaping (Bool) -> Void) {
        // Test hook: auto-accept without a modal (used to drive two real
        // instances headlessly — see README dev notes).
        if ProcessInfo.processInfo.environment["CONNORPET_BATTLE_AUTOACCEPT"] != nil {
            respond(battleWindow == nil)
            return
        }
        // If we're already in / setting up a battle (or handling another
        // challenge), auto-decline.
        guard battleWindow == nil, !pendingChallengeBubble, !pendingChallengeAlert,
              let petFrame = window?.frame else { respond(false); return }

        // 업무 중 갑자기 가운데 모달이 뜨는 걸 막으려고, 먼저 펫 오른쪽 위에 작은
        // "Challenge" 말풍선만 10초 띄운다. 누르면 예전처럼 가운데 수락/거절 모달로
        // 이어지고, 누르지 않고 시간이 지나면 응답을 보내지 않는다(무응답).
        pendingChallengeBubble = true
        challengeBubble?.onClick = { [weak self] in
            guard let self else { return }
            self.pendingChallengeBubble = false
            // Custom game-styled modal (a bold "BATTLE" banner instead of NSAlert's
            // generic folder/app icon) — see BattleChallengeDialog. 10초 안에
            // 응답하지 않으면 스스로 닫히고, 말풍선을 무시했을 때와 똑같이 무응답으로
            // 처리한다(신청자 카운트다운이 "응답하지 않음"으로 마무리).
            self.pendingChallengeAlert = true
            let choice = BattleDialog.challenge(fromName: fromName, timeout: self.challengeModalSeconds)
            self.pendingChallengeAlert = false
            switch choice {
            case .accept: respond(true)
            case .decline: respond(false)
            case .timedOut: break // 무응답
            }
        }
        challengeBubble?.show(above: petFrame, duration: challengeBubbleSeconds) { [weak self] in
            // 시간이 지나도록 누르지 않음 = 무응답. 응답을 보내지 않아, 신청자 쪽은
            // 카운트다운이 끝나며 "응답하지 않음" 안내를 받는다.
            self?.pendingChallengeBubble = false
        }
    }

    private func presentBattle(myRole: BattleRole, outcome: BattleOutcome, opponentName: String, opponentPet: String) {
        guard battleWindow == nil else { return }
        guard let mySheet = try? Self.loadSpriteSheet(slug: selectedPetSlug) else { return }
        // Fall back to our own sheet if the opponent's pet isn't bundled here.
        let oppSheet = (try? Self.loadSpriteSheet(slug: opponentPet)) ?? mySheet

        let view = BattleView(
            mySheet: mySheet,
            oppSheet: oppSheet,
            myName: "나",
            oppName: opponentName,
            myRole: myRole,
            outcome: outcome
        )
        // 전적과 보상은 **전투 창이 닫힐 때** 처리한다. 지금 주면 축하 말풍선이
        // 전투 화면 위에 겹쳐 뜬다. 창이 일찍 닫혀도(클릭으로 넘겨도) 승부는 이미
        // 났으므로 한 번은 적힌다 — onClosed 는 한 번만 불린다.
        let didWin = outcome.winner == myRole
        let win = BattleWindow(view: view) { [weak self] in
            self?.battleWindow = nil
            self?.finishBattle(won: didWin)
        }
        battleWindow = win
        win.present() // click-through overlay: show without activating/stealing focus
        view.start()
    }

    /// 전투가 끝났다. 전적을 적고, 이겼으면 경험치를 준다.
    private func finishBattle(won: Bool) {
        let record = BattleRecord.record(won: won)
        questLog("대전 \(won ? "승" : "패") → \(record.summary)")
        settingsController?.refresh()

        guard won else { return }
        // 보상은 **지금 화면에 있는 펫**에게. 토큰·퀘스트와 같은 규칙이다.
        petTokens[selectedPetSlug, default: 0] += BattleRecord.winReward
        scheduleTokenSave()
        currentPercent = XPModel.percent(tokens: petTokens[selectedPetSlug] ?? 0)
        applyStage()
        updateXPDetailWindow()

        let amount = Self.numberFormatter.string(from: NSNumber(value: Int(BattleRecord.winReward)))
            ?? "\(Int(BattleRecord.winReward))"
        petView?.enqueueCelebration("대전 승리! \(record.wins)승째\n+\(amount) EXP")
    }

    private func showInfo(title: String, text: String) {
        BattleDialog.info(title: title, message: text)
    }

    /// Builds the "대전" item. Its submenu lists everyone currently discovered on
    /// the same Wi-Fi; picking one sends them a challenge. Shows a disabled
    /// placeholder while nobody's around yet.
    /// 누가 노려봤을 때 뜨는 알림. 확인 버튼 하나뿐이다.
    private func presentStare(fromName: String, fromPet: String) {
        // 노려보기는 남이 거는 상호작용이라, 업무 중 가운데 모달로 바로 튀어나오면
        // 방해가 된다. 그래서 먼저 펫 옆에 작은 **말풍선**만 조용히 띄우고("모든
        // 상호작용은 말풍선으로, 모달은 바로 X" 원칙 — README/CLAUDE 참고), 말풍선을
        // **누르면** 그때 예전처럼 상대 펫 얼굴이 큼직하게 뜨는 모달을 연다.
        // 말풍선 안에도 상대 펫 도트(얼굴 크롭)를 함께 보여 준다.
        guard let petFrame = window?.frame else { return }
        // slug 로 각자 번들에서 찾는다(PetPortrait 참고). 우리 번들에 없는 펫이면 nil.
        let face = PetPortrait.face(of: fromPet)
        let species = Self.koreanPetName(fromPet)

        // 누르면 상대 펫 얼굴을 큼직하게 띄우는 기존 모달로 이어진다.
        stareBubble?.onClick = {
            BattleDialog.info(title: "노려보기",
                              message: "\(fromName)의 \(species)가\n노려봅니다.",
                              portrait: face)
        }
        stareBubble?.show(above: petFrame, dot: face,
                          text: "😠 \(fromName)의 \(species)가 노려봐요!",
                          duration: 8)
    }

    /// 매니페스트의 표시 이름("파이리 (Charmander)")에서 한글 이름만 뽑는다.
    /// 모르는 slug 면 slug 를 그대로 쓴다 — 상대가 우리에게 없는 펫을 쓸 수도 있다.
    private static func koreanPetName(_ slug: String) -> String {
        guard let sheet = try? loadSpriteSheet(slug: slug),
              let display = sheet.manifest.displayName else { return slug }
        return display.components(separatedBy: " (").first ?? display
    }

    /// GitHub PR·Linear 티켓을 훑어 새로 끝난 것에 경험치를 준다.
    private func startQuestService() {
        let service = QuestService()
        service.onQuests = { [weak self] quests in
            self?.award(quests)
        }
        service.start()
        questService = service
    }

    /// 퀘스트 보상을 **지금 화면에 있는 펫**에게 준다. 토큰과 같은 규칙이다 —
    /// 펫마다 경험치가 따로 쌓이므로 보상도 따로 들어가야 앞뒤가 맞는다.
    private func award(_ quests: [Quest]) {
        guard !quests.isEmpty else { return }
        let gained = Double(quests.count) * QuestService.rewardPerQuest
        petTokens[selectedPetSlug, default: 0] += gained
        scheduleTokenSave()
        currentPercent = XPModel.percent(tokens: petTokens[selectedPetSlug] ?? 0)
        applyStage()

        recentQuests = (quests.reversed() + recentQuests).prefix(20).map { $0 }
        for text in Self.celebrationTexts(for: quests) {
            petView?.enqueueCelebration(text)
        }
        questLog("지급 \(quests.count)건 → +\(Int(gained)) EXP")
    }

    /// 한 번에 여러 개가 잡히기도 한다(5분 사이에 두 건을 끝냈거나, 앱이 꺼져 있던
    /// 동안 쌓였을 때). **하나씩 차례로** 띄우도록 문구를 나눠 돌려준다 — 한꺼번에
    /// 부르면 말풍선이 같은 자리에 겹쳐 뒤엣것만 읽힌다.
    ///
    /// 다만 무한정 줄을 세우지는 않는다. 한 건에 \(PetView.celebrationDuration)초씩
    /// 걸리므로 스무 건이 잡히면 2분 넘게 말풍선만 뜬다. `maxIndividual` 건까지만
    /// 이름을 밝히고 나머지는 한 줄로 접는다.
    static func celebrationTexts(for quests: [Quest]) -> [String] {
        guard !quests.isEmpty else { return [] }
        let maxIndividual = 4
        let named = quests.suffix(maxIndividual)   // 최근 것부터 보여 준다
        var lines = named.map { quest -> String in
            "\(quest.source.badge) \(quest.name) 완료!\n+\(amount(1)) EXP"
        }
        let rest = quests.count - named.count
        if rest > 0 {
            lines.append("그 밖에 \(rest)건 더 완료!\n+\(amount(rest)) EXP")
        }
        return lines
    }

    private static func amount(_ count: Int) -> String {
        let reward = Int(QuestService.rewardPerQuest * Double(count))
        return numberFormatter.string(from: NSNumber(value: reward)) ?? "\(reward)"
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// 최근에 깬 퀘스트 목록. 무엇으로 경험치가 올랐는지 확인하는 자리다 —
    /// 토큰은 저절로 오르지만 퀘스트는 내가 한 일이라 되짚어 볼 수 있어야 한다.
    private func makeQuestMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "퀘스트", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let reward = Int(QuestService.rewardPerQuest)
        let amount = Self.numberFormatter.string(from: NSNumber(value: reward)) ?? "\(reward)"
        let header = NSMenuItem(title: "PR·티켓 1건당 +\(amount) EXP · 5분마다 확인",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        submenu.addItem(.separator())

        if recentQuests.isEmpty {
            let empty = NSMenuItem(title: "아직 깬 퀘스트가 없어요", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for quest in recentQuests.prefix(10) {
                let when = Self.questTimeFormatter.string(from: quest.completedAt)
                let line = NSMenuItem(title: "\(when)  [\(quest.source.badge)] \(quest.name)",
                                      action: nil, keyEquivalent: "")
                line.toolTip = quest.title
                line.isEnabled = false
                submenu.addItem(line)
            }
        }

        // Linear 는 키를 넣은 사람만 돈다. 왜 티켓이 안 잡히는지 여기서 알 수 있어야 한다.
        //
        // 키체인을 읽지 않고 저장 여부 플래그만 본다 — 메뉴를 여는 것만으로 키체인
        // 암호 창이 뜨면 곤란하다(LinearKeychain 참고).
        if !LinearKeychain.isStored {
            submenu.addItem(.separator())
            let hint = NSMenuItem(title: "Linear 연동 안 됨 — 설정에서 API 키 넣기",
                                  action: #selector(openSettingsFromMenu), keyEquivalent: "")
            hint.target = self
            hint.toolTip = "설정 창의 \"연동\" 에 Linear API 키를 넣으면 티켓 퀘스트도 잡힙니다."
            submenu.addItem(hint)
        }

        item.submenu = submenu
        return item
    }

    private static let questTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private func makeStareMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "노려보기", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if battlePeers.isEmpty {
            let empty = NSMenuItem(title: "주변에 상대가 없어요", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for peer in battlePeers {
                // 방해금지 중인 상대는 목록엔 그대로 두되(노출), 눌러도 소용없으니
                // 잠그고 이유를 밝힌다.
                if peer.dnd {
                    let sub = NSMenuItem(title: "\(peer.name) — 방해금지 중", action: nil, keyEquivalent: "")
                    sub.isEnabled = false
                    sub.toolTip = "\(peer.name)님이 방해금지 모드예요. 노려보기를 받지 않아요."
                    submenu.addItem(sub)
                    continue
                }
                let sub = NSMenuItem(title: "\(peer.name) 노려보기", action: #selector(starePeer(_:)), keyEquivalent: "")
                sub.target = self
                sub.representedObject = peer.id
                sub.isEnabled = true
                submenu.addItem(sub)
            }
        }
        item.submenu = submenu
        return item
    }

    @objc private func starePeer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        stare(peerID: id)
    }

    /// 메뉴바·설정창 공통 진입점.
    private func stare(peerID: String) {
        guard let peer = battlePeers.first(where: { $0.id == peerID }) else { return }
        // 방해금지 중인 상대에겐 걸지 않는다(UI 가 이미 잠갔지만 목록이 낡았을 수 있다).
        guard !peer.dnd else { return }
        battleService?.stare(at: peer)
    }

    private func makeBattleMenuItem() -> NSMenuItem {
        let battleItem = NSMenuItem(title: "대전", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if battlePeers.isEmpty {
            let empty = NSMenuItem(title: "주변에 상대가 없어요", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for peer in battlePeers {
                // 방해금지 중인 상대는 목록엔 그대로 두되(노출), 신청을 잠그고 이유를 밝힌다.
                if peer.dnd {
                    let item = NSMenuItem(title: "\(peer.name) — 방해금지 중", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    item.toolTip = "\(peer.name)님이 방해금지 모드예요. 대전 신청을 받지 않아요."
                    submenu.addItem(item)
                    continue
                }
                let item = NSMenuItem(title: "\(peer.name)에게 신청", action: #selector(challengePeer(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id
                submenu.addItem(item)
            }
        }
        battleItem.submenu = submenu
        return battleItem
    }

    /// 펫마다 속성기 이펙트 그림이 다르다(파이리 불길 / 꼬부기 물줄기). 매니페스트가
    /// 파일명을 들고 있으므로 그걸 읽어 창을 다시 만든다. 속성기가 없는 펫이면 창도
    /// 만들지 않는다.
    private func loadSkillEffect(for sheet: SpriteSheet) {
        flame?.hide()
        flame = nil
        guard let name = sheet.manifest.skill?.effect else { return }
        let base = (name as NSString).deletingPathExtension
        guard let url = Self.resourceBundle.url(forResource: base, withExtension: "png", subdirectory: "effects"),
              let image = NSImage(contentsOf: url), image.size.height > 0 else { return }
        flameAspect = image.size.width / image.size.height
        flame = FlameWindow(image: image)
    }

    // MARK: - Briefing

    /// What the pet says when clicked: the most recent sessions and what each
    /// one was started to do. Reads Claude Code's own transcripts, so it covers
    /// both the CLI and the desktop app without either being running.
    /// 지금 펫이 쓰는 속성기의 한 글자 이름("불"/"물"). 속성기가 없으면 nil.
    ///
    /// 체크포인트를 찍은 시점의 펫이 아니라 **지금 보이는 펫** 기준이다. 펫을 바꿔
    /// 가며 쓰는 상황에서 어느 쪽이 맞다고 하기 어려운데, 말풍선을 띄우는 그 펫이
    /// 자기 기술로 말하는 편이 덜 어색하다.
    private var currentSkillNoun: String? {
        guard let row = petView?.currentSpriteSheet.manifest.skill?.row,
              let name = PetAnimationName(rawValue: row) else { return nil }
        return name.skillNoun
    }

    /// 지금 말해야 할 브리프 묶음과 앞에 붙일 문장. 클릭과 예열이 **같은** 묶음을
    /// 보게 하려고 뽑아 뒀다 — 다르면 예열이 엉뚱한 걸 요약하고 캐시가 늘 빗나간다.
    private func currentBriefs() -> (briefs: [SessionBrief], prefix: String?, empty: String?, windowHours: Double) {
        // 불뿜기는 "여기까지 정리, 이제부터 할 일만 본다"는 표시다. 최근 3시간
        // 안에 뿜었다면 고정 3시간 창 대신 **그 시점 이후**만 보여 준다.
        if let firedAt = Self.savedFireBreathAt() {
            let sinceFire = Date().timeIntervalSince(firedAt)
            if sinceFire >= 0, sinceFire <= briefPrimaryHours * 3600 {
                // 체크포인트가 있으면 대화 재료도 그 뒤로 자른다. 하루치를 보면
                // "여기까지 정리한 뒤로" 라고 해 놓고 그 전 이야기를 하게 된다.
                let window = sinceFire / 3600
                let briefs = SessionBriefReader.recent(
                    withinHours: window,
                    limit: briefPrimaryLimit,
                    perBriefChars: briefCharsPerSession,
                    conversationHours: window
                )
                // 체크포인트를 찍어 둔 뒤 속성기가 없는 펫으로 바꿔 놓았을 수 있다.
                // 그 펫이 "불 뿜은 뒤로" 라고 말하면 이상하므로 중립 문구를 쓴다.
                let since = currentSkillNoun.map { "\($0) 뿜은 뒤로" } ?? "여기까지 정리한 뒤로"
                return (briefs, "\(since) 이것들만 남았어.",
                        "\(since) 새로 시작한 작업은 아직 없어. 깨끗해.", window)
            }
        }

        let primary = SessionBriefReader.recent(
            withinHours: briefPrimaryHours,
            limit: briefPrimaryLimit,
            perBriefChars: briefCharsPerSession,
            conversationHours: briefConversationHours
        )
        if !primary.isEmpty { return (primary, nil, nil, briefConversationHours) }

        let fallback = SessionBriefReader.recent(
            withinHours: briefFallbackHours,
            limit: briefFallbackLimit,
            perBriefChars: briefCharsPerSession,
            conversationHours: briefConversationHours
        )
        return (fallback,
                "최근 \(Int(briefPrimaryHours))시간은 조용했어. 그 전엔 이런 걸 했어.",
                "최근 \(Int(briefFallbackHours))시간 안에 작업한 게 없어. 푹 쉬었구나?",
                briefConversationHours)
    }

    /// What the pet says when clicked: the most recent sessions and what each
    /// one is doing. Reads Claude Code's own transcripts, so it covers both the
    /// CLI and the desktop app without either being running.
    private func briefingText() -> String? {
        let (briefs, prefix, empty, windowHours) = currentBriefs()
        guard !briefs.isEmpty else { return empty }
        return summarizedOrRaw(briefs, prefix: prefix, windowHours: windowHours)
    }

    /// 요약본이 있으면 그걸 쓰고, 없으면 원문 발췌로 대신하면서 다음 클릭을 위해
    /// 백그라운드 요약을 걸어 둔다. 요약은 10초쯤 걸려서 클릭을 붙잡아 둘 수 없다.
    private func summarizedOrRaw(_ briefs: [SessionBrief], prefix: String?, windowHours: Double) -> String {
        let mark = BriefingSummarizer.fingerprint(briefs)
        if let cache = BriefingSummarizer.cached(),
           cache.fingerprint == mark,
           Date().timeIntervalSince(cache.generatedAt) < BriefingSummarizer.cacheTTL {
            return [prefix, cache.text].compactMap { $0 }.joined(separator: "\n\n")
        }
        BriefingSummarizer.refresh(briefs: briefs, perBriefChars: briefCharsPerSession,
                                   windowHours: windowHours)
        return render(briefs, prefix: prefix)
    }

    /// 브리프들을 말풍선 한 덩어리로 만든다. 접두 문장도 글자 예산에 포함한다.
    private func render(_ briefs: [SessionBrief], prefix: String?) -> String {
        var lines: [String] = []
        if let prefix { lines.append(prefix) }
        var used = lines.reduce(0) { $0 + $1.count }
        for brief in briefs {
            let line = "· [\(brief.project)] \(brief.text)"
            // Budget is on the spoken text as a whole, so a long early brief
            // costs later ones their slot rather than overflowing the bubble.
            if used + line.count > briefCharBudget { break }
            used += line.count
            lines.append(line)
        }
        return lines.joined(separator: "\n\n")
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeStatusIcon()
        // We manage enablement ourselves (to gray out disabled rows); every other
        // item defaults to enabled. 델리게이트를 걸어 두면 메뉴가 열리기 직전마다
        // menuNeedsUpdate 로 항목을 다시 채운다 — 상태 변화는 그때 반영된다.
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        populateStatusMenu() // 첫 표시 전에도 비어 있지 않도록 한 번 채워 둔다
        item.menu = statusMenu
        statusItem = item
    }

    // 메뉴가 열리기 직전(추적 시작 전) AppKit 이 부른다. 이 시점에만 항목을 다시
    // 채우므로, 열려 있는 메뉴를 건드리는 일이 없어 갈아끼우기 크래시가 안 난다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        populateStatusMenu()
    }

    // MARK: - In-app update (Sparkle)

    /// Wires up Sparkle for packaged builds and kicks off a **silent** launch
    /// check (no pop-up). Availability shows only through the menu until the user
    /// clicks the update item. Dev/`swift run` builds have no SUFeedURL, so the
    /// updater stays nil and the menu shows a disabled "업데이트 확인" placeholder.
    private func setUpUpdater() {
        guard UpdaterManager.isConfigured else { return }
        let mgr = UpdaterManager()
        mgr.onAvailabilityChanged = { [weak self] available, version in
            guard let self else { return }
            self.updateAvailable = available
            self.updateVersion = version
            self.statusDidChange()
        }
        updater = mgr
        mgr.checkQuietlyOnLaunch()
    }

    /// Human-readable build version pulled from Info.plist, e.g. "v1.3.0 (214)".
    /// Shown as a disabled row so the user can see what they're running.
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    /// Builds the current-version row + the update row. When the silent launch
    /// check found a newer version, the update row calls it out and highlights;
    /// otherwise it's a plain "업데이트 확인…". Disabled (with a hint) when this
    /// build isn't configured for updates (e.g. a local `swift run`).
    private func appendVersionItems(to menu: NSMenu) {
        let versionItem = NSMenuItem(title: "ConnorPet \(appVersionString)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let updateItem: NSMenuItem
        if updater == nil {
            updateItem = NSMenuItem(title: "업데이트 확인 (이 빌드는 미지원)", action: nil, keyEquivalent: "")
            updateItem.isEnabled = false
        } else if updateAvailable, let v = updateVersion {
            updateItem = NSMenuItem(title: "⬆︎ 업데이트 설치 (v\(v))", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
        } else {
            updateItem = NSMenuItem(title: "업데이트 확인…", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
        }
        menu.addItem(updateItem)
    }

    @objc private func checkForUpdates() {
        updater?.userInitiatedCheck()
    }

    // MARK: - Menu-bar pet picker

    /// 상태바 메뉴 항목을 **기존 인스턴스(statusMenu)에 다시 채운다.** 새 NSMenu 를
    /// 만들어 갈아 끼우지 않는다 — 그게 열린 메뉴를 해제시켜 크래시 나던 원인이었다.
    /// 오직 setUpStatusItem 초기화와 menuNeedsUpdate(열리기 직전)에서만 부른다.
    private func populateStatusMenu() {
        let menu = statusMenu
        menu.removeAllItems()
        // 펫 선택은 메뉴바에서 제거하고 설정 창에서만 바꾸도록 함 — 노치/과밀로
        // 목록이 길어지는 것을 막고 설정 창으로 진입점을 일원화한다.
        for source in Self.availableStatusSources {
            let title = Self.statusSourceDisplayNames[source] ?? source
            let menuItem = NSMenuItem(title: title, action: #selector(selectStatusSource(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = source
            menuItem.state = (source == selectedStatusSource) ? .on : .off
            menu.addItem(menuItem)
        }

        // Installs the Claude Code hooks (into ~/.claude/settings.json) that add
        // the 헤롱헤롱(done)/실패(failed) states on top of the busy/blocked/idle a
        // DMG user already gets from the session files — the in-app path to
        // scripts/install_claude_hooks.py, which they can't run without the repo.
        // Checkmark reflects whether the hooks are currently installed.
        let hookItem = NSMenuItem(title: "Claude Code 상태 훅 (헤롱헤롱/실패)", action: #selector(toggleClaudeHooks), keyEquivalent: "")
        hookItem.target = self
        hookItem.state = ClaudeHookInstaller.isInstalled() ? .on : .off
        menu.addItem(hookItem)

        // The Claude Desktop source reads macOS's Notification Center DB to catch
        // the app's "작업 완료" banner and show 헤롱헤롱 — that needs Full Disk
        // Access. Checkmark = granted; clicking opens the settings pane. Without
        // it the desktop source still works (CPU-only done), so this is opt-in.
        // 번들이 아니면(swift run) 설정 창을 열어 줘 봐야 목록에 ConnorPet 이 없다 —
        // 권한이 띄운 앱에 귀속돼 그 앱의 버전 문자열이 대신 뜬다. 설정 창에서
        // 사정을 설명하므로 여기서는 그리로 보낸다.
        if FullDiskAccess.isAppBundle {
            let fdaItem = NSMenuItem(title: "전체 디스크 접근 권한 (헤롱헤롱 알림)",
                                     action: #selector(openFullDiskAccess), keyEquivalent: "")
            fdaItem.target = self
            fdaItem.state = FullDiskAccess.isGranted() ? .on : .off
            menu.addItem(fdaItem)
        } else {
            let item = NSMenuItem(title: "전체 디스크 접근 권한 — 앱으로 만들어야 해요",
                                  action: #selector(openSettingsFromMenu), keyEquivalent: "")
            item.target = self
            item.toolTip = "swift run 은 앱 번들이 아니라 권한 목록에 ConnorPet 이 뜨지 않습니다."
                + " 설정 창에서 만드는 명령을 복사할 수 있어요."
            menu.addItem(item)
        }

        menu.addItem(.separator())
        // When on, the XP bar is always visible; when off, it only appears while
        // hovering the pet. Default on (see savedBarAlwaysVisible).
        let barToggle = NSMenuItem(title: "경험치 바 항상 표시", action: #selector(toggleBarAlwaysVisible), keyEquivalent: "")
        barToggle.target = self
        barToggle.state = barAlwaysVisible ? .on : .off
        menu.addItem(barToggle)

        // Master on/off for evolution. When off the pet stays its base form.
        let evoToggle = NSMenuItem(title: "진화 사용", action: #selector(toggleEvolutionEnabled), keyEquivalent: "")
        evoToggle.target = self
        evoToggle.state = evolutionEnabled ? .on : .off
        menu.addItem(evoToggle)

        // 방해금지 모드: 켜면 같은 Wi-Fi 상대가 거는 대전·노려보기를 받지 않는다.
        let dndToggle = NSMenuItem(title: "방해금지 모드", action: #selector(toggleDND), keyEquivalent: "")
        dndToggle.target = self
        dndToggle.state = dndEnabled ? .on : .off
        dndToggle.toolTip = "켜면 다른 사람이 대전·노려보기를 걸 수 없어요. 상대 목록엔 '방해금지 중'으로 보입니다."
        menu.addItem(dndToggle)

        // 되돌릴 수 없으므로 확인을 받는다.
        let resetItem = NSMenuItem(title: "모든 경험치 초기화", action: #selector(resetAllXP), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())
        menu.addItem(makeQuestMenuItem())
        menu.addItem(makeBattleMenuItem())
        menu.addItem(makeStareMenuItem())

        menu.addItem(.separator())
        appendVersionItems(to: menu)

        menu.addItem(.separator())
        // 펫 우클릭과 동일한 설정 창 진입점 — 메뉴바에서도 열 수 있게 한다.
        let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        // statusMenu 는 이미 statusItem.menu 로 걸려 있으므로 다시 대입하지 않는다.
    }

    /// 상태가 바뀌었을 때 부른다. 메뉴는 다음에 열릴 때 menuNeedsUpdate 로 알아서
    /// 다시 채워지므로 여기서 건드리지 않는다(그게 크래시 원인이었다). 대신, 같은
    /// 값을 보여 주는 설정 창이 떠 있으면 함께 갱신한다(대전 상대 목록, 훅/권한
    /// 상태, 진화/경험치 토글 등이 메뉴바나 밖에서 바뀔 수 있다). refresh 는 창이
    /// 보일 때만 실제로 돈다.
    private func statusDidChange() {
        settingsController?.refresh()
    }

    /// 메뉴바 › "설정…" 진입점. 펫 우클릭과 같은 창을 연다.
    @objc private func openSettingsFromMenu() {
        openSettingsWindow()
    }

    /// 펫 우클릭 › "설정…" 진입점. 창을 (없으면 만들어) 띄운다.
    private func openSettingsWindow() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.delegate = self
            settingsController = controller
        }
        settingsController?.show()
    }

    /// Installs or removes the Claude Code status hooks. Because this writes to
    /// the global ~/.claude/settings.json, we confirm first (the click is the
    /// consent the README talks about) and back the file up before touching it.
    @objc private func toggleClaudeHooks() {
        if ClaudeHookInstaller.isInstalled() {
            guard BattleDialog.confirm(
                title: "Claude Code 상태 훅 제거",
                message: "~/.claude/settings.json에서 connor-pet이 추가한\n훅을 제거합니다. 헤롱헤롱/실패 표시가 꺼지고\n달리기/얼음/잠듦(세션파일 기준)만 남습니다.\n\n다른 훅 설정은 건드리지 않습니다.",
                confirmTitle: "제거"
            ) else { return }
            do {
                try ClaudeHookInstaller.uninstall()
                showInfo(title: "훅 제거 완료", text: "Claude Code 상태 훅을 제거했어요.\n실행 중인 Claude Code 세션은 다음 턴부터 반영돼요.")
            } catch {
                showInfo(title: "훅 제거 실패", text: error.localizedDescription)
            }
        } else {
            guard BattleDialog.confirm(
                title: "Claude Code 상태 훅 설치",
                message: "~/.claude/settings.json에 2개의 훅(Stop·SessionEnd)을\n추가해 헤롱헤롱(작업 완료)·실패 상태를 표시합니다.\n(달리기/얼음/잠듦은 훅 없이 세션파일로 이미 표시돼요.)\n\n기존 설정은 타임스탬프를 붙여 백업하고,\n다른 훅은 건드리지 않습니다. (python3 필요)",
                confirmTitle: "설치"
            ) else { return }
            do {
                try ClaudeHookInstaller.install()
                showInfo(title: "훅 설치 완료", text: "Claude Code 상태 훅을 설치했어요.\n소스가 'Claude Code'일 때 헤롱헤롱/실패까지 보여요.\n실행 중인 세션은 다음 턴부터 반영돼요.")
            } catch {
                showInfo(title: "훅 설치 실패", text: error.localizedDescription)
            }
        }
        statusDidChange()
    }

    /// Opens the Full Disk Access settings pane so the Claude Desktop source can
    /// read the Notification Center DB (its 헤롱헤롱-on-완료-알림 signal). We can't
    /// grant it from code — macOS requires the user to flip it and relaunch — so
    /// we just guide them there. Already-granted just confirms.
    @objc private func openFullDiskAccess() {
        if FullDiskAccess.isGranted() {
            showInfo(
                title: "전체 디스크 접근 권한 있음",
                text: "이미 권한이 있어요.\nClaude Desktop 소스에서 '작업 완료' 알림으로도\n헤롱헤롱을 감지합니다."
            )
            return
        }
        guard BattleDialog.confirm(
            title: "전체 디스크 접근 권한 필요",
            message: "Claude Desktop 소스가 '작업 완료' 알림으로 헤롱헤롱을\n감지하려면 전체 디스크 접근 권한이 필요합니다.\n(없어도 CPU 기준으로는 감지하지만 덜 정확해요.)\n\n시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크\n접근에서 ConnorPet을 켠 뒤 앱을 다시 실행하세요.",
            confirmTitle: "시스템 설정 열기"
        ) else { return }
        FullDiskAccess.openSettings()
    }

    @objc private func toggleBarAlwaysVisible() { setBarAlwaysVisible(!barAlwaysVisible) }

    /// 메뉴바·설정창 공통 진입점.
    private func setBarAlwaysVisible(_ on: Bool) {
        guard on != barAlwaysVisible else { return }
        barAlwaysVisible = on
        petView?.setBarAlwaysVisible(barAlwaysVisible)
        Self.saveBarAlwaysVisible(barAlwaysVisible)
        statusDidChange()
    }

    @objc private func toggleDND() { setDND(!dndEnabled) }

    /// 메뉴바·우클릭·설정창 공통 진입점. 방해금지 모드를 켜고 끈다. 대전 서비스에
    /// 알려 광고(TXT)를 갱신하고, 우클릭 메뉴 체크 표시를 위해 펫 뷰에도 반영한다.
    private func setDND(_ on: Bool) {
        guard on != dndEnabled else { return }
        dndEnabled = on
        petView?.dndEnabled = on
        battleService?.updateDND(on)
        Self.saveDNDEnabled(on)
        statusDidChange()
    }

    // MARK: - Menu-bar evolution controls

    /// 모든 펫의 누적 경험치를 지운다. 진화 단계는 경험치에서 계산되므로 같이
    /// 초기화되고, 진화형을 보고 있었다면 기본형으로 되돌아간다.
    @objc private func resetAllXP() {
        let pets = petTokens.filter { $0.value > 0 }.count
        guard BattleDialog.confirm(
            title: "모든 경험치 초기화",
            message: pets > 0
                ? "펫 \(pets)마리의 누적 경험치가\n모두 사라지고 진화도 풀립니다.\n되돌릴 수 없습니다."
                : "초기화할 경험치가 없습니다.\n그래도 진행할까요?",
            confirmTitle: "모든 경험치 초기화"
        ) else { return }

        performResetAllXP()
    }

    /// 확인 절차와 분리해 둔 초기화 본체.
    private func performResetAllXP() {
        petTokens = [:]
        tokenSaveTimer?.invalidate(); tokenSaveTimer = nil
        savePetTokens()
        // 퀘스트 지급 기록도 함께 지운다. 남겨 두면 이미 깬 것이 다시 잡히지 않아,
        // 초기화 직후 PR·티켓을 올려도 새 기준선이 잡힐 때까지 조용해진다.
        QuestService.resetHistory()
        BattleRecord.reset()
        recentQuests = []
        currentPercent = 0
        applyStage()   // 단계가 0으로 떨어지고 refreshDisplayedPet 이 기본형으로 되돌린다
        statusDidChange()
    }

    @objc private func toggleEvolutionEnabled() { setEvolutionEnabled(!evolutionEnabled) }

    /// 메뉴바·설정창 공통 진입점.
    private func setEvolutionEnabled(_ on: Bool) {
        guard on != evolutionEnabled else { return }
        evolutionEnabled = on
        Self.saveEvolutionEnabled(evolutionEnabled)
        applyStage() // evolve to the earned stage, or revert to base, immediately
        statusDidChange()
    }

    /// 메뉴바·설정창 공통 진입점. 펫을 바꾸고 상태를 다시 잡는다.
    private func changePet(to slug: String) {
        guard slug != selectedPetSlug else { return }
        // 펫을 바꾸기 전에 지금까지 쌓인 값을 확정해 둔다. 주기 저장만 믿으면
        // 전환 직전 몇 초치가 날아간다.
        tokenSaveTimer?.invalidate(); tokenSaveTimer = nil
        savePetTokens()

        selectedPetSlug = slug
        // 펫마다 경험치가 다르므로 막대와 진화 단계를 그 펫 기준으로 다시 잡는다.
        currentPercent = XPModel.percent(tokens: petTokens[slug] ?? 0)
        applyStage()

        Self.savePetSlug(slug)
        // Re-derive the shown form from the new base + current XP stage (so
        // picking a pet while already "leveled up" shows its evolved form).
        refreshDisplayedPet()
        statusDidChange()
    }

    // MARK: - Menu-bar status-source picker

    @objc private func selectStatusSource(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? String else { return }
        changeStatusSource(to: source)
    }

    /// 메뉴바·설정창 공통 진입점.
    private func changeStatusSource(to source: String) {
        guard source != selectedStatusSource else { return }
        selectedStatusSource = source
        Self.saveStatusSource(source)
        startWatcher(for: source)
        statusDidChange()
    }

    private func startWatcher(for source: String) {
        watcher?.stop()
        let newWatcher: AgentStatusWatching
        switch source {
        case "orca": newWatcher = OrcaStatusWatcher()
        case "claude-desktop": newWatcher = ClaudeDesktopStatusWatcher()
        default: newWatcher = ClaudeCodeStatusWatcher()
        }
        newWatcher.onUpdate = { [weak self] result in
            self?.applyUpdate(result)
        }
        newWatcher.start()
        watcher = newWatcher
    }

    // MARK: - First-run wizard

    /// 설치 후 최초 1회만 뜨는 2단계 마법사: ①펫 고르기(이미지) → ②사용하는 앱
    /// 고르기(Claude Code / Claude Desktop / Orca). 고른 값을 즉시 반영·저장하고
    /// 완료 플래그를 남겨 재실행 때는 뜨지 않는다. 창을 만들기 *전에* 불려서
    /// 마법사에서 고른 펫으로 창을 띄운다.
    private func maybeRunFirstRunWizard() {
        guard !Self.didCompleteFirstRun() else { return }
        // 헤드리스 셀프테스트/설정 PNG 덤프/강제 펫 지정 실행에서는 모달로 막지 않는다.
        let env = ProcessInfo.processInfo.environment
        if env["CONNORPET_SELFTEST"] != nil || env["CONNORPET_DEBUG_SETTINGS"] != nil || env["CONNORPET_PET"] != nil {
            return
        }

        // 펫 선택지(썸네일 = idle 첫 프레임)를 메뉴와 같은 순서로 만든다.
        let pets: [FirstRunWizard.PetOption] = Self.availablePetSlugs.compactMap { slug in
            guard let name = petDisplayNames[slug] else { return nil }
            let image = (try? Self.loadSpriteSheet(slug: slug))?
                .resolvedAnimation(for: .idle)?.images.first
            return FirstRunWizard.PetOption(slug: slug, name: name, image: image)
        }
        let sources = Self.availableStatusSources.map {
            FirstRunWizard.SourceOption(id: $0, name: Self.statusSourceDisplayNames[$0] ?? $0,
                                        icon: Self.sourceIcon($0))
        }

        let result = FirstRunWizard.run(pets: pets, sources: sources)
        if let slug = result.petSlug, petDisplayNames[slug] != nil {
            selectedPetSlug = slug
            Self.savePetSlug(slug)
        }
        if let source = result.sourceID, Self.availableStatusSources.contains(source) {
            selectedStatusSource = source
            Self.saveStatusSource(source)
        }
        Self.markFirstRunComplete()
    }

    /// Bundled step-2 app icon for a status source (`Resources/source-icons/<id>.png`).
    /// See Package.swift for the artwork sources/licenses.
    private static func sourceIcon(_ id: String) -> NSImage? {
        guard let url = resourceBundle.url(forResource: id, withExtension: "png", subdirectory: "source-icons") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    // MARK: - 펫별 경험치 저장

    private static let petTokensDefaultsKey = "petTokens"

    private func scheduleTokenSave() {
        guard tokenSaveTimer == nil else { return }
        tokenSaveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.tokenSaveTimer = nil
            self?.savePetTokens()
        }
    }

    private func savePetTokens() {
        UserDefaults.standard.set(petTokens, forKey: Self.petTokensDefaultsKey)
    }

    private static func savedPetTokens() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: petTokensDefaultsKey) as? [String: Double]) ?? [:]
    }

    func applicationWillTerminate(_ notification: Notification) {
        tokenSaveTimer?.invalidate()
        savePetTokens()
    }

    // MARK: - Live update: animation + XP bar + evolution

    private func applyUpdate(_ result: AgentStateAnimationResult) {
        petView?.setBaseAnimation(result.animation)
        // 새로 쌓인 토큰은 **지금 화면에 있는 펫**에게만 들어간다. 그래서 펫마다
        // 경험치가 따로 쌓이고, 진화도 따로 진행된다.
        if result.gainedTokens > 0 {
            petTokens[selectedPetSlug, default: 0] += result.gainedTokens
            scheduleTokenSave()
            if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
                let t = Int(petTokens[selectedPetSlug] ?? 0)
                FileHandle.standardError.write("[connor-pet] XP \(selectedPetSlug) 누적=\(t)\n".data(using: .utf8)!)
            }
        }
        currentPercent = XPModel.percent(tokens: petTokens[selectedPetSlug] ?? 0)
        applyStage()
        maybeThank(gained: result.gainedTokens)
        maybeSuggestLinear()
    }

    /// Linear 를 안 붙였으면 가끔 권한다. 붙이면 저절로 멈춘다.
    ///
    /// 키체인을 읽지 않고 저장 여부 플래그만 본다 — 값을 읽으면 그 순간 암호 창이
    /// 뜬다(`LinearKeychain` 참고). 말은 축하와 같은 줄에 세워, 다른 말풍선과
    /// 겹치지 않고 차례를 기다린다.
    private func maybeSuggestLinear() {
        let now = Date()
        guard !LinearKeychain.isStored else {
            // 붙인 뒤에 지웠다면 곧바로 잔소리하지 않게 시계를 다시 맞춰 둔다.
            linearNudge.postpone(to: now)
            return
        }
        guard linearNudge.due(now: now) else { return }
        petView?.enqueueCelebration(Self.linearNudgeLine(), style: .normal)
    }

    /// 권유 문구. 경험치 알림이 아니므로 초록 강조를 쓰지 않는다.
    private static func linearNudgeLine() -> String {
        let lines = [
            "Linear를 연결해봐! 티켓 끝내면 경험치 줄게",
            "Linear 연결하면 티켓도 밥이 돼. 설정에서!",
            "티켓 Done도 경험치야. Linear 연결해봐",
            "설정에서 Linear 붙이면 더 많이 먹을 수 있어",
        ]
        return lines.randomElement() ?? lines[0]
    }

    /// 경험치를 받은 것에 대해 고맙다고 말한다. 말할 때가 됐는지는 `ThanksThrottle` 이 정한다.
    private func maybeThank(gained newTokens: Double) {
        guard let total = thanks.add(newTokens, now: Date()) else { return }
        let gained = Int(total.rounded())
        let amount = Self.numberFormatter.string(from: NSNumber(value: gained)) ?? "\(gained)"
        petView?.enqueueCelebration("\(Self.thanksLine())\n+\(amount) EXP")
        questLog("감사 인사 +\(gained) EXP")
    }

    /// 인사말. 매번 같은 말을 하면 금세 배경이 되어 읽지 않게 되므로 돌려 쓴다.
    /// 무엇을 받았는지(경험치)를 밥으로 바꿔 말하는 쪽이 펫답다.
    private static func thanksLine() -> String {
        let lines = [
            "와~! 고마워! 잘 먹었어",
            "냠냠… 맛있다! 고마워",
            "우와, 배부르다! 고마워",
            "고마워! 힘이 솟아나",
            "밥 잘 먹었어! 더 클게",
            "헤헤, 또 줘! 고마워",
        ]
        return lines.randomElement() ?? lines[0]
    }

    /// 호버 중이면 펫 아래에 상세 문구를 띄우고, 아니면 감춘다. 값이 갱신될 때마다
    /// 다시 부르므로 떠 있는 동안에도 숫자가 실시간으로 바뀐다.
    private func updateXPDetailWindow() {
        guard xpHovering, let petFrame = window?.frame, let view = petView else {
            xpDetailWindow?.hide()
            return
        }
        xpDetailWindow?.show(text: view.progressDetail, below: petFrame)
    }

    /// 호버할 때 펫 아래에 뜨는 문구. "EXP 100,000 / 200,000,000 - 0.05%" 꼴이다.
    /// 분모는 **다음 진화 지점**이라, 진화할 때마다 기준이 올라간다.
    private static func xpDetail(tokens: Double) -> String {
        let p = XPModel.progress(tokens: tokens)
        let n = NumberFormatter()
        n.numberStyle = .decimal
        let now = n.string(from: NSNumber(value: Int(tokens))) ?? "0"
        guard let target = p.target else { return "EXP \(now) - MAX" }
        let goal = n.string(from: NSNumber(value: Int(target))) ?? "0"
        let pct = p.percent * 100
        // 초반에는 소수점 둘째 자리까지 보여야 움직이는 게 보인다.
        let shown = pct >= 10 ? String(format: "%.1f", pct) : String(format: "%.2f", pct)
        return "EXP \(now) / \(goal) - \(shown)%"
    }

    /// Applies the current XP to the bar and evolution. When evolution is
    /// disabled the pet is pinned to its base form (stage 0) no matter how much
    /// XP it has. Called both on each poll and immediately after a menu change
    /// (thresholds / enable toggle) so edits take effect without waiting.
    private func applyStage() {
        let tokens = petTokens[selectedPetSlug] ?? 0
        let stage = evolutionEnabled ? XPModel.stage(tokens: tokens) : 0
        petView?.setProgress(percent: currentPercent, stage: stage,
                             detail: Self.xpDetail(tokens: tokens))
        updateXPDetailWindow()
        if stage != currentStage {
            currentStage = stage
            refreshDisplayedPet()
        }
    }

    /// Picks the sprite to show from the user's base pet + current evolution
    /// stage, swapping it in only when it actually changes (so the animation
    /// isn't restarted every poll).
    private func refreshDisplayedPet() {
        let slug = displaySlug(base: selectedPetSlug, stage: currentStage)
        guard slug != currentDisplaySlug, let sheet = cachedSheet(slug: slug) else { return }
        currentDisplaySlug = slug
        // 상대에게 알리는 펫도 **지금 보이는 쪽**으로 맞춘다. 메뉴에서 고른 기본형을
        // 그대로 광고하면, 리자몽으로 진화해 놓고도 상대 화면에는 "파이리가
        // 노려봅니다" 와 파이리 얼굴이 뜬다. 메뉴 선택도 진화도 이 함수를 지나므로
        // 여기 한 곳에서 갱신하면 둘 다 덮인다.
        battleService?.updatePet(slug)

        // 프레임 크기가 다른 펫으로 바뀌면 창도 같이 커지거나 작아져야 한다. 중심을
        // 유지해서 바꾸면 펫이 제자리에 있는 것처럼 보인다. 여기가 시트를 갈아 끼우는
        // 유일한 지점이라(메뉴 선택도, 진화도 이리로 온다) 리사이즈도 여기서 한다.
        if let win = window {
            let newSize = windowSize(for: sheet)
            if abs(newSize - win.frame.width) > 0.5 {
                let newHeight = newSize + PetView.barAreaHeight
                let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
                let origin = CGPoint(x: center.x - newSize / 2, y: center.y - newHeight / 2)
                win.setFrame(NSRect(origin: origin, size: CGSize(width: newSize, height: newHeight)), display: true)
                petView?.frame = NSRect(x: 0, y: 0, width: newSize, height: newHeight)
                Self.saveOrigin(origin)
            }
        }

        petView?.setSpriteSheet(sheet)
        loadSkillEffect(for: sheet)
        if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
            let t = Int(petTokens[selectedPetSlug] ?? 0)
            let ww = Int(self.window?.frame.width ?? 0)
            FileHandle.standardError.write("[connor-pet] 표시 \(slug)  (기준 \(selectedPetSlug), 단계 \(currentStage), XP \(t), 창 \(ww)pt)\n".data(using: .utf8)!)
        }
    }

    private func displaySlug(base: String, stage: Int) -> String {
        guard stage > 0, let chain = Self.evolutionChains[base], !chain.isEmpty else { return base }
        let index = min(stage, chain.count) - 1
        return chain[index]
    }

    private func cachedSheet(slug: String) -> SpriteSheet? {
        if let cached = sheetCache[slug] { return cached }
        guard let sheet = try? Self.loadSpriteSheet(slug: slug) else { return nil }
        sheetCache[slug] = sheet
        return sheet
    }

    static func loadSpriteSheet(slug: String) throws -> SpriteSheet {
        guard
            let spritesheetURL = resourceBundle.url(forResource: "spritesheet", withExtension: "png", subdirectory: "pets/\(slug)"),
            let manifestURL = resourceBundle.url(forResource: "pet", withExtension: "json", subdirectory: "pets/\(slug)")
        else {
            throw NSError(domain: "ConnorPet", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing bundled resources for pet '\(slug)'"])
        }
        return try SpriteSheet(manifestURL: manifestURL, spritesheetURL: spritesheetURL)
    }

    // The SwiftPM resource bundle always sits next to the app's resources:
    //   - code-signed .app  → Contents/Resources/ConnorPet_ConnorPet.bundle
    //   - plain `swift run` → .build/<config>/ConnorPet_ConnorPet.bundle
    // and `Bundle.main.resourceURL` points at that directory in both cases, so this
    // single lookup covers dev and release alike.
    //
    // We deliberately do NOT fall back to SwiftPM's generated `Bundle.module`. Its
    // only candidates are the .app root (Bundle.main.bundleURL) and a build-time
    // hardcoded path (`/Users/runner/...` on CI) — the former can't be used because
    // a loose bundle at the .app root makes codesign refuse to seal it ("unsealed
    // contents present in the bundle root" → macOS reports "damaged" once
    // quarantined), and the latter never exists on a user's machine. Both only ever
    // masked bugs, so a missing bundle should fail loudly here instead.
    static let resourceBundle: Bundle = {
        guard
            let resourceURL = Bundle.main.resourceURL,
            let bundle = Bundle(url: resourceURL.appendingPathComponent("ConnorPet_ConnorPet.bundle"))
        else {
            fatalError("리소스 번들을 찾을 수 없음: \(Bundle.main.resourceURL?.path ?? "nil")/ConnorPet_ConnorPet.bundle")
        }
        return bundle
    }()

    // Menu-bar glyph for the Totodile pet: a Poké Ball outline, drawn to match
    // the monochrome/template style of the other system status-bar icons
    // (color is ignored for template images — only the alpha shape matters).
    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 1.4
            let ballRect = rect.insetBy(dx: 2, dy: 2)

            let outline = NSBezierPath(ovalIn: ballRect)
            outline.lineWidth = lineWidth
            NSColor.black.setStroke()
            outline.stroke()

            let midY = rect.midY
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: ballRect.minX, y: midY))
            divider.line(to: NSPoint(x: ballRect.maxX, y: midY))
            divider.lineWidth = lineWidth
            divider.stroke()

            let hubRadius: CGFloat = 2.6
            let hubRect = NSRect(
                x: rect.midX - hubRadius, y: midY - hubRadius,
                width: hubRadius * 2, height: hubRadius * 2
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: hubRect).fill()

            let holeRadius: CGFloat = 1.1
            let holeRect = NSRect(
                x: rect.midX - holeRadius, y: midY - holeRadius,
                width: holeRadius * 2, height: holeRadius * 2
            )
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: holeRect).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Selected pet persistence

    private static let selectedPetDefaultsKey = "selectedPetSlug"

    private static func savePetSlug(_ slug: String) {
        UserDefaults.standard.set(slug, forKey: selectedPetDefaultsKey)
    }

    // Falls back to `fallback` if nothing was saved yet, or if the saved slug
    // no longer has bundled resources (e.g. removed from a future build).
    private static func savedPetSlug(fallback: String, validSlugs: Set<String>) -> String {
        guard let saved = UserDefaults.standard.string(forKey: selectedPetDefaultsKey), validSlugs.contains(saved) else {
            return fallback
        }
        return saved
    }

    // MARK: - Selected status-source persistence

    private static let selectedStatusSourceDefaultsKey = "selectedStatusSource"

    private static func saveStatusSource(_ source: String) {
        UserDefaults.standard.set(source, forKey: selectedStatusSourceDefaultsKey)
    }

    // Falls back to `fallback` ("claude-code") if nothing was saved yet, or if
    // the saved value isn't one of the sources this build knows about.
    private static func savedStatusSource(fallback: String) -> String {
        guard let saved = UserDefaults.standard.string(forKey: selectedStatusSourceDefaultsKey),
              availableStatusSources.contains(saved) else {
            return fallback
        }
        return saved
    }

    // MARK: - First-run flag persistence

    // Whether the first-run wizard (pet + source picker) has already been shown.
    // Set once and never cleared, so it appears on first install only, not on
    // relaunch. (swift-run and the .app use different UserDefaults domains, so
    // each sees its own first run — see README.)
    private static let didCompleteFirstRunDefaultsKey = "didCompleteFirstRun"

    private static func didCompleteFirstRun() -> Bool {
        UserDefaults.standard.bool(forKey: didCompleteFirstRunDefaultsKey)
    }

    private static func markFirstRunComplete() {
        UserDefaults.standard.set(true, forKey: didCompleteFirstRunDefaultsKey)
    }

    // MARK: - XP bar visibility persistence

    private static let barAlwaysVisibleDefaultsKey = "xpBarAlwaysVisible"

    private static func saveBarAlwaysVisible(_ always: Bool) {
        UserDefaults.standard.set(always, forKey: barAlwaysVisibleDefaultsKey)
    }

    // Defaults to `fallback` (false — bar hidden until hover) when nothing saved yet.
    private static func savedBarAlwaysVisible(fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: barAlwaysVisibleDefaultsKey) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: barAlwaysVisibleDefaultsKey)
    }

    // MARK: - 방해금지 모드 persistence

    private static let dndEnabledDefaultsKey = "doNotDisturbEnabled"

    private static func saveDNDEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: dndEnabledDefaultsKey)
    }

    // Defaults to `fallback` (false — 방해금지 꺼짐) when nothing saved yet.
    private static func savedDNDEnabled(fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: dndEnabledDefaultsKey) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: dndEnabledDefaultsKey)
    }

    // MARK: - Evolution settings persistence

    private static let evolutionEnabledDefaultsKey = "evolutionEnabled"

    private static func saveEvolutionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: evolutionEnabledDefaultsKey)
    }

    // Defaults to `fallback` (false — evolution off) when nothing saved yet.
    private static func savedEvolutionEnabled(fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: evolutionEnabledDefaultsKey) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: evolutionEnabledDefaultsKey)
    }

    // MARK: - 속성기 스냅샷

    // 마지막으로 속성기를 쓴 시각. 앱을 껐다 켜도 유지돼야 체크포인트로 쓸모가 있다.
    // 키 이름이 fire 인 것은 불뿜기만 있던 때의 잔재다. 바꾸면 이미 저장된 값이
    // 버려지므로 그대로 둔다 — 체크포인트는 기술 종류와 무관하게 하나다.
    private static let fireBreathDefaultsKey = "lastFireBreathAt"

    private static func saveFireBreathAt(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: fireBreathDefaultsKey)
    }

    private static func savedFireBreathAt() -> Date? {
        let t = UserDefaults.standard.double(forKey: fireBreathDefaultsKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    // MARK: - Window position persistence

    private static let originDefaultsKey = "petWindowOrigin"

    private static func saveOrigin(_ origin: CGPoint) {
        UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: originDefaultsKey)
    }

    // Falls back to `fallback` if nothing was saved yet, or if the saved spot
    // no longer lands on any connected screen (e.g. monitor unplugged since).
    private static func savedOrigin(fallback: CGPoint) -> CGPoint {
        guard
            let dict = UserDefaults.standard.dictionary(forKey: originDefaultsKey),
            let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat
        else { return fallback }

        let saved = CGPoint(x: x, y: y)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(saved) }
        return onScreen ? saved : fallback
    }
}

// MARK: - 설정 창 다리

/// 설정 창이 읽고 부르는 표면. 전부 메뉴바 아이템이 쓰던 것과 **같은** 코드
/// 경로(changePet / changeStatusSource / setEvolutionEnabled / toggleClaudeHooks
/// 등)로 위임해, 어느 쪽에서 바꾸든 동작·저장·메뉴바 갱신이 동일하다.
extension AppDelegate: SettingsActionsDelegate {
    var settingsBattleRecord: String { BattleRecord.load().summary }

    /// 예전 기록을 가져올 수 있는지. 판정은 `XPMigration.status` 가 한다.
    var settingsLegacyStatus: XPMigration.LegacyStatus {
        XPMigration.status(current: petTokens, legacy: XPMigration.legacyTokens())
    }

    /// 예전 기록을 지금 펫들에 합친다.
    ///
    /// **펫마다 큰 쪽을 남긴다.** 덮어쓰기가 아니라 합치기라 지금 쌓인 게 더 많으면
    /// 줄어들지 않는다 — 실수로 눌러도 손해가 없다.
    ///
    /// 경험치를 UserDefaults 에만 쓰면 안 된다. 앱이 메모리에 들고 있는 값을 다음
    /// 저장 때 그대로 덮어쓰기 때문이다(그렇게 한 번 날렸다). 그래서 메모리 상태를
    /// 먼저 고치고 저장까지 여기서 한다.
    func settingsImportLegacyXP() -> String {
        let legacy = XPMigration.legacyTokens()
        guard !legacy.isEmpty else { return "가져올 예전 기록이 없어요." }

        var gained: Double = 0
        for (pet, value) in legacy {
            let current = petTokens[pet] ?? 0
            if value > current {
                gained += value - current
                petTokens[pet] = value
            }
        }
        let addedQuests = XPMigration.mergeQuestIDs()
        XPMigration.markDone()

        savePetTokens()
        currentPercent = XPModel.percent(tokens: petTokens[selectedPetSlug] ?? 0)
        applyStage()
        updateXPDetailWindow()

        guard gained > 0 || addedQuests > 0 else {
            return "이미 다 가져와 있어요. 바뀐 건 없습니다."
        }
        let amount = Self.numberFormatter.string(from: NSNumber(value: Int(gained))) ?? "\(Int(gained))"
        var message = "경험치 \(amount) 을 가져왔어요."
        if addedQuests > 0 { message += "\n퀘스트 지급 기록 \(addedQuests)건도 합쳤어요." }
        return message
    }

    var settingsLinearKeyStored: Bool { LinearKeychain.isStored }
    var settingsLinearStatus: String? { linearStatus }

    /// 키를 저장하고 곧바로 통하는지 확인한다.
    ///
    /// 저장만 하고 끝내면 오타가 난 키도 "저장됨" 으로 보이고, 5분 뒤 아무것도
    /// 안 잡히는데 이유를 알 수 없다. 확인이 실패하면 저장한 키를 다시 지운다 —
    /// 안 통하는 키를 남겨 두면 다음 폴링마다 헛되이 거절당한다.
    func settingsSaveLinearKey(_ key: String) {
        linearStatus = "확인 중…"
        settingsController?.refresh()
        QuestService.verifyLinearKey(key) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let who):
                LinearKeychain.save(key)
                self.linearStatus = "연결됨 — \(who)"
                questLog("Linear 키 확인 성공: \(who)")
            case .failure(let error):
                LinearKeychain.delete()
                self.linearStatus = "확인 실패 — \(error.localizedDescription)"
                questLog("Linear 키 확인 실패: \(error.localizedDescription)")
            }
            self.settingsController?.refresh()
        }
    }

    func settingsDeleteLinearKey() {
        LinearKeychain.delete()
        linearStatus = nil
        settingsController?.refresh()
    }

    var settingsOrderedPets: [(slug: String, name: String)] {
        Self.availablePetSlugs.compactMap { slug in
            petDisplayNames[slug].map { (slug, $0) }
        }
    }
    var settingsSelectedPetSlug: String { selectedPetSlug }
    func settingsSelectPet(slug: String) { changePet(to: slug) }

    var settingsOrderedStatusSources: [(id: String, name: String)] {
        Self.availableStatusSources.map { ($0, Self.statusSourceDisplayNames[$0] ?? $0) }
    }
    var settingsSelectedStatusSource: String { selectedStatusSource }
    func settingsSelectStatusSource(id: String) { changeStatusSource(to: id) }

    var settingsEvolutionEnabled: Bool { evolutionEnabled }
    func settingsSetEvolutionEnabled(_ on: Bool) { setEvolutionEnabled(on) }
    var settingsBarAlwaysVisible: Bool { barAlwaysVisible }
    func settingsSetBarAlwaysVisible(_ on: Bool) { setBarAlwaysVisible(on) }
    var settingsDNDEnabled: Bool { dndEnabled }
    func settingsSetDND(_ on: Bool) { setDND(on) }

    func settingsResetAllXP() { resetAllXP() }

    var settingsHooksInstalled: Bool { ClaudeHookInstaller.isInstalled() }
    func settingsToggleHooks() { toggleClaudeHooks() }
    var settingsFullDiskAccessGranted: Bool { FullDiskAccess.isGranted() }
    func settingsOpenFullDiskAccess() { openFullDiskAccess() }

    var settingsBattlePeers: [(id: String, name: String, dnd: Bool)] {
        battlePeers.map { ($0.id, $0.name, $0.dnd) }
    }
    func settingsChallenge(peerID: String) { challenge(peerID: peerID) }
    func settingsStare(peerID: String) { stare(peerID: peerID) }

    func settingsQuit() { quit() }
}
