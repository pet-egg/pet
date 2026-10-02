import AppKit

/// 결혼식 축하용 빵빠레(색종이) 이펙트 창.
///
/// 불길(`FlameWindow`)과 같은 결 — 펫 스프라이트에 넣기엔 너무 커서 **별도의
/// 클릭-통과 투명 창**에 그린다. 화면 전체를 덮고 위에서 색종이가 쏟아지며,
/// 펫 주변에서 한 번 크게 터진다. `CAEmitterLayer`(additive 아님 — 색종이는
/// 불투명 조각이라 섞지 않는다)로 몇 초간 분사한 뒤 스스로 멈추고 사라진다.
final class ConfettiWindow: NSWindow {
    private let emitterView = ConfettiEmitterView()
    private var stopWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    /// 분사 지속 시간(초). 이후엔 새 조각을 안 만들고, 남은 조각이 떨어질
    /// 시간을 더 준 뒤 창을 닫는다.
    static let burstDuration: TimeInterval = 2.2
    /// 분사를 멈춘 뒤 남은 색종이가 바닥까지 떨어지도록 기다리는 시간(초).
    static let tailDuration: TimeInterval = 3.0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // 순수 장식이다. 절대 클릭을 먹으면 안 된다.
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        contentView = emitterView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 빵빠레를 터뜨린다. `petFrame` 주변에서 한 번 크게 터지고, 화면 위에서
    /// 색종이가 쏟아진다.
    func celebrate(around petFrame: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) }
            ?? NSScreen.main
        guard let screenFrame = screen?.frame else { return }

        setFrame(screenFrame, display: true)
        emitterView.frame = NSRect(origin: .zero, size: screenFrame.size)

        // 창 좌표(원점 0,0 은 창 왼쪽아래)로 환산한 펫 중심.
        let petCenter = CGPoint(
            x: petFrame.midX - screenFrame.minX,
            y: petFrame.midY - screenFrame.minY
        )
        emitterView.start(sceneSize: screenFrame.size, burstAt: petCenter)
        orderFrontRegardless()

        // 분사 멈춤 → 잠시 뒤 창 닫기. 겹쳐 부를 수 있으니 이전 예약은 취소한다.
        stopWork?.cancel()
        hideWork?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.emitterView.stop() }
        let hide = DispatchWorkItem { [weak self] in self?.hide() }
        stopWork = stop
        hideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstDuration, execute: stop)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstDuration + Self.tailDuration, execute: hide)
    }

    func hide() {
        stopWork?.cancel(); stopWork = nil
        hideWork?.cancel(); hideWork = nil
        emitterView.stop()
        orderOut(nil)
    }
}

/// 색종이를 뿜는 레이어를 든 뷰. 화면 위를 가로지르는 비(rain)와 펫 주변
/// 한 방(burst), 두 이미터를 함께 쓴다.
private final class ConfettiEmitterView: NSView {
    private var rain: CAEmitterLayer?
    private var burst: CAEmitterLayer?

    /// 색종이 색 팔레트 — 결혼식답게 금·분홍·흰·하늘·연두.
    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.25, alpha: 1), // gold
        NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.62, alpha: 1), // pink
        NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.00, alpha: 1), // white
        NSColor(calibratedRed: 0.42, green: 0.70, blue: 1.00, alpha: 1), // sky
        NSColor(calibratedRed: 0.55, green: 0.86, blue: 0.45, alpha: 1), // green
        NSColor(calibratedRed: 0.76, green: 0.55, blue: 1.00, alpha: 1), // violet
    ]

    override var isFlipped: Bool { false }

    override func makeBackingLayer() -> CALayer { CALayer() }

    func start(sceneSize: CGSize, burstAt point: CGPoint) {
        wantsLayer = true
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let cells = Self.palette.map(Self.makeCell)

        // 화면 꼭대기 전폭에서 쏟아지는 비.
        let rainLayer = CAEmitterLayer()
        rainLayer.emitterShape = .line
        rainLayer.emitterPosition = CGPoint(x: sceneSize.width / 2, y: sceneSize.height + 10)
        rainLayer.emitterSize = CGSize(width: sceneSize.width, height: 1)
        rainLayer.renderMode = .unordered
        rainLayer.birthRate = 1
        rainLayer.emitterCells = cells.map { cell in
            let c = cell.copy() as! CAEmitterCell
            c.birthRate = 14
            c.yAcceleration = -260 // 아래로(레이어 좌표는 위가 +)
            c.velocity = 60
            c.velocityRange = 40
            c.emissionLongitude = -.pi / 2
            c.emissionRange = .pi / 8
            return c
        }
        layer?.addSublayer(rainLayer)
        rain = rainLayer

        // 펫 주변에서 한 방 터지는 폭죽.
        let burstLayer = CAEmitterLayer()
        burstLayer.emitterShape = .point
        burstLayer.emitterPosition = point
        burstLayer.emitterSize = CGSize(width: 8, height: 8)
        burstLayer.renderMode = .unordered
        burstLayer.birthRate = 1
        burstLayer.emitterCells = cells.map { cell in
            let c = cell.copy() as! CAEmitterCell
            c.birthRate = 500
            c.lifetime = 2.4
            c.velocity = 320
            c.velocityRange = 160
            c.yAcceleration = -300
            c.emissionLongitude = .pi / 2
            c.emissionRange = .pi // 위쪽 반구로 분출
            return c
        }
        layer?.addSublayer(burstLayer)
        burst = burstLayer

        // 폭죽은 한 번만 터지면 되므로 아주 짧게 켰다 끈다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak burstLayer] in
            burstLayer?.birthRate = 0
        }
    }

    func stop() {
        rain?.birthRate = 0
        burst?.birthRate = 0
    }

    /// 색종이 한 조각의 템플릿 셀. 색만 바꿔 팔레트를 만든다.
    private static func makeCell(color: NSColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = makeConfettiImage(color: color)
        cell.birthRate = 0
        cell.lifetime = 5.0
        cell.lifetimeRange = 1.0
        cell.scale = 0.5
        cell.scaleRange = 0.3
        cell.spin = 4.0
        cell.spinRange = 6.0
        cell.alphaSpeed = -0.18
        return cell
    }

    /// 작은 색종이 조각(둥근 사각형) 비트맵.
    private static func makeConfettiImage(color: NSColor) -> CGImage? {
        let size = CGSize(width: 18, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        color.setFill()
        path.fill()
        image.unlockFocus()
        var proposed = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }
}
