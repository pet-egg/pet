import AppKit
import Sparkle

/// Wraps Sparkle so the app checks for updates **silently on launch** and only
/// surfaces "an update is available" through the menu bar — no automatic
/// pop-ups or toasts. The user has to click the menu item to actually download
/// and install (that click opens Sparkle's standard install/relaunch UI).
///
/// This is the split the product wants:
///   - 켤 때        → `checkQuietlyOnLaunch()`  (UI 없음, appcast만 조용히 확인)
///   - 메뉴 표시     → `onAvailabilityChanged` 콜백으로 "업데이트 있음" 반영
///   - 눌렀을 때     → `userInitiatedCheck()`    (Sparkle 정식 설치 플로우)
///
/// Sparkle verifies downloads with its own EdDSA signature (SUPublicEDKey in
/// Info.plist), not Apple Developer ID — so it works for our ad-hoc-signed,
/// un-notarized DMG builds. Sparkle also strips the quarantine flag from the
/// update it installs, so updates don't re-trigger Gatekeeper's first-run gate.
final class UpdaterManager: NSObject, SPUUpdaterDelegate {
    /// Only wire Sparkle up when the bundle is actually configured for it. Plain
    /// `swift run` builds have no SUFeedURL, and starting the updater without one
    /// makes Sparkle pop a configuration-error alert on launch — so we skip it
    /// entirely there and the app just shows its version with no update item.
    static var isConfigured: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else { return false }
        return !feed.isEmpty
    }

    private var controller: SPUStandardUpdaterController!

    /// Fired on the main thread whenever update availability changes, so the
    /// AppDelegate can relabel/enable its menu item. `version` is the found
    /// update's human-readable version (e.g. "1.3.0") when `available` is true.
    var onAvailabilityChanged: ((_ available: Bool, _ version: String?) -> Void)?

    private(set) var availableVersion: String?

    override init() {
        super.init()
        // startingUpdater: true boots Sparkle, but we drive every check ourselves
        // and turn *both* automatic behaviors off so nothing ever pops up on its
        // own — availability shows only in the menu until the user clicks.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
    }

    /// Silent check (no UI). The result flows back through the delegate methods
    /// below into `onAvailabilityChanged`. A missing/404 appcast (e.g. before the
    /// GitHub Pages feed exists) just aborts quietly — no alert.
    func checkQuietlyOnLaunch() {
        controller.updater.checkForUpdateInformation()
    }

    /// User clicked the menu item → run Sparkle's interactive download / verify /
    /// install / relaunch UI. Safe to call whether or not the quiet check already
    /// found something.
    @objc func userInitiatedCheck() {
        controller.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        availableVersion = version
        DispatchQueue.main.async { [weak self] in
            self?.onAvailabilityChanged?(true, version)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        DispatchQueue.main.async { [weak self] in
            self?.onAvailabilityChanged?(false, nil)
        }
    }

    // A missing feed / network error during the *silent* launch check must not
    // surface any UI — treat it like "no update found" and leave the menu alone.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        availableVersion = nil
        DispatchQueue.main.async { [weak self] in
            self?.onAvailabilityChanged?(false, nil)
        }
    }
}
