import AppKit

/// 설정 창이 필요로 하는 값 읽기 + 동작 실행을 AppDelegate 로 넘기는 다리.
/// 메뉴바(상태 아이템)에 있던 기능을 그대로 창에서도 쓰게 하려는 것이므로,
/// 각 메서드는 AppDelegate 의 기존 메뉴 핸들러와 같은 코드 경로를 탄다.
protocol SettingsActionsDelegate: AnyObject {
    // 펫
    var settingsOrderedPets: [(slug: String, name: String)] { get }
    var settingsSelectedPetSlug: String { get }
    func settingsSelectPet(slug: String)

    // 상태 소스
    var settingsOrderedStatusSources: [(id: String, name: String)] { get }
    var settingsSelectedStatusSource: String { get }
    func settingsSelectStatusSource(id: String)

    // 토글
    var settingsEvolutionEnabled: Bool { get }
    func settingsSetEvolutionEnabled(_ on: Bool)
    var settingsBarAlwaysVisible: Bool { get }
    func settingsSetBarAlwaysVisible(_ on: Bool)

    // 경험치
    func settingsResetAllXP()

    // 연동
    var settingsHooksInstalled: Bool { get }
    func settingsToggleHooks()
    var settingsFullDiskAccessGranted: Bool { get }
    func settingsOpenFullDiskAccess()

    // 대전 / 노려보기 (같은 wifi 상대)
    var settingsBattlePeers: [(id: String, name: String)] { get }
    func settingsChallenge(peerID: String)
    func settingsStare(peerID: String)

    // 앱
    func settingsQuit()
}

/// 메뉴바가 가려 접근하기 어려운 사용자를 위해, 펫 우클릭 › "설정…"에서 여는
/// 창. 메뉴바 아이템에 흩어져 있던 모든 기능을 한 곳에 모은다.
///
/// 룩은 macOS 시스템 설정·Linear·Things 계열의 **무채색 그룹 카드** — 밝은
/// 회색 배경 위에 흰(다크 모드에선 짙은 회색) 둥근 카드, 카드 위엔 작은 회색
/// 섹션 제목, 각 행은 왼쪽 라벨 + 오른쪽 컨트롤. 색은 전부 시스템 semantic
/// 그레이(label/secondaryLabel/separator/controlBackground/windowBackground)라
/// 라이트·다크 모두에서 자동으로 무채색을 유지한다.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    weak var delegate: SettingsActionsDelegate?

    private var window: NSWindow?
    private var scrollView: NSScrollView?
    private var documentView: FlippedView?

    // 레이아웃 상수
    private let winWidth: CGFloat = 460
    private let leftPad: CGFloat = 20
    private let topPad: CGFloat = 16
    private let bottomPad: CGFloat = 20
    private let headerHeight: CGFloat = 30
    private let rowHeight: CGFloat = 46
    private let sectionGap: CGFloat = 12
    private let maxVisibleContentHeight: CGFloat = 640
    private var cardWidth: CGFloat { winWidth - leftPad * 2 }

    // 대전 신청/노려보기 버튼 → peer id 매핑 (rebuild 마다 다시 채운다)
    private var peerButtonMap: [Int: String] = [:]

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Show / refresh

    func show() {
        if window == nil { buildWindow() }
        rebuildContent()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    /// 창이 떠 있는 동안 상태(대전 상대 목록, 훅 설치 여부 등)가 바뀌면 다시 그린다.
    func refresh() {
        guard isVisible else { return }
        rebuildContent()
    }

    /// 디버그 전용: 화면 캡처 권한 없이도 레이아웃을 눈으로 확인하려고, 내용 뷰를
    /// 그대로 PNG 로 떠서 남긴다(말풍선 디버그와 같은 방식).
    func debugRenderPNG(to path: String) {
        if window == nil { buildWindow() }
        rebuildContent()
        guard let doc = documentView else { return }
        doc.layoutSubtreeIfNeeded()
        guard let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return }
        doc.cacheDisplay(in: doc.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    private func buildWindow() {
        let win = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: winWidth, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "ConnorPet 설정"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = .windowBackgroundColor
        win.delegate = self

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: winWidth, height: 480))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: winWidth, height: 480))
        scroll.documentView = doc
        win.contentView = scroll

        window = win
        scrollView = scroll
        documentView = doc
    }

    // MARK: - Content

    private func rebuildContent() {
        guard let doc = documentView, let delegate = delegate else { return }
        doc.subviews.forEach { $0.removeFromSuperview() }
        peerButtonMap.removeAll()

        var y = topPad

        // 1) 펫
        y = addSection(title: "펫", rows: petRows(delegate), at: y, in: doc)

        // 2) 상태 소스
        y = addSection(title: "상태 소스", rows: [sourceRow(delegate)], at: y, in: doc)

        // 3) 연동
        y = addSection(title: "연동", rows: integrationRows(delegate), at: y, in: doc)

        // 4) 대전 / 노려보기
        y = addSection(title: "대전 / 노려보기", rows: battleRows(delegate), at: y, in: doc)

        // 5) 앱
        y = addSection(title: "앱", rows: [quitRow()], at: y, in: doc)

        y += bottomPad - sectionGap

        // 문서 높이 = 콘텐츠 높이, 창 높이는 상한까지만(넘치면 스크롤)
        let contentHeight = y
        let visible = min(contentHeight, maxVisibleContentHeight)
        doc.frame = NSRect(x: 0, y: 0, width: winWidth, height: max(contentHeight, visible))
        resizeWindow(toContentHeight: visible)
        scrollView?.contentView.scroll(to: .zero)
    }

    /// 섹션 하나(작은 회색 제목 + 둥근 카드)를 y 위치에 놓고, 다음 y 를 돌려준다.
    private func addSection(title: String, rows: [RowSpec], at startY: CGFloat, in doc: NSView) -> CGFloat {
        var y = startY

        let header = makeSectionHeader(title)
        header.frame = NSRect(x: leftPad + 4, y: y + 8, width: cardWidth - 8, height: 18)
        doc.addSubview(header)
        y += headerHeight

        let cardHeight = rowHeight * CGFloat(max(rows.count, 1))
        let card = CardView(frame: NSRect(x: leftPad, y: y, width: cardWidth, height: cardHeight))
        card.rowCount = rows.count
        card.rowHeight = rowHeight
        doc.addSubview(card)

        for (i, row) in rows.enumerated() {
            layout(row: row, index: i, in: card)
        }

        y += cardHeight + sectionGap
        return y
    }

    /// 카드 안의 한 행: 왼쪽 라벨(+선택적 보조문구), 오른쪽 컨트롤. 카드는 flipped.
    private func layout(row: RowSpec, index i: Int, in card: NSView) {
        let rowTop = CGFloat(i) * rowHeight
        let inset: CGFloat = 14

        var controlLeftEdge = card.frame.width - inset
        if let control = row.control {
            // NSControl(팝업/스위치/버튼)은 sizeToFit 로, NSStackView(peer 버튼 묶음)은
            // 이미 fittingSize 로 프레임이 잡혀 있으므로 그대로 쓴다.
            if let ctrl = control as? NSControl { ctrl.sizeToFit() }
            var f = control.frame
            // 팝업은 sizeToFit 폭이 좁아 텍스트가 잘리기도 해 최소 폭을 준다.
            if control is NSPopUpButton {
                f.size.width = max(f.size.width, 150)
            }
            f.origin.x = card.frame.width - inset - f.size.width
            f.origin.y = rowTop + (rowHeight - f.size.height) / 2
            control.frame = f
            card.addSubview(control)
            controlLeftEdge = f.origin.x - 10
        }

        let hasSub = row.subtitle != nil
        let titleH: CGFloat = 17
        let subH: CGFloat = 14
        let blockH = hasSub ? titleH + subH + 1 : titleH
        let blockTop = rowTop + (rowHeight - blockH) / 2

        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = row.destructive ? .systemRed : .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: inset, y: blockTop, width: controlLeftEdge - inset, height: titleH)
        card.addSubview(title)

        if let sub = row.subtitle {
            let subLabel = NSTextField(labelWithString: sub)
            subLabel.font = .systemFont(ofSize: 11)
            subLabel.textColor = .secondaryLabelColor
            subLabel.lineBreakMode = .byTruncatingTail
            subLabel.frame = NSRect(x: inset, y: blockTop + titleH + 1, width: controlLeftEdge - inset, height: subH)
            card.addSubview(subLabel)
        }
    }

    // MARK: - Row builders

    private func petRows(_ d: SettingsActionsDelegate) -> [RowSpec] {
        // 펫 선택 (팝업)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for pet in d.settingsOrderedPets {
            let item = NSMenuItem(title: pet.name, action: nil, keyEquivalent: "")
            item.representedObject = pet.slug
            popup.menu?.addItem(item)
        }
        if let idx = d.settingsOrderedPets.firstIndex(where: { $0.slug == d.settingsSelectedPetSlug }) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(petPopupChanged(_:))

        // 진화 사용 (스위치)
        let evo = makeSwitch(on: d.settingsEvolutionEnabled, action: #selector(evolutionToggled(_:)))
        // 경험치 바 항상 표시 (스위치)
        let bar = makeSwitch(on: d.settingsBarAlwaysVisible, action: #selector(barToggled(_:)))
        // 경험치 초기화 (버튼)
        let reset = makeButton(title: "초기화", action: #selector(resetPressed))

        return [
            RowSpec(title: "펫 선택", control: popup),
            RowSpec(title: "진화 사용", subtitle: "경험치가 쌓이면 다음 단계로 진화", control: evo),
            RowSpec(title: "경험치 바 항상 표시", subtitle: "끄면 펫에 마우스를 올렸을 때만", control: bar),
            RowSpec(title: "모든 경험치 초기화", control: reset),
        ]
    }

    private func sourceRow(_ d: SettingsActionsDelegate) -> RowSpec {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for src in d.settingsOrderedStatusSources {
            let item = NSMenuItem(title: src.name, action: nil, keyEquivalent: "")
            item.representedObject = src.id
            popup.menu?.addItem(item)
        }
        if let idx = d.settingsOrderedStatusSources.firstIndex(where: { $0.id == d.settingsSelectedStatusSource }) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(sourcePopupChanged(_:))
        return RowSpec(title: "상태 소스", subtitle: "펫 애니메이션을 무엇으로 움직일지", control: popup)
    }

    private func integrationRows(_ d: SettingsActionsDelegate) -> [RowSpec] {
        let hooks = makeSwitch(on: d.settingsHooksInstalled, action: #selector(hooksToggled(_:)))
        let granted = d.settingsFullDiskAccessGranted
        let fdaButton = makeButton(title: granted ? "확인" : "열기", action: #selector(fdaPressed))
        return [
            RowSpec(title: "Claude Code 상태 훅", subtitle: "얼음(권한 대기) / 헤롱헤롱(작업 완료) 표시", control: hooks),
            RowSpec(title: "전체 디스크 접근 권한",
                    subtitle: granted ? "허용됨 — 완료 알림으로 헤롱헤롱 감지" : "헤롱헤롱 알림 감지에 필요",
                    control: fdaButton),
        ]
    }

    private func battleRows(_ d: SettingsActionsDelegate) -> [RowSpec] {
        let peers = d.settingsBattlePeers
        guard !peers.isEmpty else {
            return [RowSpec(title: "주변에 상대가 없어요", subtitle: "같은 Wi-Fi의 다른 ConnorPet을 찾는 중", control: nil, dimmed: true)]
        }
        var rows: [RowSpec] = []
        for (i, peer) in peers.enumerated() {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 8

            let challenge = makeButton(title: "신청", action: #selector(challengePressed(_:)))
            challenge.tag = i
            let stare = makeButton(title: "노려보기", action: #selector(starePressed(_:)))
            stare.tag = i
            peerButtonMap[i] = peer.id

            stack.addArrangedSubview(challenge)
            stack.addArrangedSubview(stare)
            stack.layoutSubtreeIfNeeded()
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)

            rows.append(RowSpec(title: peer.name, control: stack))
        }
        return rows
    }

    private func quitRow() -> RowSpec {
        let quit = makeButton(title: "종료", action: #selector(quitPressed))
        return RowSpec(title: "ConnorPet 종료", control: quit)
    }

    // MARK: - Small factory helpers

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSwitch(on: Bool, action: Selector) -> NSSwitch {
        let sw = NSSwitch()
        sw.state = on ? .on : .off
        sw.target = self
        sw.action = action
        return sw
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        return b
    }

    private func resizeWindow(toContentHeight contentHeight: CGFloat) {
        guard let win = window else { return }
        var frame = win.frame
        let titleBarHeight = win.frame.height - (win.contentView?.frame.height ?? win.frame.height)
        let newHeight = contentHeight + titleBarHeight
        // 위쪽 가장자리를 유지하며 높이만 조정한다.
        frame.origin.y += frame.size.height - newHeight
        frame.size.height = newHeight
        frame.size.width = winWidth
        win.setFrame(frame, display: true)
    }

    // MARK: - Actions (모두 delegate 로 위임 — 메뉴바와 같은 경로)

    @objc private func petPopupChanged(_ sender: NSPopUpButton) {
        guard let slug = sender.selectedItem?.representedObject as? String else { return }
        delegate?.settingsSelectPet(slug: slug)
    }

    @objc private func sourcePopupChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        delegate?.settingsSelectStatusSource(id: id)
    }

    @objc private func evolutionToggled(_ sender: NSSwitch) {
        delegate?.settingsSetEvolutionEnabled(sender.state == .on)
    }

    @objc private func barToggled(_ sender: NSSwitch) {
        delegate?.settingsSetBarAlwaysVisible(sender.state == .on)
    }

    @objc private func resetPressed() {
        delegate?.settingsResetAllXP()
    }

    @objc private func hooksToggled(_ sender: NSSwitch) {
        // 설치/제거는 확인 모달을 띄우고, 취소하면 상태가 안 바뀐다. 실제 결과에
        // 스위치를 맞춰야 하므로 동작 뒤 전체를 다시 그린다.
        delegate?.settingsToggleHooks()
        refresh()
    }

    @objc private func fdaPressed() {
        delegate?.settingsOpenFullDiskAccess()
        refresh()
    }

    @objc private func challengePressed(_ sender: NSButton) {
        guard let id = peerButtonMap[sender.tag] else { return }
        delegate?.settingsChallenge(peerID: id)
    }

    @objc private func starePressed(_ sender: NSButton) {
        guard let id = peerButtonMap[sender.tag] else { return }
        delegate?.settingsStare(peerID: id)
    }

    @objc private func quitPressed() {
        delegate?.settingsQuit()
    }
}

/// 한 행의 사양: 왼쪽 라벨(+보조문구) 과 오른쪽 컨트롤.
private struct RowSpec {
    let title: String
    let subtitle: String?
    let control: NSView?
    let destructive: Bool
    let dimmed: Bool

    init(title: String, subtitle: String? = nil, control: NSView?, destructive: Bool = false, dimmed: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
        self.destructive = destructive
        self.dimmed = dimmed
    }
}

/// 위에서 아래로 쌓기 편하게 좌표계를 뒤집은 컨테이너. 창 배경색을 직접 칠해,
/// 카드 사이 여백이 창과 같은 무채색 회색으로 보이게 한다.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// 둥근 카드 배경 + 행 사이 얇은 구분선. 색은 전부 시스템 그레이라 무채색을
/// 유지하고 라이트/다크에 자동 대응한다.
private final class CardView: NSView {
    var rowCount = 0
    var rowHeight: CGFloat = 46

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        guard rowCount > 1 else { return }
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        for i in 1..<rowCount {
            let y = CGFloat(i) * rowHeight
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 14, y: y))
            line.line(to: NSPoint(x: bounds.width, y: y))
            line.lineWidth = 1
            line.stroke()
        }
    }
}

/// 액세서리(메뉴바) 앱이라 일반 창이 키가 되려면 명시적으로 허용해야 한다.
private final class SettingsPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
