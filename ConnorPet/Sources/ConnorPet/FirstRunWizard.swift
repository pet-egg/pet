import AppKit

/// First-launch wizard, shown exactly once — on first install, not on relaunch
/// (see `AppDelegate.didCompleteFirstRun`). Two steps:
///
///   1. **펫 고르기** — a grid of pet thumbnails (image + name).
///   2. **사용하는 앱 고르기** — which app's status drives the pet
///      (Claude Code / Claude Desktop / Orca).
///
/// Drawn as a borderless dark card like `BattleDialog`: this is an accessory app
/// with no Dock icon, so `NSAlert` would render a generic folder icon at the top.
/// Runs modally and returns the user's picks synchronously; a field is `nil` if
/// the user dismissed (Esc) before choosing, in which case the caller keeps its
/// default.
enum FirstRunWizard {
    struct PetOption { let slug: String; let name: String; let image: NSImage? }
    /// 펫 대분류 한 묶음(포켓몬/동물/메이플스토리). 마법사 1단계가 이 그룹별로
    /// 헤더 + 썸네일 그리드를 그린다. 아직 펫이 없는 그룹은 "준비 중"으로 나온다.
    struct PetGroup { let category: String; let pets: [PetOption] }
    struct SourceOption { let id: String; let name: String; let icon: NSImage? }
    struct Result { let petSlug: String?; let sourceID: String? }

    static func run(petGroups: [PetGroup], sources: [SourceOption]) -> Result {
        // Held in a local so the controller (buttons' weak target) stays alive
        // for the whole modal loop.
        let controller = FirstRunWizardController(petGroups: petGroups, sources: sources)
        return controller.runModal()
    }
}

/// A borderless panel must opt in to becoming key, or its buttons' keyboard
/// shortcuts (Esc = dismiss) won't fire during the modal loop.
private final class WizardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class FirstRunWizardController: NSObject {
    private let petGroups: [FirstRunWizard.PetGroup]
    private let pets: [FirstRunWizard.PetOption]   // 평탄화(버튼 tag → 펫 조회용)
    private let sources: [FirstRunWizard.SourceOption]
    private var panel: NSPanel?
    private var chosenPet: String?
    private var chosenSource: String?

    // Grid geometry for the pet page.
    private let cols = 4
    private let cell = NSSize(width: 96, height: 100)
    private let pad: CGFloat = 24
    private let titleH: CGFloat = 34
    // 대분류 그룹 레이아웃.
    private let headerH: CGFloat = 20      // 그룹 헤더("포켓몬" 등) 높이
    private let headerGap: CGFloat = 6     // 헤더 → 그리드 간격
    private let groupGap: CGFloat = 16     // 그룹 사이 간격
    private let emptyRowH: CGFloat = 40    // 빈 그룹("준비 중") 높이

    init(petGroups: [FirstRunWizard.PetGroup], sources: [FirstRunWizard.SourceOption]) {
        self.petGroups = petGroups
        self.pets = petGroups.flatMap { $0.pets }
        self.sources = sources
    }

    /// 그룹(헤더 + 그리드/빈 표시)을 모두 쌓았을 때 필요한 펫 페이지 크기.
    private func petPageSize() -> NSSize {
        let width = pad * 2 + cell.width * CGFloat(cols)
        var content: CGFloat = 0
        for g in petGroups {
            let gridH: CGFloat
            if g.pets.isEmpty {
                gridH = emptyRowH
            } else {
                let rows = Int(ceil(Double(g.pets.count) / Double(cols)))
                gridH = CGFloat(rows) * cell.height
            }
            content += headerH + headerGap + gridH + groupGap
        }
        let height = pad + titleH + content + pad
        return NSSize(width: width, height: height)
    }

    func runModal() -> FirstRunWizard.Result {
        let size = petPageSize()
        let width = size.width
        let height = size.height

        let panel = WizardPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.isMovableByWindowBackground = true
        self.panel = panel

        showPetPage(size: NSSize(width: width, height: height))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        self.panel = nil
        return FirstRunWizard.Result(petSlug: chosenPet, sourceID: chosenSource)
    }

    // MARK: - Pages

    private func showPetPage(size: NSSize) {
        let card = CardView(frame: NSRect(origin: .zero, size: size))
        card.addSubview(makeTitle("펫을 골라주세요", size: size))
        card.addSubview(makeStep("1 / 2", size: size))

        // 대분류(포켓몬/동물/메이플스토리)별로 헤더 + 썸네일 그리드를 위에서 아래로
        // 쌓는다. 버튼 tag 는 평탄화한 pets 순서와 맞도록 그룹 순회하며 증가시킨다.
        var y = size.height - pad - titleH   // 내용 영역 상단
        var tag = 0
        for group in petGroups {
            card.addSubview(makeGroupHeader(group.category, top: y, width: size.width))
            y -= headerH + headerGap

            if group.pets.isEmpty {
                card.addSubview(makeEmptyNote("준비 중", top: y, width: size.width))
                y -= emptyRowH + groupGap
                continue
            }

            let rows = Int(ceil(Double(group.pets.count) / Double(cols)))
            for (i, pet) in group.pets.enumerated() {
                let col = i % cols, row = i / cols
                let x = pad + CGFloat(col) * cell.width
                let by = y - CGFloat(row + 1) * cell.height
                let button = WizardButton(frame: NSRect(x: x, y: by, width: cell.width, height: cell.height))
                button.configureCell(image: pet.image, title: pet.name)
                button.tag = tag
                tag += 1
                button.target = self
                button.action = #selector(petPicked(_:))
                card.addSubview(button)
            }
            y -= CGFloat(rows) * cell.height + groupGap
        }

        installEscDismiss(on: card)
        panel?.contentView = card
        panel?.makeFirstResponder(card)
    }

    /// 왼쪽 정렬한 대분류 헤더 라벨(어두운 카드 위 흐린 회색).
    private func makeGroupHeader(_ text: String, top: CGFloat, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        label.frame = NSRect(x: pad + 2, y: top - headerH, width: width - pad * 2, height: headerH)
        return label
    }

    /// 아직 펫이 없는 그룹 표시("준비 중").
    private func makeEmptyNote(_ text: String, top: CGFloat, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        label.frame = NSRect(x: pad + 4, y: top - emptyRowH + 10, width: width - pad * 2, height: 20)
        return label
    }

    private func showSourcePage() {
        guard let panel else { return }
        let width: CGFloat = 380
        let rowH: CGFloat = 54, gap: CGFloat = 12
        let height = pad + titleH + CGFloat(sources.count) * (rowH + gap) + pad
        // Resize the panel around the (smaller) source page, keeping it centered.
        let old = panel.frame
        let newFrame = NSRect(
            x: old.midX - width / 2, y: old.midY - height / 2,
            width: width, height: height
        )
        panel.setFrame(newFrame, display: true, animate: true)

        let size = NSSize(width: width, height: height)
        let card = CardView(frame: NSRect(origin: .zero, size: size))
        card.addSubview(makeTitle("어떤 앱의 상태를 볼까요?", size: size))
        card.addSubview(makeStep("2 / 2", size: size))

        var y = size.height - pad - titleH - rowH
        for (i, source) in sources.enumerated() {
            let button = WizardButton(frame: NSRect(x: pad, y: y, width: width - pad * 2, height: rowH))
            button.configureRow(title: source.name, icon: source.icon)
            button.tag = i
            button.target = self
            button.action = #selector(sourcePicked(_:))
            card.addSubview(button)
            y -= rowH + gap
        }
        installEscDismiss(on: card)
        panel.contentView = card
        panel.makeFirstResponder(card)
    }

    // MARK: - Actions

    @objc private func petPicked(_ sender: NSButton) {
        chosenPet = pets[sender.tag].slug
        showSourcePage()
    }

    @objc private func sourcePicked(_ sender: NSButton) {
        chosenSource = sources[sender.tag].id
        NSApp.stopModal()
    }

    /// Esc dismisses the whole wizard (caller falls back to defaults for anything
    /// not yet chosen). Wired via a hidden zero-size button with the Esc key.
    private func installEscDismiss(on card: NSView) {
        let esc = NSButton(frame: .zero)
        esc.title = ""
        esc.isTransparent = true
        esc.keyEquivalent = "\u{1b}"
        esc.target = self
        esc.action = #selector(dismiss)
        card.addSubview(esc)
    }

    @objc private func dismiss() { NSApp.stopModal() }

    // MARK: - Shared bits

    private func makeTitle(_ text: String, size: NSSize) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 19, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 20, y: size.height - pad - 26, width: size.width - 40, height: 28)
        return label
    }

    private func makeStep(_ text: String, size: NSSize) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        label.alignment = .center
        label.frame = NSRect(x: 20, y: size.height - 20, width: size.width - 40, height: 14)
        return label
    }
}

/// The dark rounded card behind a wizard page.
private final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        card.fill()
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        card.lineWidth = 1
        card.stroke()
    }
}

/// A layer-backed button used for both the pet cells (image above name) and the
/// source rows (title only), with subtle grayscale hover feedback that matches
/// the settings window's neutral look.
private final class WizardButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = bg(hover: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configureCell(image: NSImage?, title: String) {
        if let image { self.image = Self.thumbnail(image) }
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyDown
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
        ])
    }

    /// A source row: a white rounded tile holding the app's glyph, then the name.
    /// Left-aligned. The image view + label are children of this button; hits are
    /// routed to the button via `hitTest`, so the whole pill stays clickable.
    func configureRow(title: String, icon: NSImage?) {
        attributedTitle = NSAttributedString(string: "")
        setAccessibilityLabel(title)   // name lives in a child label, so set it here
        let tile: CGFloat = 38, inset: CGFloat = 16, gap: CGFloat = 14
        let iv = NSImageView(frame: NSRect(x: inset, y: (bounds.height - tile) / 2, width: tile, height: tile))
        iv.image = Self.composeTile(icon)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.minYMargin, .maxYMargin]
        addSubview(iv)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBordered = false
        let lx = inset + tile + gap
        label.frame = NSRect(x: lx, y: (bounds.height - 22) / 2, width: bounds.width - lx - inset, height: 22)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(label)
    }

    /// Draws the app glyph centered on a near-white rounded tile — a consistent
    /// backing so glyphs of any color (orange marks, a black/white orca) read on
    /// the dark row. Matches the design artifact.
    private static func composeTile(_ glyph: NSImage?, side: CGFloat = 38, pad: CGFloat = 6) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        if let glyph {
            let inner = rect.insetBy(dx: pad, dy: pad)
            let s = glyph.size
            let scale = s.width > 0 && s.height > 0 ? min(inner.width / s.width, inner.height / s.height) : 1
            let w = s.width * scale, h = s.height * scale
            glyph.draw(in: NSRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
        img.unlockFocus()
        return img
    }

    // The source rows add child views (tile + label); route every hit inside the
    // pill to the button itself so those children never swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Pre-scale a sprite frame to a crisp ~60px thumbnail.
    private static func thumbnail(_ image: NSImage, side: CGFloat = 60) -> NSImage {
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    private func bg(hover: Bool) -> CGColor {
        NSColor(calibratedWhite: hover ? 0.30 : 0.20, alpha: 1).cgColor
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = bg(hover: true) }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = bg(hover: false) }
}
