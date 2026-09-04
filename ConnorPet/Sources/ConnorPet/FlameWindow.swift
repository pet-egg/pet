import AppKit

/// The fire-breath jet, drawn in its own window instead of inside the pet's
/// spritesheet.
///
/// Why a separate window: the flame has to be far bigger than the pet, and a
/// sprite row can only be as wide as one frame. Growing the frame to fit meant
/// growing every frame of every row — a 5x-longer flame worked out to a
/// 19200x16000 sheet and a 720pt pet window. Here the flame is one image
/// scaled at draw time, so its size costs nothing, and the window is
/// click-through so the extra area never blocks anything.
final class FlameWindow: NSPanel {
    private let imageView = NSImageView()
    private var timer: Timer?

    /// 화면에 찍히는 불길의 최대 길이 = 펫 창 너비 × 이 배수.
    /// 하나만 만지면 되도록 여기 모아 둔다.
    /// 화면에 찍히는 불길의 최대 길이 = 펫 창 너비 × 이 배수. 진화 단계마다 다르다.
    ///
    /// 창 너비가 이미 단계에 따라 커지므로 배수를 고정하면 길이도 따라 커지긴 한다.
    /// 하지만 그러면 **펫 대비 비율**이 단계와 무관하게 일정해서, 기본형에서도 자기
    /// 키의 5배가 넘는 불길이 나갔다. 어린 개체는 덜 뿜는 편이 자연스럽다.
    ///
    /// 최종 단계 값(3.75 → 675pt)은 그대로 두고 아래 단계만 줄였다.
    static func lengthMultiplier(forStage stage: Int) -> CGFloat {
        switch stage {
        case 0:  return 2.0
        case 1:  return 2.7
        default: return 3.75
        }
    }

    init(image: NSImage) {
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
        // 순수 장식이다. 절대 클릭을 먹으면 안 된다.
        ignoresMouseEvents = true
        hidesOnDeactivate = false

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = false
        contentView = imageView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 불길을 그린다.
    /// - Parameters:
    ///   - mouth: 화면 좌표로 환산한 입 위치. 불길의 오른쪽 끝(좁은 쪽)이 여기 붙는다.
    ///   - length: 불길의 가로 길이(pt). 0 이하이면 감춘다.
    ///   - aspect: 원본 이미지의 가로/세로 비.
    func show(mouth: CGPoint, length: CGFloat, aspect: CGFloat) {
        guard length > 1 else { hide(); return }
        let height = length / aspect
        let frame = NSRect(x: mouth.x - length, y: mouth.y - height / 2, width: length, height: height)
        setFrame(frame, display: true)
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        orderFrontRegardless()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
    }
}
