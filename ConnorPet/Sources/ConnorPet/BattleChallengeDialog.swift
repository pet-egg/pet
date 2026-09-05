import AppKit

/// Game-styled modal used for battle challenges (and simple battle info popups),
/// replacing `NSAlert`. Because this is an accessory app with no app icon,
/// NSAlert renders a generic folder/document icon at the top — which looks wrong
/// for a battle prompt. This draws a dark rounded card topped by a bold "BATTLE"
/// banner instead, in the spirit of the Digimon battle screen, with a green
/// Accept button. Shown modally; returns the user's choice synchronously.
enum BattleDialog {
    /// 신청받은 쪽이 "Challenge" 말풍선을 눌렀을 때 뜨는 수락/거절 모달의 결과.
    /// `timedOut` 은 `timeout` 안에 아무 버튼도 안 눌러 스스로 닫힌 경우 — 무응답이라
    /// 신청자에게 거절을 보내지 않고, 신청자 쪽 카운트다운이 "응답하지 않음"으로
    /// 마무리하게 둔다.
    enum ChallengeChoice { case accept, decline, timedOut }

    /// Incoming-challenge accept/decline. `timeout` 을 주면 그 시간 뒤 스스로 닫히며
    /// `.timedOut` 을 돌려준다(무응답).
    static func challenge(fromName: String, timeout: TimeInterval? = nil) -> ChallengeChoice {
        let controller = DialogController(
            showsBanner: true,
            title: "대전 신청",
            message: "\(fromName)님이 대전을\n신청했어요. 수락할까요?",
            buttons: [.init(title: "거절", kind: .secondary), .init(title: "수락", kind: .primary)]
        )
        switch controller.runModal(autoDismissAfter: timeout) {
        case 1: return .accept
        case DialogController.timeoutCode: return .timedOut
        default: return .decline
        }
    }

    /// 되돌릴 수 없는 동작을 확인받는다. 기본 버튼이 취소라, 실수로 Return 을
    /// 눌러도 진행되지 않는다.
    static func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        let controller = DialogController(
            showsBanner: false,
            title: title,
            message: message,
            buttons: [.init(title: confirmTitle, kind: .secondary), .init(title: "취소", kind: .primary)]
        )
        return controller.runModal() == 0
    }

    /// One-button info popup (e.g. declined / failed), same look, no banner.
    static func info(title: String, message: String) {
        let controller = DialogController(
            showsBanner: false,
            title: title,
            message: message,
            buttons: [.init(title: "확인", kind: .primary)]
        )
        _ = controller.runModal()
    }
}

/// A borderless panel must opt in to becoming key, or its buttons' keyboard
/// shortcuts (Return = Accept, Esc = Decline) won't fire during the modal loop.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the panel + content and drives the modal loop, returning the index of
/// the button the user pressed.
final class DialogController: NSObject {
    struct Button {
        enum Kind { case primary, secondary }
        let title: String
        let kind: Kind
    }

    /// `runModal` 이 시간 초과로 스스로 닫힐 때 돌려주는 값. 실제 버튼 tag(0,1…)과
    /// 절대 겹치지 않게 큰 음수를 쓴다.
    static let timeoutCode = -777

    private let showsBanner: Bool
    private let title: String
    private let message: String
    private let buttons: [Button]
    private var panel: NSPanel?
    private var autoDismissTimer: Timer?

    init(showsBanner: Bool, title: String, message: String, buttons: [Button]) {
        self.showsBanner = showsBanner
        self.title = title
        self.message = message
        self.buttons = buttons
    }

    func runModal(autoDismissAfter: TimeInterval? = nil) -> Int {
        let width: CGFloat = 380
        let height: CGFloat = showsBanner ? 324 : 208
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.isMovableByWindowBackground = true

        let content = DialogContentView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            showsBanner: showsBanner, title: title, message: message
        )

        // Lay out the buttons along the bottom.
        let pad: CGFloat = 22, gap: CGFloat = 12, btnH: CGFloat = 46
        let count = CGFloat(buttons.count)
        let btnW = (width - pad * 2 - gap * (count - 1)) / count
        for (i, spec) in buttons.enumerated() {
            let x = pad + (btnW + gap) * CGFloat(i)
            let button = PillButton(
                title: spec.title, kind: spec.kind,
                frame: NSRect(x: x, y: 22, width: btnW, height: btnH)
            )
            button.tag = i
            button.target = self
            button.action = #selector(buttonPressed(_:))
            // Enter triggers the primary button; Esc the secondary (if any).
            if spec.kind == .primary { button.keyEquivalent = "\r" }
            else if buttons.count > 1 { button.keyEquivalent = "\u{1b}" }
            content.addSubview(button)
        }

        panel.contentView = content
        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // 시간 안에 아무 버튼도 안 누르면 스스로 닫는다. 모달 실행 중에는 런루프가
        // .modalPanel 모드로 도므로, 그 모드에 타이머를 넣어야 실제로 발화한다
        // (기본 .default 모드 타이머는 모달 중 안 뜬다).
        if let secs = autoDismissAfter {
            let t = Timer(timeInterval: secs, repeats: false) { [weak self] _ in
                self?.autoDismissTimer = nil
                NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: Self.timeoutCode))
            }
            RunLoop.main.add(t, forMode: .modalPanel)
            autoDismissTimer = t
        }

        let response = NSApp.runModal(for: panel)
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        panel.orderOut(nil)
        self.panel = nil
        return response.rawValue
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
    }
}

/// A layer-backed rounded "pill" button — the green Accept / gray Decline look.
final class PillButton: NSButton {
    private let kind: DialogController.Button.Kind

    init(title: String, kind: DialogController.Button.Kind, frame: NSRect) {
        self.kind = kind
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = backgroundColor(hover: false)
        contentTintColor = .white
        let color: NSColor = .white
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: color
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func backgroundColor(hover: Bool) -> CGColor {
        switch kind {
        case .primary:
            return (hover ? NSColor.systemGreen.blended(withFraction: 0.12, of: .white) ?? .systemGreen
                          : NSColor.systemGreen).cgColor
        case .secondary:
            return NSColor(calibratedWhite: hover ? 0.34 : 0.28, alpha: 1).cgColor
        }
    }

    // Subtle hover feedback.
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = backgroundColor(hover: true) }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = backgroundColor(hover: false) }
}

/// Draws the dark rounded card, the "BATTLE" banner, the title and the message.
final class DialogContentView: NSView {
    private let showsBanner: Bool
    private let titleText: String
    private let messageText: String

    init(frame: NSRect, showsBanner: Bool, title: String, message: String) {
        self.showsBanner = showsBanner
        self.titleText = title
        self.messageText = message
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Dark rounded card.
        let card = NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        card.fill()
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        card.lineWidth = 1
        card.stroke()

        let w = bounds.width
        var y = bounds.height

        if showsBanner {
            y -= 84
            drawBattleBanner(in: NSRect(x: (w - 220) / 2, y: y, width: 220, height: 60))
            y -= 24
        } else {
            y -= 40
        }

        // Title.
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: centered()
        ]
        let tRect = NSRect(x: 20, y: y - 30, width: w - 40, height: 28)
        (titleText as NSString).draw(in: tRect, withAttributes: titleAttrs)
        y -= 40

        // Message.
        let msgAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1),
            .paragraphStyle: centered(lineSpacing: 3)
        ]
        let mRect = NSRect(x: 24, y: 80, width: w - 48, height: y - 80)
        (messageText as NSString).draw(in: mRect, withAttributes: msgAttrs)
    }

    /// The "BATTLE" banner that replaces NSAlert's folder icon: a warm gradient
    /// pill with bold white lettering and a soft glow.
    private func drawBattleBanner(in rect: NSRect) {
        let pill = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)

        // Glow behind the pill.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.systemOrange.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.systemOrange.setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Gradient body.
        NSGraphicsContext.saveGraphicsState()
        pill.addClip()
        let grad = NSGradient(colors: [
            NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.20, alpha: 1),
            NSColor(calibratedRed: 0.95, green: 0.28, blue: 0.16, alpha: 1)
        ])
        grad?.draw(in: rect, angle: -90)
        // Top sheen.
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        // "BATTLE" lettering — bold, slightly tracked, dark stroke for punch.
        let text = "BATTLE" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .heavy),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor(calibratedRed: 0.5, green: 0.1, blue: 0.05, alpha: 1),
            .strokeWidth: -3.0,
            .kern: 2.0
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    private func centered(lineSpacing: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineSpacing = lineSpacing
        return p
    }
}
