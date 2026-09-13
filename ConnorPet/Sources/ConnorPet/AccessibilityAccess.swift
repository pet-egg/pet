import AppKit
import ApplicationServices

/// Helpers for the macOS **Accessibility (손쉬운 사용)** permission — the one grant
/// the Claude Desktop source needs. Reading Claude Desktop's per-turn state
/// (생성 중·완료·승인 대기) is only possible by walking its forced AX tree, and
/// that requires this permission (see `ClaudeAXProbe`).
///
/// Mirrors `FullDiskAccess`: the app can't grant it itself — macOS requires the
/// user to flip it in System Settings — so all we can do is detect the state,
/// make sure we're listed there, and open the right pane. `AppDelegate` drives
/// the UI (an actionable alert whenever the desktop source is active but the
/// grant is missing).
enum AccessibilityAccess {
    /// Whether we're trusted to read other apps' AX trees. This is the single
    /// source of truth — after an update our ad-hoc signature's cdhash changes,
    /// so a *shown-ON-but-stale* System Settings toggle still reports `false`
    /// here (see `ClaudeAXProbe.reconcileAccessibilityGrant()`).
    static func isGranted() -> Bool { AXIsProcessTrusted() }

    /// Ask macOS to add us to the Accessibility list (so the user has a toggle to
    /// flip) and show its own one-shot system prompt. The system dialog only
    /// appears while there's no TCC record for us yet — which is exactly the case
    /// right after a fresh install or after we purge a stale record on update — so
    /// we never rely on it for repeat nagging (that's the alert in `AppDelegate`).
    static func registerAndPrompt() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Open System Settings straight to Privacy & Security ▸ Accessibility. The
    /// URL scheme is stable across the old System Preferences and the newer
    /// System Settings, so it lands on the right pane on both.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
