import AppKit
import QuartzCore

/// A small floating "screen" that hosts a battle — like the Digimon device's
/// LCD. Only one pet is on screen at a time; when a shot flies off the edge the
/// view cuts to the other pet. Centered, rounded, floats over the desktop, and
/// auto-closes a few seconds after the WIN/LOSE banner. It's a `.nonactivatingPanel`
/// so it never steals focus or switches Spaces.
final class BattleWindow: NSPanel {
    private var onClosed: (() -> Void)?

    init(view: BattleView, onClosed: @escaping () -> Void) {
        self.onClosed = onClosed
        let size = BattleView.screenSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        view.frame = NSRect(origin: .zero, size: size)
        contentView = view
        center()

        view.onFinished = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self?.close() }
        }
    }

    // Non-activating: receives clicks (to dismiss) without pulling focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() { center(); orderFrontRegardless() }

    override func close() {
        (contentView as? BattleView)?.stop()
        onClosed?()
        onClosed = nil
        super.close()
    }
}

/// Renders a 1:1 battle as a single-pet, camera-cutting sequence in the spirit
/// of the Digimon device: the attacker fills the little screen and fires, the
/// shot flies off the edge, the screen cuts to the defender, and the shot flies
/// back in to land or be dodged. HP for both pets sits along the top so the
/// score stays legible even though only one pet shows at a time.
///
/// Every round has two scenes with a flash-cut between them. Which sprite fills
/// each scene depends on who's attacking, so *both* pets take their turns on
/// screen. The whole thing is a deterministic function of `elapsed`, so it stays
/// reproducible from the shared seed.
final class BattleView: NSView {
    static let screenSize = NSSize(width: 460, height: 340)

    private let mySheet: SpriteSheet
    private let oppSheet: SpriteSheet
    private let myName: String
    private let oppName: String
    private let myRole: BattleRole
    private let outcome: BattleOutcome

    private let hpTimeline: [(challenger: Int, accepter: Int)]

    private var timer: Timer?
    private var startTime: TimeInterval = 0
    private var finished = false
    var onFinished: (() -> Void)?

    // Clean battle stance (the shared idle bakes in a sleep/Zzz overlay).
    private let myPose: SpriteAnimationFrames?
    private let oppPose: SpriteAnimationFrames?

    private var fireEmitter: CAEmitterLayer?

    // Timing (seconds). Each round holds two scenes (fire + impact), so it's long.
    private let introDuration: TimeInterval = 1.2
    private let roundDuration: TimeInterval = 2.0

    // Per-round phase boundaries, as fractions of a round:
    private let windupEnd = 0.12    // attacker wind-up before the shot leaves
    private let fireExit = 0.44     // shot has flown off the attacker's screen edge
    private let cutAt = 0.50        // flash-cut midpoint (attacker → defender)
    private let impactEnter = 0.52  // shot re-enters on the defender's screen
    private let hitAt = 0.80        // a landing shot reaches the defender
    private let dodgeExit = 0.95    // a dodged shot leaves the far edge

    init(mySheet: SpriteSheet, oppSheet: SpriteSheet, myName: String, oppName: String, myRole: BattleRole, outcome: BattleOutcome) {
        self.mySheet = mySheet
        self.oppSheet = oppSheet
        self.myName = myName
        self.oppName = oppName
        self.myRole = myRole
        self.outcome = outcome
        self.myPose = mySheet.animation(named: "running") ?? mySheet.resolvedAnimation(for: .running)
        self.oppPose = oppSheet.animation(named: "running") ?? oppSheet.resolvedAnimation(for: .running)

        var timeline: [(challenger: Int, accepter: Int)] = [(outcome.startHP, outcome.startHP)]
        var ch = outcome.startHP, ac = outcome.startHP
        for round in outcome.rounds {
            if round.attacker == .challenger { ac = max(0, ac - round.damage) }
            else { ch = max(0, ch - round.damage) }
            timeline.append((ch, ac))
        }
        self.hpTimeline = timeline

        super.init(frame: NSRect(origin: .zero, size: Self.screenSize))
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true // rounds the screen and clips the flame at its edges
        setUpEmitter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Flame emitter

    private static func makeGlowImage(diameter: Int = 64) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: diameter, height: diameter,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                      CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        guard let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { return nil }
        let c = CGPoint(x: diameter / 2, y: diameter / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(diameter) / 2, options: [])
        return ctx.makeImage()
    }

    private func setUpEmitter() {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .point
        emitter.emitterSize = CGSize(width: 5, height: 5)
        emitter.renderMode = .additive

        let fire = CAEmitterCell()
        fire.name = "fire"
        fire.contents = Self.makeGlowImage()
        fire.birthRate = 0
        fire.lifetime = 0.5
        fire.lifetimeRange = 0.15
        fire.velocity = 20
        fire.velocityRange = 16
        fire.emissionRange = .pi * 2
        fire.scale = 0.55
        fire.scaleRange = 0.25
        fire.scaleSpeed = -0.9
        fire.alphaSpeed = -1.9
        fire.color = CGColor(red: 1, green: 0.55, blue: 0.16, alpha: 1)
        fire.greenSpeed = -0.5
        fire.blueSpeed = -0.4
        emitter.emitterCells = [fire]

        layer?.addSublayer(emitter)
        fireEmitter = emitter
    }

    private func updateEmitter(active: Bool, at point: CGPoint) {
        guard let emitter = fireEmitter else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.emitterPosition = point
        emitter.setValue(active ? 220.0 : 0.0, forKeyPath: "emitterCells.fire.birthRate")
        CATransaction.commit()
    }

    // MARK: - Lifecycle

    func start() {
        startTime = Date().timeIntervalSinceReferenceDate
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        updateEmitter(active: false, at: .zero)
    }

    override func mouseDown(with event: NSEvent) { window?.close() }

    private var elapsed: TimeInterval { Date().timeIntervalSinceReferenceDate - startTime }
    private var battleEnd: TimeInterval { introDuration + Double(outcome.rounds.count) * roundDuration }

    private var burstIndex = 0
    private var nextBurstAt: TimeInterval = 0

    private func tick() {
        if !finished && elapsed >= battleEnd {
            finished = true
            updateEmitter(active: false, at: .zero)
            onFinished?()
        }
        needsDisplay = true
        maybeCaptureSnapshot()
    }

    // Test hook: dump a burst of frames (`<stem>_NN.png`) via cacheDisplay, which
    // renders only this instance's own screen — for headless verification.
    private func maybeCaptureSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["CONNORPET_BATTLE_SNAPSHOT"],
              elapsed >= nextBurstAt, burstIndex <= 40 else { return }
        nextBurstAt = elapsed + 0.25
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let outURL = dir.appendingPathComponent(String(format: "%@_%02d.%@", stem, burstIndex, ext))
        burstIndex += 1
        display()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: outURL)
        }
    }

    // MARK: - Layout
    //
    // My pet lives at the LEFT edge and shoots right; the opponent lives at the
    // RIGHT edge and shoots left. So the pet firing right sits at the left edge,
    // the pet firing left sits at the right edge — and every shot has the full
    // width of the little screen to cross.

    private var petSize: CGFloat { min(bounds.height, bounds.width) * 0.46 }
    private var baseY: CGFloat { bounds.midY - 12 }
    private var leftPetCenter: CGPoint { CGPoint(x: petSize * 0.5 + 8, y: baseY) }
    private var rightPetCenter: CGPoint { CGPoint(x: bounds.width - petSize * 0.5 - 8, y: baseY) }
    private var projectileY: CGFloat { baseY + petSize * 0.02 }
    private var leftEdge: CGFloat { -30 }
    private var rightEdge: CGFloat { bounds.width + 30 }

    /// Where a role's pet stands and which way it faces.
    private func home(for role: BattleRole) -> (center: CGPoint, facingRight: Bool) {
        role == myRole ? (leftPetCenter, true) : (rightPetCenter, false)
    }
    private func pose(for role: BattleRole) -> SpriteAnimationFrames? {
        role == myRole ? myPose : oppPose
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        drawScreenBackground()
        let t = elapsed

        if t < introDuration {
            drawPose(myPose, facingRight: true, at: leftPetCenter, flash: false)
            drawTopHUD(myHP: outcome.startHP, oppHP: outcome.startHP)
            drawCenterBanner("VS", color: .white)
            drawBorder()
            updateEmitter(active: false, at: .zero)
            return
        }

        let roundsElapsed = t - introDuration
        let roundIndex = min(outcome.rounds.count, Int(roundsElapsed / roundDuration))
        guard roundIndex < outcome.rounds.count else {
            // Battle over: hold on the last scene under the banner.
            drawFinalFrame()
            drawBorder()
            updateEmitter(active: false, at: .zero)
            return
        }
        let f = (roundsElapsed - Double(roundIndex) * roundDuration) / roundDuration
        let round = outcome.rounds[roundIndex]
        let attacker = round.attacker
        let defender = attacker.opponent

        // HP to show (snap once a landing shot connects).
        let connected = !round.missed && f >= hitAt
        let hp = hpTimeline[min(connected ? roundIndex + 1 : roundIndex, hpTimeline.count - 1)]
        let myHP = myRole == .challenger ? hp.challenger : hp.accepter
        let oppHP = myRole == .challenger ? hp.accepter : hp.challenger

        if f < cutAt {
            drawFireScene(attacker: attacker, f: f)
        } else {
            drawImpactScene(attacker: attacker, defender: defender, f: f, dodged: round.missed)
        }

        drawTopHUD(myHP: myHP, oppHP: oppHP)

        // Flash-cut between the two scenes.
        let cutHalf = 0.06
        if abs(f - cutAt) < cutHalf {
            let a = (1 - abs(f - cutAt) / cutHalf) * 0.9
            NSColor(white: 1, alpha: CGFloat(a)).setFill()
            NSBezierPath(rect: bounds).fill()
        }

        drawBorder()
    }

    /// Scene 1 — the attacker sits at its edge, winds up, and fires a shot that
    /// crosses the whole screen and off the far edge.
    private func drawFireScene(attacker: BattleRole, f: Double) {
        let (base, facingRight) = home(for: attacker)
        let dir: CGFloat = facingRight ? 1 : -1
        let lunge = lungeAmount(f) * (petSize * 0.12) * dir
        // Ease slightly inward as the camera starts to chase the shot.
        let chase = f > fireExit - 0.06 ? CGFloat((f - (fireExit - 0.06)) / 0.06) * (bounds.width * 0.10) * dir : 0
        let center = CGPoint(x: base.x + lunge + chase, y: base.y)
        drawPose(pose(for: attacker), facingRight: facingRight, at: center, flash: false)

        if f >= windupEnd {
            let muzzle = base.x + dir * petSize * 0.5
            let exitX = facingRight ? rightEdge : leftEdge
            let p = (f - windupEnd) / (fireExit - windupEnd)
            let x = muzzle + (exitX - muzzle) * CGFloat(min(p, 1))
            if f < fireExit { drawShot(at: CGPoint(x: x, y: projectileY)) } else { updateEmitter(active: false, at: .zero) }
        } else {
            updateEmitter(active: false, at: .zero)
        }
    }

    /// Scene 2 — cut to the defender at the *other* edge; the shot re-enters from
    /// the attacker's side and crosses to it. It lands (flash + HP drop) or the
    /// defender turns away and hops back, letting the shot sail off the far edge.
    private func drawImpactScene(attacker: BattleRole, defender: BattleRole, f: Double, dodged: Bool) {
        let shotGoesRight = home(for: attacker).facingRight
        let (base, facingRight) = home(for: defender)
        let hitDir: CGFloat = shotGoesRight ? 1 : -1
        let entryX = shotGoesRight ? leftEdge : rightEdge
        let farX = shotGoesRight ? rightEdge : leftEdge
        let defenderFront = base.x - hitDir * petSize * 0.5 // side toward the incoming shot

        let dodge = dodged ? dodgeAmount(f) : 0
        let hop = dodge * (petSize * 0.24) * hitDir          // hop away from the incoming shot
        let slideIn = f < impactEnter + 0.08 ? CGFloat((impactEnter + 0.08 - f) / 0.08) * (bounds.width * 0.12) * hitDir : 0
        let center = CGPoint(x: base.x + hop + slideIn, y: base.y + dodge * petSize * 0.06)
        let facing = dodge > 0.5 ? shotGoesRight : facingRight // dodge → face away (= shot direction)
        let flash = !dodged && f >= hitAt && f < hitAt + 0.12
        drawPose(pose(for: defender), facingRight: facing, at: center, flash: flash)

        guard f >= impactEnter else { updateEmitter(active: false, at: .zero); return }
        if dodged {
            let p = (f - impactEnter) / (dodgeExit - impactEnter)
            let x = entryX + (farX - entryX) * CGFloat(min(p, 1))
            if f < dodgeExit { drawShot(at: CGPoint(x: x, y: projectileY)) } else { updateEmitter(active: false, at: .zero) }
        } else {
            let p = (f - impactEnter) / (hitAt - impactEnter)
            let x = entryX + (defenderFront - entryX) * CGFloat(min(p, 1))
            if f < hitAt { drawShot(at: CGPoint(x: x, y: projectileY)) } else { updateEmitter(active: false, at: .zero) }
        }
    }

    private func drawFinalFrame() {
        // Show the winner's pet at its home edge, under the banner.
        let (base, facing) = home(for: outcome.winner)
        drawPose(pose(for: outcome.winner), facingRight: facing, at: base, flash: false)
        let hp = hpTimeline[hpTimeline.count - 1]
        drawTopHUD(myHP: myRole == .challenger ? hp.challenger : hp.accepter,
                   oppHP: myRole == .challenger ? hp.accepter : hp.challenger)
        drawCenterBanner(outcome.winner == myRole ? "WIN!" : "LOSE",
                         color: outcome.winner == myRole ? .systemYellow : .systemGray)
    }

    private func lungeAmount(_ f: Double) -> CGFloat {
        let hi = windupEnd + 0.18
        guard f >= 0, f <= hi else { return 0 }
        return CGFloat(sin(f / hi * .pi))
    }

    private func dodgeAmount(_ f: Double) -> CGFloat {
        let lo = hitAt - 0.14, hi = hitAt + 0.14
        guard f >= lo, f <= hi else { return 0 }
        return CGFloat(sin((f - lo) / (hi - lo) * .pi))
    }

    // MARK: - Primitives

    private func screenRect() -> NSRect { bounds }

    private func drawScreenBackground() {
        let top = NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.20, alpha: 1)
        let bottom = NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.09, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)
        // Ground line under the pets.
        let footY = baseY - petSize * 0.5
        let g = NSBezierPath()
        g.move(to: NSPoint(x: 0, y: footY)); g.line(to: NSPoint(x: bounds.width, y: footY))
        NSColor(white: 1, alpha: 0.10).setStroke(); g.lineWidth = 1.5; g.stroke()
    }

    private func drawBorder() {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 17, yRadius: 17)
        NSColor(white: 1, alpha: 0.14).setStroke(); p.lineWidth = 2; p.stroke()
    }

    private func drawPose(_ frames: SpriteAnimationFrames?, facingRight: Bool, at center: CGPoint, flash: Bool) {
        guard let frames, !frames.images.isEmpty else { return }
        let totalMs = frames.durationsMs.reduce(0, +)
        var index = 0
        if totalMs > 0 {
            var acc = (elapsed * 1000).truncatingRemainder(dividingBy: totalMs)
            for (i, d) in frames.durationsMs.enumerated() { if acc < d { index = i; break }; acc -= d }
        }
        let image = frames.images[min(index, frames.images.count - 1)]
        let rect = NSRect(x: center.x - petSize / 2, y: center.y - petSize / 2, width: petSize, height: petSize)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        // Sprites face right un-flipped; flip to face left.
        if !facingRight {
            ctx?.translateBy(x: rect.midX, y: 0); ctx?.scaleBy(x: -1, y: 1); ctx?.translateBy(x: -rect.midX, y: 0)
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        if flash {
            NSColor(calibratedRed: 1, green: 0.25, blue: 0.25, alpha: 0.6).set()
            image.draw(in: rect, from: .zero, operation: .sourceAtop, fraction: 0.6)
        }
        ctx?.restoreGState()
    }

    private func drawShot(at point: CGPoint) {
        updateEmitter(active: true, at: point)
        let core = NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        NSColor(calibratedRed: 1, green: 0.95, blue: 0.7, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: core).fill()
        let halo = NSRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30)
        NSColor(calibratedRed: 1, green: 0.55, blue: 0.15, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: halo).fill()
    }

    private func drawTopHUD(myHP: Int, oppHP: Int) {
        let barW: CGFloat = 150, barH: CGFloat = 12, pad: CGFloat = 16
        let topY = bounds.height - 34
        drawHP(name: myName, hp: myHP, maxHP: outcome.startHP,
               at: CGRect(x: pad, y: topY, width: barW, height: barH), rightAligned: false)
        drawHP(name: oppName, hp: oppHP, maxHP: outcome.startHP,
               at: CGRect(x: bounds.width - pad - barW, y: topY, width: barW, height: barH), rightAligned: true)
    }

    private func drawHP(name: String, hp: Int, maxHP: Int, at rect: CGRect, rightAligned: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white
        ]
        let s = name as NSString
        let sz = s.size(withAttributes: attrs)
        let maxNameW = rect.width
        let nameX = rightAligned ? rect.maxX - min(sz.width, maxNameW) : rect.minX
        s.draw(at: NSPoint(x: nameX, y: rect.maxY + 2), withAttributes: attrs)

        let bg = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor(white: 0, alpha: 0.4).setFill(); bg.fill()
        NSColor(white: 1, alpha: 0.18).setStroke(); bg.stroke()

        let frac = maxHP > 0 ? CGFloat(max(0, hp)) / CGFloat(maxHP) : 0
        let fillW = (rect.width - 2) * frac
        let fillRect = rightAligned
            ? CGRect(x: rect.maxX - 1 - fillW, y: rect.minY + 1, width: fillW, height: rect.height - 2)
            : CGRect(x: rect.minX + 1, y: rect.minY + 1, width: fillW, height: rect.height - 2)
        let color: NSColor = frac > 0.5 ? .systemGreen : (frac > 0.25 ? .systemYellow : .systemRed)
        if fillW > 0.5 { color.setFill(); NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill() }
    }

    private func drawCenterBanner(_ text: String, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 52, weight: .heavy),
            .foregroundColor: color, .strokeColor: NSColor.black, .strokeWidth: -3.5
        ]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2 + 18), withAttributes: attrs)
    }
}
