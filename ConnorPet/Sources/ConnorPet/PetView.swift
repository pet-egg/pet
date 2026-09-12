import AppKit

/// Renders the current sprite frame and owns all pointer interaction
/// (drag → running-left/right, hover → jumping), mirroring
/// `usePetPointerInteraction.ts` + `PetOverlay.tsx`'s render precedence.
final class PetView: NSView {
    /// Height reserved at the bottom of the view for the XP bar (game convention
    /// puts progression bars along the bottom, not overhead — overhead space
    /// reads as health/status). The sprite renders in the square above it.
    static let barAreaHeight: CGFloat = 18

    private var spriteSheet: SpriteSheet
    private var trackingArea: NSTrackingArea?

    private var frameIndex = 0
    private var frameTimer: Timer?
    private var currentFrames: SpriteAnimationFrames?
    private var currentAnimationKey: String?

    // XP bar inputs. `percent` (0...1) sets the fill width; `stage` (0/1/2)
    // sets the fill color, so the bar's color tracks the pet's evolution stage.
    private var progressPercent: Double = 0
    private var progressStage: Int = 0
    // When true the bar is always drawn; when false it only appears on hover
    // (menu-bar toggle, see AppDelegate). Default on.
    private var barAlwaysVisible = true

    // Live inputs, combined exactly like `selectPetAnimationName`.
    private var baseAnimation: PetAnimationName = .idle
    private var dragging = false
    private var dragDirection: PetDragDirection?
    private var hovering = false
    /// 호버 중에만 뜨는 상세 문구. 그리기는 XPDetailWindow 가 한다.
    private(set) var progressDetail = ""
    private var dragBaselineX: CGFloat = 0
    private var dragOffset: CGPoint = .zero
    private var didDragThisGesture = false

    /// Set while the pet is delivering a briefing — outranks hover so the
    /// pointer sitting on the pet (which it always is, right after a click)
    /// does not replace the waving motion with the hover jump.
    private var speaking = false
    private var speakingTimer: Timer?
    /// 깨우기 연출이 끝난 뒤 말하기로 넘어가는 예약. 도중에 다시 클릭하면 취소한다.
    private var wakeWorkItem: DispatchWorkItem?

    /// Motion pinned from the right-click menu. While set it overrides the
    /// agent state entirely, so any motion can be inspected on demand; picking
    /// "자동" clears it and hands control back to the live status.
    ///
    /// 고정은 `pinDuration` 뒤에 스스로 풀린다. 손으로 풀어 줄 때까지 남아 있으면
    /// 펫이 에이전트 상태와 무관한 자세로 굳어 버리고, 그 사실을 알아채기 어렵다 —
    /// 작업이 돌아가는지 보려고 띄워 둔 물건인데 상태를 안 보여 주게 된다.
    private var pinnedAnimation: PetAnimationName?
    private var pinReleaseTimer: Timer?

    /// 손으로 지시한 모션이 유지되는 시간. 자체검증이 1분을 기다리지 않도록
    /// 환경 변수로 줄일 수 있게 열어 뒀다 — 평소에는 60초다.
    static let pinDuration: TimeInterval = ProcessInfo.processInfo
        .environment["CONNORPET_PIN_SECONDS"].flatMap(Double.init) ?? 60

    /// 한 바퀴만 돌고 스스로 물러나는 모션(불뿜기). 고정(pin)과 달리 끝나면
    /// 원래 상태로 돌아간다 — 체크포인트 동작이라 계속 뿜고 있으면 곤란하다.
    private var oneShotAnimation: PetAnimationName?

    /// 속성기가 실제로 재생됐을 때. 호출부가 시각을 기록한다.
    var onSkillUsed: (() -> Void)?

    /// 속성기 프레임이 바뀔 때마다 호출된다. 매니페스트 좌표(프레임 기준)를
    /// 그대로 넘기고, 화면 좌표 환산과 그리기는 호출부가 한다.
    /// grow 가 0 이면 이번 프레임에는 이펙트가 없다.
    var onFlameFrame: ((_ mouthInFrame: CGPoint, _ grow: CGFloat) -> Void)?

    var onRequestWindowMove: ((_ screenOrigin: CGPoint) -> Void)?
    /// Left click (not a drag). The delegate returns the text to say, or nil
    /// to stay quiet.
    var onClick: (() -> String?)?
    var onSpeak: ((_ text: String, _ duration: TimeInterval, _ style: BubbleStyle) -> Void)?
    var onSilence: (() -> Void)?
    /// Fires once each time the pointer enters the pet — the "you noticed it"
    /// gesture AppDelegate uses to dismiss a lingering review/헤롱헤롱 state.
    var onHoverEnter: (() -> Void)?
    /// 우클릭 메뉴의 "설정…"을 눌렀을 때. 설정 창을 여는 건 AppDelegate 몫이다 —
    /// 메뉴바 아이콘이 가려 접근 못 하는 사용자를 위한 두 번째 진입점이다.
    var onOpenSettings: (() -> Void)?
    /// 우클릭 메뉴의 "방해금지 모드"를 눌렀을 때. 실제 토글·저장·광고는 AppDelegate 몫.
    var onToggleDND: (() -> Void)?
    /// 방해금지 모드가 켜져 있는지. 우클릭 메뉴 체크 표시에 쓴다 — AppDelegate 가
    /// 값을 바꿀 때마다 여기에 반영한다.
    var dndEnabled = false
    /// 호버가 켜지고 꺼질 때. 경험치 상세 창을 여닫는 데 쓴다 — 그 문구는 펫 창보다
    /// 길어서 별도 창(XPDetailWindow)에 그린다.
    var onHoverChanged: ((Bool) -> Void)?

    init(spriteSheet: SpriteSheet) {
        self.spriteSheet = spriteSheet
        super.init(frame: .zero)
        wantsLayer = true
        applyDisplayAnimation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Public: base agent-status animation

    func setBaseAnimation(_ name: PetAnimationName) {
        guard baseAnimation != name else { return }
        baseAnimation = name
        applyDisplayAnimation()
    }

    // MARK: - Public: XP bar

    /// Updates the XP bar fill (`percent`, 0...1), its color (`stage`), and the
    /// text shown while hovering (`detail`, 예: "EXP 100,000 / 200,000,000 - 0.05%").
    func setProgress(percent: Double, stage: Int, detail: String) {
        let clamped = min(1, max(0, percent))
        guard clamped != progressPercent || stage != progressStage || detail != progressDetail else { return }
        progressPercent = clamped
        progressStage = stage
        progressDetail = detail
        needsDisplay = true
    }

    /// Whether the XP bar shows all the time (true) or only while hovered (false).
    func setBarAlwaysVisible(_ always: Bool) {
        guard always != barAlwaysVisible else { return }
        barAlwaysVisible = always
        needsDisplay = true
    }

    // MARK: - Public: swapping the active character

    /// Switches the rendered character (e.g. via the menu-bar picker) while
    /// preserving live interaction state (hover/drag/base status animation).
    /// 현재 재생 중인 시트. 호출부가 매니페스트(프레임 크기 등)를 읽는다.
    var currentSpriteSheet: SpriteSheet { spriteSheet }

    func setSpriteSheet(_ newSheet: SpriteSheet) {
        spriteSheet = newSheet
        currentAnimationKey = nil // force applyDisplayAnimation to restart from frame 0
        applyDisplayAnimation()
    }

    // MARK: - Selection precedence (mirrors selectPetAnimationName)

    private func selectedAnimation() -> PetAnimationName {
        if dragging {
            switch dragDirection {
            case .right: return .runningRight
            case .left: return .runningLeft
            case nil: return pinnedAnimation ?? baseAnimation
            }
        }
        if let oneShot = oneShotAnimation {
            return oneShot
        }
        if let pinned = pinnedAnimation {
            return pinned
        }
        if speaking {
            return .waving
        }
        if hovering {
            return .jumping
        }
        return baseAnimation
    }

    // MARK: - Speaking

    /// 브리핑 말풍선이 떠 있는 시간. 여러 세션을 훑어 읽을 수 있어야 한다.
    static let briefingDuration: TimeInterval = 30
    /// 퀘스트 축하 말풍선 하나가 떠 있는 시간. 한 줄짜리라 브리핑만큼 길 이유가 없고,
    /// 여러 개가 줄줄이 이어질 수 있어 길면 지루해진다.
    /// 자체검증이 6초씩 기다리지 않도록 환경 변수로 줄일 수 있게 열어 뒀다.
    static let celebrationDuration: TimeInterval = ProcessInfo.processInfo
        .environment["CONNORPET_CELEBRATION_SECONDS"].flatMap(Double.init) ?? 6
    /// 축하와 축하 사이 간격. 0 으로 붙이면 앞 말풍선이 사라지는 프레임과 다음 것이
    /// 뜨는 프레임이 겹쳐 두 개가 한 번에 보인다.
    static let celebrationGap: TimeInterval = 0.5

    /// 자고 있으면 먼저 깨우고 나서 말한다.
    ///
    /// 잠든 채로 말풍선만 뜨면 깨어난 느낌이 없어서, 잠듦 상태일 때만 점프 모션을
    /// 한 번 재생하고 그게 끝나면 말한다. 전용 "기지개" 행이 없어 jumping 을 쓴다 —
    /// 화들짝 일어나는 것으로 읽힌다. 자고 있지 않으면 곧장 말한다.
    private func speakWaking(_ text: String) {
        wakeWorkItem?.cancel()
        wakeWorkItem = nil

        guard baseAnimation == .idle, playOnce(.jumping) else {
            speak(text)
            return
        }
        // 점프 한 바퀴가 끝나는 시점에 말하기로 넘긴다. 길이는 매니페스트에서 읽으므로
        // 프레임 타이밍을 바꿔도 따라온다.
        let ms = spriteSheet.resolvedAnimation(for: .jumping)?.durationsMs.reduce(0, +) ?? 900
        let work = DispatchWorkItem { [weak self] in
            self?.wakeWorkItem = nil
            self?.speak(text)
        }
        wakeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000, execute: work)
    }

    /// 아직 띄우지 못한 축하들. 한 번에 여러 퀘스트가 잡히면 여기에 줄을 선다.
    private var celebrationQueue: [(text: String, style: BubbleStyle)] = []
    /// 지금 떠 있는 말풍선이 축하인가(브리핑과 구분해야 이어 붙일지 판단할 수 있다).
    private var celebrating = false
    private var celebrationWork: DispatchWorkItem?

    /// 퀘스트 축하를 줄 세운다. 한 번에 하나씩, 앞 것이 사라진 뒤에 다음이 뜬다 —
    /// 동시에 부르면 말풍선이 같은 자리에 겹쳐 뒤엣것만 읽히기 때문이다.
    ///
    /// 고정된 모션은 밀어내지 않는다. 손으로 자세를 잡아 놓고 보는 중일 수 있는데
    /// 축하가 그것을 덮으면 지시를 뺏는 셈이다 — 말풍선과 점프만 쓴다.
    func enqueueCelebration(_ text: String, style: BubbleStyle = .reward) {
        celebrationQueue.append((text, style))
        drainCelebrations()
    }

    /// 줄에서 하나를 꺼내 띄운다.
    ///
    /// 무언가를 이미 말하는 중이면 아무것도 하지 않고 돌아간다. 그 말이 끝날 때
    /// (`speak` 의 타이머나 `stopSpeaking`)가 이 함수를 다시 부르므로 줄은 저절로
    /// 이어진다 — 브리핑을 보는 중에 축하가 끼어들어 말을 자르지 않는다.
    private func drainCelebrations() {
        guard !celebrationQueue.isEmpty, !speaking else { return }
        celebrating = true
        if pinnedAnimation == nil { _ = playOnce(.jumping) }
        let next = celebrationQueue.removeFirst()
        speak(next.text, duration: Self.celebrationDuration, style: next.style)
    }

    /// 말풍선이 사라진 직후에 부른다. 간격을 두고 다음 축하로 넘어간다.
    private func scheduleCelebrationDrain() {
        guard !celebrationQueue.isEmpty else { return }
        celebrationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.celebrationWork = nil
            self?.drainCelebrations()
        }
        celebrationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.celebrationGap, execute: work)
    }

    /// 줄 서 있는 축하 개수. 자체검증이 본다.
    var pendingCelebrations: Int { celebrationQueue.count }

    private func speak(_ text: String, duration: TimeInterval = PetView.briefingDuration,
                       style: BubbleStyle = .normal) {
        speaking = true
        applyDisplayAnimation()
        onSpeak?(text, duration, style)

        speakingTimer?.invalidate()
        speakingTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.speaking = false
            self.celebrating = false
            self.applyDisplayAnimation()
            self.scheduleCelebrationDrain()
        }
    }

    private func stopSpeaking() {
        wakeWorkItem?.cancel()
        wakeWorkItem = nil
        speakingTimer?.invalidate()
        speakingTimer = nil
        guard speaking else { return }
        speaking = false
        celebrating = false
        onSilence?()
        applyDisplayAnimation()
        // 클릭으로 말풍선을 닫았을 때도 줄이 이어져야 한다. 브리핑이 곧바로 이어지면
        // drainCelebrations 가 speaking 을 보고 물러나고, 그 브리핑이 끝날 때 다시 걸린다.
        scheduleCelebrationDrain()
    }

    // MARK: - Right-click motion menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        // 기본값(true)이면 AppKit 이 target/action 존재 여부만 보고 활성화를 다시
        // 판단해서, 우리가 준 isEnabled 를 덮어쓴다. 그러면 이 펫에 없는 모션도
        // 눌리는 것처럼 보이고 눌러도 아무 일이 없다.
        menu.autoenablesItems = false
        menu.addItem(withTitle: "모션 (\(Int(Self.pinDuration))초 뒤 자동 복귀)",
                     action: nil, keyEquivalent: "").isEnabled = false

        let auto = NSMenuItem(title: "자동 (에이전트 상태 따르기)", action: #selector(pinMotion(_:)), keyEquivalent: "")
        // 고정이 영구적이지 않다는 것을 메뉴에서 알 수 있어야 한다.
        auto.toolTip = "고른 모션은 \(Int(Self.pinDuration))초 뒤 저절로 여기로 돌아옵니다."
        auto.target = self
        auto.representedObject = nil as String?
        auto.state = pinnedAnimation == nil ? .on : .off
        auto.isEnabled = true
        menu.addItem(auto)
        menu.addItem(.separator())

        for name in PetAnimationName.allCases {
            // 이 펫의 매니페스트에 없는 행은 재생할 수가 없다. 회색으로 남겨 두느니
            // 아예 안 보이는 게 낫다 — 속성기는 포켓몬 타입에 묶여 있어서, 파이리
            // 메뉴에 "물뿜기"가 있는 것 자체가 이상하다.
            guard spriteSheet.animation(named: name.rawValue) != nil else { continue }

            // 단축키가 붙은 모션은 고정이 아니라 그 자리에서 한 번 실행되는 동작이다.
            let shortcut = name.menuShortcut
            let action: Selector
            switch name {
            case _ where name.isSkill: action = #selector(useSkill(_:))
            case .waving:              action = #selector(speakBriefing(_:))
            default:                   action = #selector(pinMotion(_:))
            }
            let item = NSMenuItem(title: name.koreanLabel, action: action,
                                  keyEquivalent: shortcut ?? "")
            if shortcut != nil {
                // 기본값이 ⌘ 라서 비워야 글자 단독으로 먹는다.
                item.keyEquivalentModifierMask = []
            }
            item.target = self
            item.representedObject = name.rawValue
            item.state = (shortcut == nil && pinnedAnimation == name) ? .on : .off
            item.isEnabled = true
            menu.addItem(item)
        }

        // 설정과 종료를 맨 아래 한 묶음으로. 메뉴바 아이콘이 가려 접근 못 하는
        // 사용자를 위해, 메뉴바에 있던 기능을 모은 설정 창을 여기서도 연다.
        menu.addItem(.separator())

        // 방해금지 모드: 켜면 같은 Wi-Fi 상대가 거는 대전·노려보기를 받지 않는다.
        // 메뉴바·설정창과 같은 토글이라 어디서 켜든 상태가 일치한다.
        let dnd = NSMenuItem(title: "방해금지 모드", action: #selector(toggleDND(_:)), keyEquivalent: "")
        dnd.target = self
        dnd.state = dndEnabled ? .on : .off
        dnd.toolTip = "켜면 다른 사람이 대전·노려보기를 걸 수 없어요. 상대 목록엔 '방해금지 중'으로 보입니다."
        dnd.isEnabled = true
        menu.addItem(dnd)

        let settings = NSMenuItem(title: "설정…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        settings.isEnabled = true
        menu.addItem(settings)

        // 종료. 지금까지는 메뉴바 아이콘에서만 끌 수 있었는데, 펫이 눈앞에 있는데
        // 메뉴바까지 올라가야 하는 게 번거롭다.
        //
        // 단축키는 일부러 안 붙였다. 메뉴가 열린 상태에서 글자 키가 그대로 먹으므로
        // (a·s 가 그렇게 동작한다) 종료에까지 달면 오타 한 번에 앱이 꺼진다.
        let quit = NSMenuItem(title: "나가", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        quit.isEnabled = true
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// 좌클릭과 같은 동작 — 브리핑을 말한다. 좌클릭이 펫을 맞춰야 하는 반면
    /// 이쪽은 메뉴에서 s 로 바로 부를 수 있다.
    @objc private func speakBriefing(_ sender: NSMenuItem) {
        releasePin()
        stopSpeaking()
        if let text = onClick?(), !text.isEmpty {
            speakWaking(text)
        }
    }

    @objc private func toggleDND(_ sender: NSMenuItem) {
        onToggleDND?()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings?()
    }

    @objc private func useSkill(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let name = PetAnimationName(rawValue: raw) else { return }
        releasePin()
        if playOnce(name) {
            onSkillUsed?()
        }
    }

    @objc private func pinMotion(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String
        pin(raw.flatMap(PetAnimationName.init(rawValue:)))
    }

    /// 모션을 고정한다. `nil` 이면 지금 바로 에이전트 상태로 돌아간다.
    /// 메뉴가 부르는 통로이자 자체검증이 부르는 통로다.
    func pin(_ name: PetAnimationName?) {
        stopSpeaking()
        guard let name else {
            releasePin()
            return
        }
        pinnedAnimation = name
        schedulePinRelease()
        applyDisplayAnimation()
    }

    /// 지금 고정된 모션. 자체검증이 자동 해제를 확인할 때 본다.
    var pinnedMotion: PetAnimationName? { pinnedAnimation }

    /// 고정을 풀고 에이전트 상태로 되돌린다.
    private func releasePin() {
        pinReleaseTimer?.invalidate()
        pinReleaseTimer = nil
        guard pinnedAnimation != nil else { return }
        pinnedAnimation = nil
        applyDisplayAnimation()
    }

    /// 새로 지시할 때마다 시계를 처음부터 다시 잰다 — 방금 고른 모션이 앞선
    /// 지시의 남은 시간에 잘려 나가면 안 된다.
    private func schedulePinRelease() {
        pinReleaseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pinDuration, repeats: false) { [weak self] _ in
            self?.releasePin()
        }
        // .common 으로 넣는다. 기본 모드로만 걸면 메뉴가 열려 있거나 펫을 끌고 있는
        // 동안(이벤트 추적 모드) 시계가 멈춘다 — 끌어다 놓는 사이에 시간이 안 가는
        // 셈이라, 손을 떼기 전까지는 영영 안 풀린다.
        RunLoop.main.add(timer, forMode: .common)
        pinReleaseTimer = timer
    }

    private func applyDisplayAnimation() {
        let name = selectedAnimation()
        guard let frames = spriteSheet.resolvedAnimation(for: name), !frames.images.isEmpty else { return }

        let key = name.rawValue
        // Why: mirrors PetOverlay's restartKey — only restart from frame 0 when
        // the resolved animation actually changes; re-selecting the same one
        // (e.g. still hovering) must not visibly reset mid-loop.
        if key != currentAnimationKey {
            currentAnimationKey = key
            currentFrames = frames
            frameIndex = 0
            scheduleNextFrame()
            needsDisplay = true
            publishFlameState()
        }
    }

    private func scheduleNextFrame() {
        frameTimer?.invalidate()
        guard let frames = currentFrames, !frames.durationsMs.isEmpty else { return }
        let holdMs = frames.durationsMs[frameIndex % frames.durationsMs.count]
        frameTimer = Timer.scheduledTimer(withTimeInterval: holdMs / 1000.0, repeats: false) { [weak self] _ in
            self?.advanceFrame()
        }
    }

    private func advanceFrame() {
        guard let frames = currentFrames, !frames.images.isEmpty else { return }
        let next = frameIndex + 1
        // 1회 재생 모션은 마지막 프레임에서 멈추고 원래 상태로 돌아간다.
        if oneShotAnimation != nil, next >= frames.images.count {
            oneShotAnimation = nil
            onFlameFrame?(.zero, 0)
            currentAnimationKey = nil // 다음 모션을 0프레임부터 다시 시작시킨다
            applyDisplayAnimation()
            return
        }
        frameIndex = next % frames.images.count
        needsDisplay = true
        publishFlameState()
        scheduleNextFrame()
    }

    /// The square the sprite renders into — the whole view minus the XP-bar
    /// strip reserved along the bottom.
    private var spriteRect: NSRect {
        NSRect(x: 0, y: Self.barAreaHeight, width: bounds.width, height: bounds.height - Self.barAreaHeight)
    }

    /// 모션을 한 바퀴만 재생한다. 이 펫에 그 행이 없으면 아무것도 하지 않는다.
    @discardableResult
    func playOnce(_ name: PetAnimationName) -> Bool {
        guard spriteSheet.animation(named: name.rawValue) != nil else { return false }
        stopSpeaking()
        oneShotAnimation = name
        currentAnimationKey = nil
        applyDisplayAnimation()
        return true
    }

    /// 지금 재생 중인 프레임에 맞는 불길 상태를 호출부에 알린다.
    private func publishFlameState() {
        guard let skill = spriteSheet.manifest.skill,
              oneShotAnimation?.rawValue == skill.row,
              case let track = skill.mouthByFrame,
              track.indices.contains(frameIndex)
        else {
            onFlameFrame?(.zero, 0)
            return
        }
        let m = track[frameIndex]
        onFlameFrame?(CGPoint(x: m.x, y: m.y), CGFloat(m.grow))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let frames = currentFrames, frames.images.indices.contains(frameIndex) else { return }
        let image = frames.images[frameIndex]
        // Why: .sourceOver blends onto whatever pixels are already in the layer's
        // backing store. Since every frame has transparent margins, switching to a
        // differently-shaped sprite (e.g. via the menu-bar pet picker, or even
        // Totodile's own asymmetric run-cycle frames) left a faint ghost of the
        // previous frame visible wherever the new frame is transparent but the old
        // one wasn't. .copy overwrites the whole rect (color + alpha) with the new
        // frame's pixels instead of blending, so there's nothing left to bleed through.
        image.draw(in: spriteRect, from: .zero, operation: .copy, fraction: 1.0)

        // The bar strip is never touched by the sprite draw above, so clear it
        // to transparent each frame (.copy) before optionally drawing the bar —
        // otherwise a hidden bar (hover-only mode, pointer gone) would linger.
        let barArea = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barAreaHeight)
        NSColor.clear.setFill()
        NSGraphicsContext.current?.compositingOperation = .copy
        barArea.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        if barAlwaysVisible || hovering {
            drawXPBar(in: barArea)
        }
    }

    private func drawXPBar(in area: NSRect) {
        let hInset: CGFloat = 12
        let barHeight: CGFloat = 8
        let track = NSRect(
            x: area.minX + hInset,
            y: area.midY - barHeight / 2,
            width: area.width - hInset * 2,
            height: barHeight
        )
        let radius = barHeight / 2

        // Track (empty portion) — dark, semi-transparent, faint border.
        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0, alpha: 0.42).setFill()
        trackPath.fill()
        NSColor(calibratedWhite: 1, alpha: 0.28).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        // Filled portion — width is the XP %, color is the evolution stage.
        guard progressPercent > 0 else { return }
        let fillWidth = max(barHeight, track.width * CGFloat(progressPercent))
        let fill = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
        let fillPath = NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius)
        Self.stageColor(progressStage).setFill()
        fillPath.fill()
        // Glossy top highlight so the fill reads as a filled gauge, not a flat block.
        let gloss = NSRect(x: fill.minX + 1, y: fill.midY, width: fill.width - 2, height: fill.height / 2 - 1)
        let glossPath = NSBezierPath(roundedRect: gloss, xRadius: radius / 2, yRadius: radius / 2)
        NSColor(calibratedWhite: 1, alpha: 0.30).setFill()
        glossPath.fill()
    }

    /// Fill color per evolution stage: green (base) → blue (1st) → gold (final),
    /// so the bar's color alone tells you how far the pet has evolved.
    private static func stageColor(_ stage: Int) -> NSColor {
        switch stage {
        case 0: return NSColor(calibratedRed: 0.37, green: 0.82, blue: 0.40, alpha: 1)
        case 1: return NSColor(calibratedRed: 0.29, green: 0.64, blue: 1.00, alpha: 1)
        default: return NSColor(calibratedRed: 1.00, green: 0.79, blue: 0.23, alpha: 1)
        }
    }

    // MARK: - Pointer interaction

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHoverEnter?()
        onHoverChanged?(true)
        applyDisplayAnimation()
        if !barAlwaysVisible { needsDisplay = true } // reveal hover-only bar
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        onHoverChanged?(false)
        applyDisplayAnimation()
        if !barAlwaysVisible { needsDisplay = true } // hide hover-only bar again
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        didDragThisGesture = false
        dragDirection = nil
        dragBaselineX = event.locationInWindow.x
        dragOffset = CGPoint(
            x: event.locationInWindow.x,
            y: event.locationInWindow.y
        )
        applyDisplayAnimation()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let deltaX = event.locationInWindow.x - dragBaselineX
        let (direction, accepted) = nextPetDragAnimation(current: dragDirection, deltaX: deltaX)
        if accepted {
            dragDirection = direction
            dragBaselineX = event.locationInWindow.x
            didDragThisGesture = true
            applyDisplayAnimation()
        }

        // Move the owning window with the pointer (screen coordinates).
        guard let window = window else { return }
        let mouseLocationInScreen = window.convertPoint(toScreen: event.locationInWindow)
        let newOrigin = CGPoint(
            x: mouseLocationInScreen.x - dragOffset.x,
            y: mouseLocationInScreen.y - dragOffset.y
        )
        onRequestWindowMove?(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        let wasClick = !didDragThisGesture
        dragging = false
        dragDirection = nil

        if wasClick {
            // A second click while talking dismisses the bubble instead of
            // restarting it — otherwise the pet cannot be told to be quiet.
            if speaking {
                stopSpeaking()
            } else if let text = onClick?(), !text.isEmpty {
                speakWaking(text)
                return
            }
        }
        applyDisplayAnimation()
    }
}
