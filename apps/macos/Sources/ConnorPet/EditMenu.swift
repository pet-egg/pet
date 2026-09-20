import AppKit

/// 잘라내기·복사·붙여넣기 단축키를 살려 두는 최소한의 메인 메뉴.
///
/// 이 앱은 `.accessory` 라 Dock 아이콘도 메뉴 막대도 없다. 그런데 ⌘V 같은 단축키는
/// **`NSApp.mainMenu` 를 뒤져서** 처리된다 — 메뉴가 없으면 갈 곳이 없어 아무 일도
/// 일어나지 않는다. 설정 창의 API 키 입력란에 붙여넣기가 안 되던 이유가 이것이다.
///
/// 화면에는 아무것도 나타나지 않는다. `.accessory` 앱은 활성 상태여도 메뉴 막대를
/// 그리지 않기 때문에, 이 메뉴는 오로지 단축키를 받아 주는 통로다.
///
/// 동작은 `nil` 타깃으로 보낸다 — 지금 편집 중인 텍스트 필드가 응답자 사슬에서
/// 받는다. 특정 필드를 가리키면 필드가 늘 때마다 여기를 고쳐야 한다.
enum EditMenu {
    static func install() {
        guard NSApp.mainMenu == nil else { return }

        let edit = NSMenu(title: "편집")
        let items: [(String, Selector, String)] = [
            ("실행 취소", Selector(("undo:")), "z"),
            ("다시 실행", Selector(("redo:")), "Z"),
            ("잘라내기", #selector(NSText.cut(_:)), "x"),
            ("복사", #selector(NSText.copy(_:)), "c"),
            ("붙여넣기", #selector(NSText.paste(_:)), "v"),
            ("모두 선택", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, key) in items {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let main = NSMenu()
        // 첫 항목은 앱 메뉴 자리다. 비워 두면 macOS 가 편집 메뉴를 앱 메뉴로 잡아
        // 그 안의 단축키를 놓친다.
        main.addItem(NSMenuItem())
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
