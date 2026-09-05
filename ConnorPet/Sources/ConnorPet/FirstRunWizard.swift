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
    struct SourceOption { let id: String; let name: String; let icon: NSImage? }
    struct Result { let petSlug: String?; let sourceID: String? }

    static func run(pets: [PetOption], sources: [SourceOption]) -> Result {
        // Held in a local so the controller (buttons' weak target) stays alive
        // for the whole modal loop.
        let controller = FirstRunWizardController(pets: pets, sources: sources)
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
    private let pets: [FirstRunWizard.PetOption]
    private let sources: [FirstRunWizard.SourceOption]
    private var panel: NSPanel?
    private var chosenPet: String?
    private var chosenSource: String?

    // Grid geometry for the pet page.
    private let cols = 4
    private let cell = NSSize(width: 96, height: 100)
    private let pad: CGFloat = 24
    private let titleH: CGFloat = 34

    init(pets: [FirstRunWizard.PetOption], sources: [FirstRunWizard.SourceOption]) {
        self.pets = pets
        self.sources = sources
    }

    func runModal() -> FirstRunWizard.Result {
        let rows = Int(ceil(Double(pets.count) / Double(cols)))
        let width = pad * 2 + cell.width * CGFloat(cols)
        let height = pad + titleH + CGFloat(rows) * cell.height + pad

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

        let rows = Int(ceil(Double(pets.count) / Double(cols)))
        let gridTop = size.height - pad - titleH
        for (i, pet) in pets.enumerated() {
            let col = i % cols, row = i / cols
            let x = pad + CGFloat(col) * cell.width
            // Fill top-to-bottom: row 0 is the topmost.
            let y = gridTop - CGFloat(row + 1) * cell.height
            let button = WizardButton(frame: NSRect(x: x, y: y, width: cell.width, height: cell.height))
            button.configureCell(image: pet.image, title: pet.name)
            button.tag = i
            button.target = self
            button.action = #selector(petPicked(_:))
            card.addSubview(button)
        }
        _ = rows
        installEscDismiss(on: card)
        panel?.contentView = card
        panel?.makeFirstResponder(card)
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
