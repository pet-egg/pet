import AppKit

/// 대전을 신청한 쪽이 보는 카운트다운. 펫 위에 작게 떠서 20초 동안 줄어드는 막대를
/// 보여 준다. 상대가 수락/거절하면 호출자가 바로 `hide()` 하고, 시간이 다 될 때까지
/// 응답이 없으면 호출자가 "상대가 응답하지 않음" 모달을 띄운다 — 이 창은 순수하게
/// 남은 시간을 그리기만 한다(모달 판단은 네트워크 결과가 한다).
///
/// `ignoresMouseEvents` 라 20초 동안 떠 있어도 뒤에서 하던 작업의 클릭을 가로채지
/// 않는다.
final class ChallengeCountdownWindow: NSPanel {
    private let view = CountdownView()
    private static let gap: CGFloat = 6
    private static let size = NSSize(width: 200, height: 42)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `petFrame`(화면 좌표) 위에 카운트다운을 띄우고 `duration` 동안 막대를 줄인다.
    func show(peerName: String, above petFrame: NSRect, duration: TimeInterval) {
        var origin = NSPoint(
            x: petFrame.midX - Self.size.width / 2,
            y: petFrame.maxY + Self.gap
        )
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - Self.size.width - 4)
            if origin.y + Self.size.height > visible.maxY {
                origin.y = petFrame.minY - Self.size.height - Self.gap
            }
            origin.y = max(origin.y, visible.minY + 4)
        }
        setFrame(NSRect(origin: origin, size: Self.size), display: true)
        view.frame = NSRect(origin: .zero, size: Self.size)
        view.start(peerName: peerName, duration: duration)
        orderFrontRegardless()
    }

    func hide() {
        view.stop()
        orderOut(nil)
    }

    var isShowing: Bool { isVisible }
}

/// 어두운 둥근 카드에 "OO에게 신청 중…" 문구와, 20초 동안 오른쪽에서 왼쪽으로
/// 줄어드는 주황색 막대를 그린다. 1/30초 타이머로 다시 그린다.
private final class CountdownView: NSView {
    private var timer: Timer?
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 20
    private var peerName: String = ""

    override var isFlipped: Bool { true }

    func start(peerName: String, duration: TimeInterval) {
        self.peerName = peerName
        self.duration = duration
        self.startTime = Date().timeIntervalSinceReferenceDate
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.needsDisplay = true
            if self.progress >= 1 { self.timer?.invalidate(); self.timer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        needsDisplay = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var progress: CGFloat {
        guard duration > 0 else { return 1 }
        let p = (Date().timeIntervalSinceReferenceDate - startTime) / duration
        return CGFloat(min(max(p, 0), 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        // 어두운 둥근 카드.
        let card = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.13, alpha: 0.97).setFill()
        card.fill()
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        card.lineWidth = 1
        card.stroke()

        let pad: CGFloat = 12

        // 문구.
        let title = "\(peerName)에게 신청 중…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        title.draw(at: NSPoint(x: pad, y: 8), withAttributes: attrs)

        // 남은 초(오른쪽 위).
        let remaining = max(0, Int(ceil(duration * Double(1 - progress))))
        let secs = "\(remaining)s" as NSString
        let secAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1),
        ]
        let secSize = secs.size(withAttributes: secAttrs)
        secs.draw(at: NSPoint(x: bounds.width - pad - secSize.width, y: 8), withAttributes: secAttrs)

        // 줄어드는 막대.
        let trackRect = NSRect(x: pad, y: bounds.height - 14, width: bounds.width - pad * 2, height: 6)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 3, yRadius: 3)
        NSColor(calibratedWhite: 1, alpha: 0.14).setFill()
        track.fill()

        let fillW = trackRect.width * (1 - progress)
        if fillW > 0.5 {
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillW, height: trackRect.height)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
            let color: NSColor = progress < 0.75 ? .systemOrange : .systemRed
            color.setFill()
            fill.fill()
        }
    }
}
