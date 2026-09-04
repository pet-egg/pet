import AppKit

/// 경험치 상세("EXP 13,147,288 / 200,000,000 - 6.57%")를 펫 아래에 띄우는 작은 창.
///
/// 펫 창 안에 그리지 않는 이유: 기본형 펫의 창은 90pt 인데 이 문구는 그보다 훨씬
/// 길어서, 뷰가 잘라 버린 채 "EXP 13,147,288 / 2" 로만 보였다. 숫자를 축약하면
/// 들어가긴 하지만 실제 값을 확인하려고 띄우는 문구라 줄이면 의미가 없다.
/// 창을 따로 두면 펫 창 크기와 무관하게 온전히 보인다.
///
/// `ignoresMouseEvents` 라 펫의 호버 판정을 가로채지 않는다 — 이 창이 마우스를
/// 먹으면 펫에서 커서가 벗어난 것으로 처리돼 문구가 깜빡인다.
final class XPDetailWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    /// 문구와 창 가장자리 사이 여백.
    private static let padding = NSSize(width: 6, height: 3)
    /// 펫 창 아래 경계에서 얼마나 띄울지.
    private static let gap: CGFloat = 2

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
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

        // 숫자 폭이 고정돼야 값이 바뀔 때 글자가 덜 흔들린다.
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.alignment = .center
        // 배경이 밝든 어둡든 읽히도록 검은 그림자를 깔았다.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        label.shadow = shadow

        let container = NSView()
        container.addSubview(label)
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `petFrame`(화면 좌표) 바로 아래 가운데에 문구를 띄운다.
    func show(text: String, below petFrame: NSRect) {
        guard !text.isEmpty else { hide(); return }
        label.stringValue = text
        let textSize = label.intrinsicContentSize
        let size = NSSize(width: textSize.width + Self.padding.width * 2,
                          height: textSize.height + Self.padding.height * 2)

        var origin = NSPoint(x: petFrame.midX - size.width / 2, y: petFrame.minY - size.height - Self.gap)
        // 펫이 화면 끝이나 바닥에 붙어 있어도 문구는 화면 안에 남게 한다.
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 2), visible.maxX - size.width - 2)
            if origin.y < visible.minY + 2 { origin.y = petFrame.maxY + Self.gap }
        }

        setFrame(NSRect(origin: origin, size: size), display: true)
        contentView?.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(x: Self.padding.width, y: Self.padding.height,
                             width: textSize.width, height: textSize.height)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}
