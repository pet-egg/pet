import AppKit

/// 결혼식 축하가 도는 동안 펫 오른쪽 위에 뜨는 작은 클릭 가능한 말풍선.
/// 누르면 빵빠레·손님 펫·축하 말풍선을 바로 끈다. 30초를 다 기다리지 않고
/// 사용자가 원할 때 정리할 수 있게 하는 통로다(모달 대신 말풍선 — CLAUDE.md).
///
/// `ChallengeBubbleWindow` 와 같은 결 — 클릭을 받아야 하므로 `ignoresMouseEvents`
/// 를 켜지 않고, `.nonactivatingPanel` 이라 눌러도 타이핑하던 창의 포커스를 안 뺏는다.
final class EffectOffBubbleWindow: NSPanel {
    private let bubble = EffectOffBubbleView()
    private var dismissTimer: Timer?
    private static let gap: CGFloat = 4

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false // 클릭이 목적이다
        hidesOnDeactivate = false
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 눌렀을 때. 말풍선은 스스로 사라지고 콜백이 불린다.
    var onClick: (() -> Void)? {
        get { bubble.onClick }
        set { bubble.onClick = { [weak self] in self?.hide(); newValue?() } }
    }

    /// `petFrame`(화면 좌표) 오른쪽 위에 띄우고, `duration` 뒤에 스스로 사라진다
    /// (축하가 저절로 끝나는 시점 — 그땐 끌 것도 없다).
    func show(above petFrame: NSRect, duration: TimeInterval) {
        let size = bubble.fittingSize()
        var origin = NSPoint(
            x: petFrame.maxX - EffectOffBubbleView.tailInset - EffectOffBubbleView.tailWidth / 2,
            y: petFrame.maxY + Self.gap
        )
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            if origin.y + size.height > visible.maxY {
                origin.y = petFrame.minY - size.height - Self.gap
            }
            origin.y = max(origin.y, visible.minY + 4)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        bubble.frame = NSRect(origin: .zero, size: size)
        orderFrontRegardless()

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        orderOut(nil)
    }

    var isShowing: Bool { isVisible }
}

/// 흰 둥근 말풍선 본체 + 아래를 가리키는 꼬리 + "이펙트 끄기" 글자. 눌리면 `onClick`.
private final class EffectOffBubbleView: NSView {
    static let tailHeight: CGFloat = 8
    static let tailWidth: CGFloat = 14
    static let tailInset: CGFloat = 18
    static let cornerRadius: CGFloat = 10
    private static let padding = NSEdgeInsets(top: 7, left: 13, bottom: 7, right: 13)
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let text = "✕ 이펙트 끄기"

    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    func fittingSize() -> NSSize {
        let textSize = (Self.text as NSString).size(withAttributes: [.font: Self.font])
        let w = ceil(textSize.width) + Self.padding.left + Self.padding.right
        let h = ceil(textSize.height) + Self.padding.top + Self.padding.bottom + Self.tailHeight
        return NSSize(width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.tailHeight)
        let path = NSBezierPath(roundedRect: body, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        let half = Self.tailWidth / 2
        let cx = min(max(Self.tailInset, Self.cornerRadius + half), body.maxX - Self.cornerRadius - half)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - half, y: body.maxY - 1))
        tail.line(to: NSPoint(x: cx + half, y: body.maxY - 1))
        tail.line(to: NSPoint(x: cx, y: bounds.maxY))
        tail.close()
        path.append(tail)

        NSColor.white.setFill()
        path.fill()
        NSColor(calibratedWhite: 0, alpha: 0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        ]
        let s = Self.text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: Self.padding.top), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
