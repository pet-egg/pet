import AppKit

/// 스프라이트에서 얼굴만 잘라 낸 초상. 노려보기 알림에 상대 펫을 띄울 때 쓴다.
///
/// 상대의 이미지를 주고받지 않는다 — 스프라이트는 두 앱 모두 번들에 갖고 있으므로,
/// 메시지에 실려 온 slug 로 **각자 자기 번들에서** 찾아 그리면 된다. 그림을 네트워크로
/// 옮기면 크기도 커지고 위조도 가능해진다.
enum PetPortrait {
    /// `slug` 펫의 idle 첫 프레임에서 얼굴을 잘라 낸다. 번들에 없는 펫(상대가 더
    /// 최신 버전이라 우리에게 없는 펫을 쓰는 경우)이면 nil 이다.
    static func face(of slug: String) -> NSImage? {
        guard let sheet = try? AppDelegate.loadSpriteSheet(slug: slug),
              let frames = sheet.resolvedAnimation(for: .idle) ?? sheet.animation(named: "idle"),
              let first = frames.images.first,
              let cg = first.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        guard let box = opaqueBounds(of: cg) else { return nil }

        // 프레임의 여백은 펫마다 크게 다르다(실측 채움 46%~83%). 알파 경계를 먼저
        // 구해야 어느 펫이든 같은 크기로 보인다.
        //
        // 얼굴만 남기는 규칙: 경계 상자 **위쪽에서 정사각형**을 잘라 낸다. 키가 큰
        // 펫은 머리와 어깨가 남고, 납작한 펫(메타몽·디그다)은 세로가 짧아 정사각형이
        // 가로를 좁히므로 통째로 담긴다. 펫마다 얼굴 좌표를 손으로 적지 않아도 되는
        // 것이 이 규칙의 값어치다.
        //
        // 한 변은 경계의 짧은 쪽 그대로다. 더 좁히면 얼굴이 커지지만, 기울어 선 펫에서
        // 머리가 잘려 나가는 쪽이 손해가 크다.
        // 한 변을 정수로 먼저 확정한다. 실수 사각형을 만들고 integral 로 맞추면 축마다
        // 반올림이 갈려 96x95 처럼 한 픽셀 어긋난 직사각형이 나온다.
        let side = max(1, Int(min(box.width, box.height).rounded()))
        // 가로 중심은 경계 상자 그대로 쓴다.
        //
        // 한때 "맨 위 띠에서 픽셀이 걸친 가운데" 를 머리로 보고 그쪽에 맞췄는데,
        // 27종에 돌려 보니 더 나빴다 — 맨 위 픽셀이 머리가 아닌 펫이 많다(아차모의
        // 볏, 뚜꾸리·꼬부기의 치켜든 팔, 리자몽의 날개). 그런 펫은 중심이 엉뚱한
        // 곳으로 끌려가 얼굴이 통째로 잘렸다. 상자 중심은 어느 펫에서도 크게
        // 어긋나지 않아, 몇 종을 더 잘 잡는 것보다 전부 멀쩡한 쪽을 택했다.
        let x = min(max(0, Int((box.midX - CGFloat(side) / 2).rounded())), cg.width - side)
        let y = min(max(0, Int(box.minY.rounded())), cg.height - side)
        guard side <= cg.width, side <= cg.height,
              let cropped = cg.cropping(to: CGRect(x: x, y: y, width: side, height: side))
        else { return nil }

        let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        image.isTemplate = false
        return image
    }

    /// 투명하지 않은 픽셀이 차지하는 범위(이미지 좌표, 원점은 좌상단).
    ///
    /// 알파만 보면 되므로 8비트 알파 전용 컨텍스트에 한 번 그려 훑는다 — RGBA 로
    /// 읽으면 픽셀당 4바이트를 헛도는 셈이다.
    private static func opaqueBounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: w * h)
        let ok = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        // 배경이 완전 투명이 아닌 스프라이트가 있어 0 이 아니라 여유를 둔다.
        let threshold: UInt8 = 16
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where alpha[row + x] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
