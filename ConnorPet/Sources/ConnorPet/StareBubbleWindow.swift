import AppKit

/// 누가 노려봤을 때 펫 오른쪽 위에 뜨는 작은 말풍선. 업무 중 갑자기 가운데 모달이
/// 튀어나오는 걸 막으려고(“모든 상호작용은 말풍선으로” 원칙 — README/CLAUDE 참고)
/// 먼저 이것만 조용히 띄운다. 말풍선 안에는 **상대 펫 도트**(얼굴 크롭)와 문구가
/// 함께 보이고, **누르면** 예전처럼 상대 펫 얼굴이 큼직하게 뜨는 모달로 이어진다.
/// 누르지 않고 시간이 지나면 소리 없이 사라진다.
///
/// `ChallengeBubbleWindow` 와 같은 클릭-가능 패널 구조다 — `ignoresMouseEvents` 를
/// 켜지 않고, `.nonactivatingPanel` 이라 눌러도 타이핑하던 창의 포커스를 뺏지 않는다.
final class StareBubbleWindow: NSPanel {
    private let bubble = StareBubbleView()
    private var dismissTimer: Timer?

    /// 펫 오른쪽 위 꼭짓점에서 말풍선을 얼마나 띄울지.
    private static let gap: CGFloat = 4

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 48),
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

    /// `petFrame`(화면 좌표) 오른쪽 위에 `dot`(상대 펫 도트, nil 이면 문구만)과 `text`
    /// 를 담은 말풍선을 띄우고, `duration` 뒤에 스스로 사라진다.
    func show(above petFrame: NSRect, dot: NSImage?, text: String, duration: TimeInterval) {
        bubble.configure(dot: dot, text: text)
        let size = bubble.fittingSize()

        // 꼬리는 말풍선 왼쪽 아래에서 펫의 오른쪽 위를 가리킨다.
        var origin = NSPoint(
            x: petFrame.maxX - StareBubbleView.tailInset - StareBubbleView.tailWidth / 2,
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
        }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        orderOut(nil)
    }

    var isShowing: Bool { isVisible }
}

/// 흰색 둥근 말풍선 본체 + 아래를 가리키는 꼬리 + [펫 도트][문구]. 눌리면 `onClick`.
private final class StareBubbleView: NSView {
    static let tailHeight: CGFloat = 8
    static let tailWidth: CGFloat = 14
    /// 꼬리 중심이 말풍선 왼쪽 끝에서 얼마나 안쪽에 있는지(펫 오른쪽 위를 가리키게).
    static let tailInset: CGFloat = 18
    static let cornerRadius: CGFloat = 10
    private static let padding = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 13)
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// 도트(펫 얼굴)의 한 변. 글자 높이와 비슷하게 맞춘다.
    private static let dotSide: CGFloat = 26
    /// 도트와 글자 사이 간격.
    private static let dotGap: CGFloat = 8

    var onClick: (() -> Void)?
    private var dot: NSImage?
    private var text = ""

    override var isFlipped: Bool { true }

    func configure(dot: NSImage?, text: String) {
        self.dot = dot
        self.text = text
        needsDisplay = true
    }

    private var hasDot: Bool { dot != nil }

    /// 내용(도트 + 글자)에 맞춘 말풍선 전체 크기(꼬리 포함).
    func fittingSize() -> NSSize {
        let textSize = (text as NSString).size(withAttributes: [.font: Self.font])
        let dotWidth = hasDot ? Self.dotSide + Self.dotGap : 0
        let contentH = max(ceil(textSize.height), hasDot ? Self.dotSide : 0)
        let w = Self.padding.left + dotWidth + ceil(textSize.width) + Self.padding.right
        let h = contentH + Self.padding.top + Self.padding.bottom + Self.tailHeight
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

        var x = Self.padding.left
        let contentH = body.height - Self.padding.top - Self.padding.bottom

        // 펫 도트. 픽셀 아트라 보간을 끄고(nearest) 또렷하게 그린다. 이 뷰는 flipped
        // (좌상단 원점)라, NSImage 를 그냥 그리면 위아래가 뒤집힌다 — `respectFlipped:
        // true` 로 대상 뷰의 flip 을 존중해 바로 서게 그린다.
        if let dot {
            let dotRect = NSRect(x: x, y: (body.height - Self.dotSide) / 2,
                                 width: Self.dotSide, height: Self.dotSide)
            dot.draw(in: dotRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            x += Self.dotSide + Self.dotGap
        }

        // 문구. 세로 가운데 정렬.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let ty = Self.padding.top + (contentH - size.height) / 2
        s.draw(at: NSPoint(x: x, y: ty), withAttributes: attrs)
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
