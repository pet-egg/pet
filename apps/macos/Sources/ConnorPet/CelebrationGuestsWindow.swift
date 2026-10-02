import AppKit

/// 결혼식 축하에 "참여" 했을 때, 같은 Wi-Fi 에서 발견된 **다른 사람들의 펫**을
/// 내 화면의 내 펫 주위로 불러와 함께 축하하게 하는 오버레이.
///
/// 핵심: 남의 화면에는 아무것도 띄우지 않는다. 상대 펫 종류(slug)는 이미 Bonjour
/// TXT 레코드로 발견돼 있으니(= `BattlePeer.pet`), 네트워크로 무언가를 보내지 않고
/// 그 정보만으로 이 화면에 손님 펫들을 그린다. 그래서 "내 화면에 다른 펫들이
/// 참여해 여러 마리가 된" 상태가 된다.
///
/// 불길·빵빠레와 같은 결의 클릭-통과 투명 창. 잠깐 떴다가 스스로 사라진다.
final class CelebrationGuestsWindow: NSWindow {
    /// 한 번 참여에 보여 줄 손님 펫 수 상한. 너무 많으면 화면을 가린다.
    static let maxGuests = 8
    /// 손님들이 머무는 시간(초). 빵빠레(약 5.2초)와 대략 맞춘다.
    static let visibleDuration: TimeInterval = 5.2
    private static let fadeDuration: TimeInterval = 0.6

    private var guests: [CelebrationGuest] = []
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        let view = NSView()
        view.wantsLayer = true
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 손님 펫들을 내 펫 주위에 불러온다.
    /// - Parameters:
    ///   - slugs: 참여하는 다른 사람들의 펫 slug. 빈 배열이면 아무것도 안 한다.
    ///   - petFrame: 내 펫 창의 화면 좌표.
    func welcome(slugs: [String], around petFrame: NSRect) {
        let slugs = Array(slugs.prefix(Self.maxGuests))
        guard !slugs.isEmpty else { return }

        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.main
        guard let screenFrame = screen?.frame, let content = contentView else { return }

        hideWork?.cancel()
        guests.forEach { $0.remove() }
        guests.removeAll()

        setFrame(screenFrame, display: true)
        content.frame = NSRect(origin: .zero, size: screenFrame.size)
        content.alphaValue = 1

        // 창 좌표(원점 = 화면 왼쪽아래)로 환산한 내 펫.
        let petW = petFrame.width
        let petCenterX = petFrame.midX - screenFrame.minX
        // 펫 스프라이트는 창 위쪽에 정사각형(한 변 = 너비)으로 그려진다.
        let spriteCenterY = (petFrame.maxY - screenFrame.minY) - petW / 2

        let size = petW * 0.92            // 손님은 내 펫보다 살짝 작게 — 주인공은 내 펫.
        let spacing = petW * 0.8

        for (i, slug) in slugs.enumerated() {
            // 1,-1,2,-2… 순으로 좌우 번갈아 — 내 펫을 가운데 두고 양옆으로 퍼진다.
            let step = (i / 2) + 1
            let dir: CGFloat = (i % 2 == 0) ? 1 : -1
            var cx = petCenterX + dir * CGFloat(step) * spacing
            // 화면 밖으로 나가면 안쪽으로 접어 넣는다(겹쳐도 여러 마리인 건 보인다).
            cx = min(max(cx, size/2), screenFrame.width - size/2)
            // 뒷줄은 살짝 올려 입체감을 준다.
            let cy = spriteCenterY + CGFloat(step - 1) * (size * 0.18)

            guard let guest = CelebrationGuest(slug: slug) else { continue }
            let frame = NSRect(x: cx - size/2, y: cy - size/2, width: size, height: size)
            guest.install(in: content, frame: frame, bobPhase: Double(i) * 0.25)
            guests.append(guest)
        }
        guard !guests.isEmpty else { return }
        orderFrontRegardless()

        let hide = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: hide)
    }

    private func fadeOut() {
        guard let content = contentView else { hide(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            content.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.hide()
        })
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        guests.forEach { $0.remove() }
        guests.removeAll()
        orderOut(nil)
    }
}

/// 손님 펫 한 마리 — 스프라이트 프레임을 순환 재생하며 위아래로 통통 튄다.
private final class CelebrationGuest {
    private let imageView = NSImageView()
    private let frames: [NSImage]
    private let durationsMs: [Double]
    private var index = 0
    private var timer: Timer?
    private var baseFrame: NSRect = .zero

    init?(slug: String) {
        guard let sheet = try? SpriteSheet.bundled(slug: slug) else { return nil }
        // 축하하는 자리이니 점프 모션을 쓰되, 없는 펫은 기본(idle)로 떨어진다.
        let anim = sheet.resolvedAnimation(for: .jumping)
        guard let anim, !anim.images.isEmpty else { return nil }
        frames = anim.images
        durationsMs = anim.durationsMs
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        imageView.image = frames[0]
        imageView.wantsLayer = true
    }

    func install(in parent: NSView, frame: NSRect, bobPhase: Double) {
        baseFrame = frame
        imageView.frame = frame
        parent.addSubview(imageView)
        addBob(phase: bobPhase)
        scheduleNextFrame()
    }

    /// 위아래 통통 튀는 애니메이션. 손님마다 위상을 달리해 리듬이 겹치지 않게 한다.
    private func addBob(phase: Double) {
        guard let layer = imageView.layer else { return }
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = 0
        bob.toValue = baseFrame.height * 0.12
        bob.duration = 0.42
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timeOffset = phase
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bob, forKey: "bob")
    }

    private func scheduleNextFrame() {
        let holdMs = index < durationsMs.count ? durationsMs[index] : 120
        timer = Timer.scheduledTimer(withTimeInterval: holdMs / 1000, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.index = (self.index + 1) % self.frames.count
            self.imageView.image = self.frames[self.index]
            self.scheduleNextFrame()
        }
    }

    func remove() {
        timer?.invalidate()
        timer = nil
        imageView.layer?.removeAllAnimations()
        imageView.removeFromSuperview()
    }
}
