import AppKit

/// Helpers for the one macOS permission this app can benefit from: **Full Disk
/// Access**. Only the Claude Desktop source uses it — reading macOS's
/// Notification Center DB is how it detects "Claude finished a turn" from the
/// desktop app's completion banner and shows 헤롱헤롱 (see
/// `ClaudeDesktopStatusWatcher` / `NotificationCenterDB`). Without the grant the
/// desktop source still works, just falling back to CPU-only done detection.
///
/// The app can't grant this itself — macOS requires the user to flip it in
/// System Settings and relaunch — so all we can do is detect the state and open
/// the right settings pane. The menu action in `AppDelegate` drives both.
enum FullDiskAccess {
    /// Whether the app can read the Notification Center DB — our proxy for "Full
    /// Disk Access is granted". Cheap enough to call while rebuilding the menu.
    static func isGranted() -> Bool {
        NotificationCenterDB()?.isReadable ?? false
    }

    /// 지금 `.app` 번들로 돌고 있는가.
    ///
    /// `swift run` 은 번들 없는 맨 실행 파일을 띄운다. 그런 프로세스가 보호된
    /// 자원을 요구하면 macOS 는 권한을 **그것을 띄운 앱**에 귀속시킨다 — 터미널이나
    /// Claude Code 같은 것들이다. 그래서 시스템 설정의 전체 디스크 접근 목록에
    /// "ConnorPet" 대신 그 앱의 버전 문자열(`2.1.263` 같은)이 뜬다.
    ///
    /// 거기에 체크해 봐야 펫이 아니라 그 앱에 권한을 주는 것이고, 그 앱이 업데이트되면
    /// 경로가 바뀌어 다시 풀린다. 이 상태에서는 설정 창을 열어 줄 게 아니라 **왜 안
    /// 되는지** 를 알려 줘야 한다.
    static var isAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// `.app` 을 만들어 실행하는 명령. 지금 실행 파일 위치에서 저장소를 찾아
    /// 절대 경로로 만들어 준다 — 사용자가 어느 디렉터리에 있든 그대로 붙여 넣으면 된다.
    static func makeAppCommand() -> String {
        let fallback = "bash scripts/make_app.sh && open ~/Applications/ConnorPet.app"
        // 맨 실행 파일은 <repo>/apps/macos/.build/<트리플>/debug/ 아래에 있다. 단계
        // 수가 SwiftPM 판마다 달라(실측: .build/debug 와 .build/arm64-apple-macosx/debug)
        // 넉넉히 올라가며 스크립트를 찾는다.
        var dir = URL(fileURLWithPath: Bundle.main.bundlePath)
        for _ in 0..<6 {
            let script = dir.appendingPathComponent("scripts/make_app.sh")
            if FileManager.default.isReadableFile(atPath: script.path) {
                return "bash \(script.path) && open ~/Applications/ConnorPet.app"
            }
            dir.deleteLastPathComponent()
        }
        return fallback
    }

    /// Opens System Settings straight to Privacy & Security ▸ Full Disk Access.
    /// The URL scheme is stable across the old System Preferences and the newer
    /// System Settings, so it lands on the right pane on both.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
