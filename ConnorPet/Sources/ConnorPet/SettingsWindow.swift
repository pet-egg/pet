import AppKit
import CoreImage

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
    /// 예전 실행 방식(swift run · 옛 .app)에 남은 기록을 가져올 수 있는지.
    var settingsLegacyStatus: XPMigration.LegacyStatus { get }
    /// 예전 기록을 지금 펫들에 합친다. 결과를 사람이 읽을 한 줄로 돌려준다.
    func settingsImportLegacyXP() -> String

    // 연동
    var settingsHooksInstalled: Bool { get }
    func settingsToggleHooks()
    var settingsFullDiskAccessGranted: Bool { get }
    func settingsOpenFullDiskAccess()

    // Linear 연동 — 키 자체는 키체인에 있고 여기로 오가지 않는다. 저장 여부와
    // 마지막 확인 결과만 주고받는다.
    var settingsLinearKeyStored: Bool { get }
    var settingsLinearStatus: String? { get }
    func settingsSaveLinearKey(_ key: String)
    func settingsDeleteLinearKey()

    // 대전 / 노려보기 (같은 wifi 상대)
    /// 이 맥에 쌓인 대전 전적 한 줄. 예: "12승 8패 · 승률 60%"
    var settingsBattleRecord: String { get }
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
    /// 지금 화면에 있는 Linear 키 입력란. rebuild 마다 새로 만든다.
    private weak var linearKeyField: NSSecureTextField?

    var isVisible: Bool { window?.isVisible ?? false }


    // MARK: - Show / refresh

    func show() {
        // show() 는 **항상 메뉴 추적 루프 안에서** 불린다 — 메뉴바 "설정…"(상태바
        // NSMenu)이든 펫 우클릭 "설정…"(NSMenu.popUpContextMenu)이든. 이미 한 번
        // 연 창이 떠 있는 상태에서 다시 부르면, 아래 present() 의 rebuildContent 가
        // `removeFromSuperview` 로 **직전에 만든 라이브 NSPopUpButton** 을 메뉴가
        // 아직 추적 중인 도중에 헐어, AppKit 이 죽은 객체를 건드려 EXC_BAD_ACCESS
        // 로 죽는다("doc(메뉴바)으로 연 뒤 우클릭으로 다시 열면 꺼지는" 버그 —
        // refresh() 를 다음 런루프로 미룬 것과 완전히 같은 원인). 그래서 present()
        // 도 다음 런루프로 미뤄, 메뉴 추적이 끝나고 액션 디스패치가 스택에서 빠진
        // 뒤에 창을 그린다. 한 틱 늦게 뜨지만 눈에는 즉시로 보인다.
        DispatchQueue.main.async { [weak self] in
            self?.present()
        }
    }

    private func present() {
        if window == nil { buildWindow() }
        rebuildContent()
        guard let window else { return }

        // 위치를 먼저 잡는다. 앞으로 내보낸 뒤 옮기면 한 프레임 다른 자리에 보인다.
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // 여기까지만 하면 창이 **다른 앱 뒤에 깔린다**. 이 앱은 .accessory 라
        // 메뉴 막대 항목을 눌러도 앱이 활성화되지 않고, 최신 macOS 는 활성화되지
        // 않은 앱의 activate 요청을 무시한다. 실측으로 key=false / appActive=false /
        // orderedIndex=2 였다 — 창은 떠 있는데 사용자 눈에는 "안 뜬" 것이다.
        //
        // orderFrontRegardless 는 활성화 여부와 무관하게 앞으로 내보낸다.
        window.orderFrontRegardless()

        // 그리고 떠 있는 층에 올린다. 앞으로 내보내는 것만으로는 다른 앱을 한 번
        // 클릭하는 순간 다시 뒤로 숨고, 이 앱은 활성화가 막혀 있어 되살릴 방법이
        // 없다. 활성화 여부로 갈라 보려 했으나 실측에서 열린 직후 활성 상태가
        // 뒤집혀(열 때 true → 1초 뒤 false) 조건이 소용없었다.
        //
        // 포커스를 받으면(windowDidBecomeKey) 곧바로 보통 층으로 내린다. 그래서
        // 설정 창이 계속 위에 떠 있는 성가신 창이 되지는 않는다.
        window.level = .floating
        window.makeKey()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.level = .normal
    }

    /// 창이 떠 있는 동안 상태(대전 상대 목록, 훅 설치 여부 등)가 바뀌면 다시 그린다.
    ///
    /// 반드시 **다음 런루프로 미뤄** 다시 그린다. 펫/소스 팝업을 고르면 그 액션이
    /// (changePet → statusDidChange → refresh 로) 곧장 refresh 를 부르는데, 여기서
    /// 동기로 rebuildContent 하면 `removeFromSuperview` 가 **아직 메뉴를 추적 중이던
    /// 바로 그 NSPopUpButton** 을 해제해, AppKit 이 쓰고 있던 죽은 객체를 건드려
    /// EXC_BAD_ACCESS 로 죽는다("펫 선택 시 앱이 꺼지는" 버그 — 상태바 메뉴
    /// 갈아끼우기 크래시와 같은 원인). 미루면 컨트롤이 추적을 끝낸 뒤 안전하게
    /// 재구성된다. 여러 상태 변화가 겹쳐 async 가 여러 번 큐잉돼도 무해하다.
    func refresh() {
        guard isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.rebuildContent()
        }
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

        var rows = [
            RowSpec(title: "펫 선택", control: popup),
            RowSpec(title: "진화 사용", subtitle: "경험치가 쌓이면 다음 단계로 진화", control: evo),
            RowSpec(title: "경험치 바 항상 표시", subtitle: "끄면 펫에 마우스를 올렸을 때만", control: bar),
        ]

        // 예전 실행 방식에 남아 있는 경험치를 손으로 가져온다.
        //
        // 왜 버튼이 필요한가: 경험치는 UserDefaults 에 있고 어느 파일을 쓰는지는 번들
        // 식별자가 정한다. 그래서 swift run → .app → dmg 로 갈아타면 저장소가 갈려
        // 경험치가 사라진 것처럼 보인다. 자동 이관은 "지금 도메인이 비어 있을 때" 만
        // 도는데, 이미 조금 쌓인 뒤에 알아차리면 그 조건에 걸리지 않는다.
        if let row = legacyXPRow(d) { rows.append(row) }

        rows.append(RowSpec(title: "모든 경험치 초기화", control: reset))
        return rows
    }

    /// 예전 기록이 하나라도 있으면 늘 보이는 행. 아예 없을 때만 nil 이다.
    ///
    /// 가져올 게 없을 때도 보여 주는 이유: 숨기면 기능이 없는 것처럼 보여서, 이미
    /// 가져온 사람이 "가져오기가 어디 있나" 하고 찾게 된다. 상태를 문구로 밝히고
    /// 버튼만 잠근다.
    private func legacyXPRow(_ d: SettingsActionsDelegate) -> RowSpec? {
        let status = d.settingsLegacyStatus
        guard status != .none else { return nil }

        let button = makeButton(title: "가져오기", action: #selector(importLegacyPressed))
        func won(_ value: Double) -> String {
            Self.decimal.string(from: NSNumber(value: Int(value))) ?? "\(Int(value))"
        }

        switch status {
        case .none:
            return nil
        case .importable(_, let gain):
            let pets = gain.count == 1 ? "펫 1종" : "펫 \(gain.count)종"
            return RowSpec(title: "구 버전에서 경험치 가져오기",
                           subtitle: "예전 기록 발견 — \(pets) · \(won(gain.values.reduce(0, +))) 늘어나요",
                           control: button)
        case .alreadyMerged(let found):
            button.isEnabled = false
            return RowSpec(title: "구 버전에서 경험치 가져오기",
                           subtitle: "예전 기록 \(won(found.values.reduce(0, +))) — 이미 다 가져왔어요",
                           control: button, dimmed: true)
        }
    }

    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    @objc private func importLegacyPressed() {
        guard let d = delegate,
              case .importable(_, let gain) = d.settingsLegacyStatus else { return }
        let total = Int(gain.values.reduce(0, +))
        let amount = Self.decimal.string(from: NSNumber(value: total)) ?? "\(total)"
        // 펫마다 큰 쪽을 남기는 합치기라 줄어들 일은 없지만, 경험치를 건드리는
        // 동작이니 한 번 확인받는다.
        guard BattleDialog.confirm(title: "예전 경험치 가져오기",
                                   message: "예전 기록에서 \(amount) 을 가져옵니다.\n\n펫마다 더 많이 쌓인 쪽을 남기므로\n지금 경험치가 줄어들지는 않아요.",
                                   confirmTitle: "가져오기") else { return }

        let result = d.settingsImportLegacyXP()
        rebuildContent()
        BattleDialog.info(title: "가져오기 완료", message: result)
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
        var rows = [
            RowSpec(title: "Claude Code 상태 훅", subtitle: "헤롱헤롱(작업 완료) / 실패 표시", control: hooks),
        ]
        if FullDiskAccess.isAppBundle {
            rows.append(RowSpec(title: "전체 디스크 접근 권한",
                                subtitle: granted ? "허용됨 — 완료 알림으로 헤롱헤롱 감지" : "헤롱헤롱 알림 감지에 필요",
                                control: makeButton(title: granted ? "확인" : "열기",
                                                    action: #selector(fdaPressed))))
        } else {
            // 번들이 아니면 설정 창을 열어 줘 봐야 목록에 ConnorPet 이 안 뜬다.
            // 대신 왜 그런지와 어떻게 하면 되는지를 알려 준다.
            rows.append(RowSpec(title: "전체 디스크 접근 권한 — 지금은 줄 수 없어요",
                                subtitle: "swift run 은 앱 번들이 아니라, 목록에 띄운 앱 이름이 대신 떠요",
                                control: makeButton(title: "만드는 명령 복사",
                                                    action: #selector(fdaCopyBuildCommand)),
                                dimmed: true))
        }
        rows += linearRows(d)
        return rows
    }

    /// Linear API 키 입력. 키를 넣어야 티켓 Done 이 퀘스트로 잡힌다.
    ///
    /// 입력란은 `NSSecureTextField` 다 — 어깨너머로 읽히면 안 되는 값이고, 실수로
    /// 스크린샷에 담기는 것도 막는다. 저장된 키를 여기에 되채우지 않는다. 그러려면
    /// 키체인을 읽어야 하는데, 설정 창을 여는 것만으로 암호 창이 뜨게 된다.
    private func linearRows(_ d: SettingsActionsDelegate) -> [RowSpec] {
        let stored = d.settingsLinearKeyStored
        let field = NSSecureTextField()
        field.placeholderString = stored ? "바꾸려면 새 키" : "lin_api_…"
        field.font = .systemFont(ofSize: 12)
        field.target = self
        field.action = #selector(linearKeySubmitted(_:))   // Return 으로도 저장
        // 스택뷰는 우리가 준 frame 이 아니라 고유 크기로 배치한다. 빈 입력란의 고유
        // 폭은 15pt 남짓이라 제약으로 못 박지 않으면 글자 한 자도 안 들어간다.
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 140),
            field.heightAnchor.constraint(equalToConstant: 22),
        ])
        linearKeyField = field

        // 버튼 이름은 "저장" 으로 짧게 둔다. 저장이 곧 확인이라는 것은 보조문구가
        // "확인 중…" → "연결됨 — …" 으로 바뀌며 알려 주고, 이름을 길게 잡으면
        // 컨트롤이 넓어져 왼쪽 설명이 잘린다.
        let stack = NSStackView(views: [field, makeButton(title: "저장", action: #selector(linearSavePressed))])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.frame.size = stack.fittingSize

        // 키를 어디서 만드는지 모르면 입력란만 있어 봐야 소용이 없다. Linear 의
        // 개인 API 키 화면으로 바로 보낸다.
        var rows = [RowSpec(title: "Linear에서 키 만들기",
                            subtitle: "Settings › Security & access › Personal API keys",
                            control: makeButton(title: "열기", action: #selector(linearOpenPressed)))]
        rows.append(RowSpec(title: "Linear API 키",
                            subtitle: d.settingsLinearStatus
                                ?? (stored ? "저장됨 — 티켓 Done 이 퀘스트로 잡혀요"
                                           : "넣으면 티켓 Done 도 퀘스트가 돼요"),
                            control: stack))
        // 키체인 항목은 앱의 코드 서명에 묶여 있고 ad-hoc 서명은 빌드마다 바뀐다.
        // 암호 창이 왜 뜨는지 모르면 앱이 고장 난 줄 안다.
        if stored {
            rows.append(RowSpec(title: "키체인 암호를 물으면 「항상 허용」",
                                subtitle: "항목이 앱 서명에 묶여 있어요. 앱은 실행당 한 번만 읽습니다",
                                control: nil, dimmed: true))
            rows.append(RowSpec(title: "Linear 키 삭제",
                                control: makeButton(title: "삭제", action: #selector(linearDeletePressed)),
                                destructive: true))
        }
        return rows
    }

    @objc private func linearSavePressed() { submitLinearKey() }
    @objc private func linearKeySubmitted(_ sender: NSTextField) { submitLinearKey() }

    private func submitLinearKey() {
        guard let field = linearKeyField else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // 입력란은 곧바로 비운다. 값이 화면에 남아 있을 이유가 없다.
        field.stringValue = ""
        delegate?.settingsSaveLinearKey(key)
    }

    /// `.app` 을 만드는 명령을 클립보드에 넣는다. 붙여 넣고 실행하면 이름이 제대로
    /// 뜨는 앱이 만들어진다.
    @objc private func fdaCopyBuildCommand() {
        let command = FullDiskAccess.makeAppCommand()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        BattleDialog.info(title: "명령을 복사했어요",
                          message: "터미널에 붙여 넣고 실행하면\nConnorPet.app 이 만들어져요.\n\n그 앱으로 실행하면 전체 디스크 접근\n목록에 ConnorPet 으로 나옵니다.")
    }

    @objc private func linearOpenPressed() {
        NSWorkspace.shared.open(URL(string: "https://linear.app/settings/account/security")!)
    }

    @objc private func linearDeletePressed() {
        linearKeyField?.stringValue = ""
        delegate?.settingsDeleteLinearKey()
    }

    private func battleRows(_ d: SettingsActionsDelegate) -> [RowSpec] {
        // 전적은 상대가 없어도 보여 준다 — 지난 성적을 보려고 여는 자리이기도 하다.
        let reward = Self.decimal.string(from: NSNumber(value: Int(BattleRecord.winReward)))
            ?? "\(Int(BattleRecord.winReward))"
        var rows = [RowSpec(title: "대전 전적",
                            subtitle: "\(d.settingsBattleRecord) · 이기면 +\(reward) EXP",
                            control: nil, dimmed: true)]

        let peers = d.settingsBattlePeers
        guard !peers.isEmpty else {
            rows.append(RowSpec(title: "주변에 상대가 없어요",
                                subtitle: "같은 Wi-Fi의 다른 ConnorPet을 찾는 중",
                                control: nil, dimmed: true))
            return rows
        }
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
        // 네이티브 NSSwitch 의 켜짐 색은 시스템 accent(사용자 환경에 따라 초록 등)라
        // 무채색 카드 룩과 어긋난다. 레이어에 채도 제거 필터를 걸어 accent 와 무관하게
        // 항상 그레이(그래파이트)로 보이게 한다. 공개 API(CALayer.filters + CoreImage)만 사용.
        sw.wantsLayer = true
        if let desaturate = CIFilter(name: "CIColorControls") {
            desaturate.setValue(0.0, forKey: kCIInputSaturationKey)
            sw.layer?.filters = [desaturate]
        }
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
