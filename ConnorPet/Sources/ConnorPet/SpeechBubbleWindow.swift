import AppKit

/// 말풍선 종류. 경험치가 오른 것을 알리는 말풍선은 브리핑과 다르게 그린다 —
/// 브리핑은 읽어야 하는 글이고, 이쪽은 "얼마 올랐다" 가 눈에 들어와야 한다.
enum BubbleStyle {
    /// 브리핑·평소 말하기. 시스템 배경색을 따른다(다크 모드면 어둡다).
    case normal
    /// 경험치 알림. 흰 바탕에 경험치 바와 같은 초록을 쓴다.
    case reward

    /// 경험치 바 0단계 색. 바와 말풍선이 같은 초록이어야 "그 경험치" 로 읽힌다
    /// (`PetView.stageColor(0)` 과 같은 값 — 색을 옮길 때 두 곳을 함께 고쳐야 한다).
    static let rewardGreen = NSColor(calibratedRed: 0.37, green: 0.82, blue: 0.40, alpha: 1)
}

/// The rounded panel body plus the little tail that points down at the pet.
private final class SpeechBubbleView: NSView {
    static let tailHeight: CGFloat = 9
    static let tailWidth: CGFloat = 16
    static let cornerRadius: CGFloat = 12
    static let padding = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)

    var tailCenterX: CGFloat = 0 { didSet { needsDisplay = true } }
    var style: BubbleStyle = .normal { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.tailHeight)
        let path = NSBezierPath(roundedRect: body, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        // Tail is clamped so it always sits on the bubble's own edge, even when
        // the pet is near a screen edge and the bubble had to shift sideways.
        let half = Self.tailWidth / 2
        let cx = min(max(tailCenterX, Self.cornerRadius + half), body.maxX - Self.cornerRadius - half)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - half, y: body.maxY - 1))
        tail.line(to: NSPoint(x: cx + half, y: body.maxY - 1))
        tail.line(to: NSPoint(x: cx, y: bounds.maxY))
        tail.close()
        path.append(tail)

        switch style {
        case .normal:
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        case .reward:
            // 다크 모드에서도 흰 바탕이다. 시스템 색을 따르면 초록 글자가 어두운
            // 바탕에 얹혀 경험치 바와 다른 색으로 보인다.
            NSColor.white.setFill()
            path.fill()
            BubbleStyle.rewardGreen.setStroke()
            path.lineWidth = 1.5
        }
        path.stroke()
    }
}

/// A borderless panel that floats just above the pet and shows what it is
/// saying. Separate from the pet window on purpose: the pet window is sized
/// tightly to the sprite, while this has to grow with the text.
/// 펫 창과 **같은 종류**(`NSWindow`)로 둔다. 예전에는 `NSPanel` 이었는데, 바탕화면
/// 위에서는 멀쩡히 보이면서 몇몇 앱 위에서만 보이지 않는다는 제보가 있었다. 펫 창만
/// `NSWindow` 였고 그것은 어디서든 보였다.
///
/// 층(`.floating`)·스페이스 설정·`hidesOnDeactivate` 는 이미 펫과 같았고, 실제로 다른
/// 앱을 앞에 두고 재도 윈도우 서버가 매긴 레이어가 셋 다 같았다(`CONNORPET_SELFTEST=overlay`).
/// 그래서 남은 차이는 창 **종류** 하나뿐이었다. 이 창들은 클릭을 통과시키므로
/// `.nonactivatingPanel` 로 얻을 것이 없어, 확실히 동작하는 쪽으로 맞췄다.
final class SpeechBubbleWindow: NSWindow {
    private let bubble = SpeechBubbleView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var dismissTimer: Timer?

    private static let maxWidth: CGFloat = 340
    private static let gap: CGFloat = 6

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true // never steals a click meant for the pet
        hidesOnDeactivate = false

        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false

        bubble.addSubview(label)
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `text` above `petFrame` (screen coordinates) and hides it again
    /// after `duration`.
    func show(text: String, above petFrame: NSRect, duration: TimeInterval,
              style: BubbleStyle = .normal) {
        let inset = SpeechBubbleView.padding
        let textWidth = Self.maxWidth - inset.left - inset.right

        bubble.style = style
        switch style {
        case .normal:
            label.textColor = .labelColor
            label.stringValue = text
        case .reward:
            label.attributedStringValue = Self.rewardText(text)
        }
        label.preferredMaxLayoutWidth = textWidth
        let textSize = label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))

        let bodyWidth = min(Self.maxWidth, textSize.width + inset.left + inset.right)
        let bodyHeight = textSize.height + inset.top + inset.bottom
        let total = NSSize(width: bodyWidth, height: bodyHeight + SpeechBubbleView.tailHeight)

        label.frame = NSRect(x: inset.left, y: inset.top, width: bodyWidth - inset.left - inset.right, height: textSize.height)

        var origin = NSPoint(
            x: petFrame.midX - total.width / 2,
            y: petFrame.maxY + Self.gap
        )

        // Keep the whole bubble on the pet's own screen: shift sideways if it
        // would hang off, and flip below the pet if there is no room above.
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - total.width - 4)
            if origin.y + total.height > visible.maxY {
                origin.y = petFrame.minY - total.height - Self.gap
            }
            origin.y = max(origin.y, visible.minY + 4)
        }

        setFrame(NSRect(origin: origin, size: total), display: true)
        bubble.frame = NSRect(origin: .zero, size: total)
        bubble.tailCenterX = petFrame.midX - origin.x
        orderFrontRegardless()

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    /// 경험치 알림 문구. `+300,000 EXP` 처럼 숫자와 EXP 로 끝나는 부분에 형광펜을
    /// 칠하듯 초록 배경을 깔고 글자도 진한 초록으로 바꾼다 — 얼마 올랐는지가 먼저
    /// 읽혀야 한다. 나머지 줄은 흰 바탕에 검은 글씨다.
    private static func rewardText(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2

        let full = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1),
            .paragraphStyle: paragraph,
        ])

        // "+숫자 EXP" 를 찾아 강조한다. 없으면 그냥 검은 글씨로 남는다.
        guard let range = text.range(of: #"\+[0-9,]+ EXP"#, options: .regularExpression) else {
            return full
        }
        full.addAttributes([
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.50, blue: 0.20, alpha: 1),
            .backgroundColor: BubbleStyle.rewardGreen.withAlphaComponent(0.28),
        ], range: NSRange(range, in: text))
        return full
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        orderOut(nil)
    }

    var isShowing: Bool { isVisible }
}
