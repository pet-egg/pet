import AppKit

/// 대전을 받은 쪽에 먼저 뜨는 작은 흰색 "Challenge" 말풍선. 업무 중 갑자기 가운데
/// 모달이 튀어나오는 걸 막으려고, 처음에는 펫의 오른쪽 위에 이것만 조용히 띄운다.
/// 누르면 수락/거절 모달(`BattleDialog.challenge`)로 이어지고, 누르지 않고 시간이
/// 지나면 소리 없이 사라진다(= 무응답. 신청자 쪽은 카운트다운이 끝나며 안내를 받는다).
///
/// `SpeechBubbleWindow` 와 달리 **클릭을 받아야** 하므로 `ignoresMouseEvents` 를
/// 켜지 않는다. 대신 `.nonactivatingPanel` 이라 눌러도 사용자가 타이핑하던 창에서
/// 포커스를 빼앗지 않는다.
final class ChallengeBubbleWindow: NSPanel {
    private let bubble = ChallengeBubbleView()
    private var dismissTimer: Timer?

    /// 펫 오른쪽 위 꼭짓점에서 말풍선을 얼마나 띄울지.
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
        ignoresMouseEvents = false // 이 말풍선은 클릭이 목적이다
        hidesOnDeactivate = false
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 눌렀을 때. 한 번만 불리고 말풍선은 스스로 사라진다.
    var onClick: (() -> Void)? {
        get { bubble.onClick }
        set { bubble.onClick = { [weak self] in self?.hide(); newValue?() } }
    }

    /// `petFrame`(화면 좌표)의 오른쪽 위에 말풍선을 띄우고, `duration` 뒤에 스스로
    /// 사라지며 `onTimeout` 을 부른다(사용자가 그 사이 누르지 않았다는 뜻).
    func show(above petFrame: NSRect, duration: TimeInterval, onTimeout: @escaping () -> Void) {
        let size = bubble.fittingSize()

        // 꼬리는 말풍선 왼쪽 아래에서 펫의 오른쪽 위를 가리킨다. 그래서 말풍선 본체는
        // 펫의 오른쪽 위 꼭짓점 위로, 살짝 오른쪽으로 걸치게 놓는다.
        var origin = NSPoint(
            x: petFrame.maxX - ChallengeBubbleView.tailInset - ChallengeBubbleView.tailWidth / 2,
            y: petFrame.maxY + Self.gap
        )

        // 화면 밖으로 나가지 않게 민다. 오른쪽/위가 막히면 각각 반대로 넘긴다.
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
            onTimeout()
        }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        orderOut(nil)
    }

    var isShowing: Bool { isVisible }
}

/// 흰색 둥근 말풍선 본체 + 아래를 가리키는 꼬리 + "Challenge" 글자. 눌리면 `onClick`.
private final class ChallengeBubbleView: NSView {
    static let tailHeight: CGFloat = 8
    static let tailWidth: CGFloat = 14
    /// 꼬리 중심이 말풍선 왼쪽 끝에서 얼마나 안쪽에 있는지(펫 오른쪽 위를 가리키게).
    static let tailInset: CGFloat = 18
    static let cornerRadius: CGFloat = 10
    private static let padding = NSEdgeInsets(top: 7, left: 13, bottom: 7, right: 13)
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let text = "Challenge"

    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    /// 글자에 맞춘 말풍선 전체 크기(꼬리 포함).
    func fittingSize() -> NSSize {
        let textSize = (Self.text as NSString).size(withAttributes: [.font: Self.font])
        let w = ceil(textSize.width) + Self.padding.left + Self.padding.right
        let h = ceil(textSize.height) + Self.padding.top + Self.padding.bottom + Self.tailHeight
        return NSSize(width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.tailHeight)
        let path = NSBezierPath(roundedRect: body, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        // 꼬리: 본체 왼쪽 아래에서 아래로 내려가 펫을 가리킨다.
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

    // 손 모양 커서로 누를 수 있음을 알린다.
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
