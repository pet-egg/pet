import Foundation

/// Installs/removes the connor-pet Claude Code hooks from `~/.claude/settings.json`
/// straight from the app — the in-app equivalent of running
/// `scripts/install_claude_hooks.py`. This exists because a DMG-installed
/// `ConnorPet.app` has no repo checkout to run that script from: the menu action
/// (see AppDelegate `toggleClaudeHooks`) copies the bundled hook handler to a
/// stable path and wires the same hook events that the script does.
///
/// Working/blocked/idle now come from Claude Code's own session files (see
/// `ClaudeCodeStatusWatcher`), so the hooks are only needed for the two states
/// those files can't express — 헤롱헤롱/리뷰 대기(done) and 실패(failed). See
/// README "Claude Code 훅으로 헤롱헤롱/실패까지 보기".
///
/// This touches a **global** file affecting every Claude Code session on the
/// machine, so the menu action asks for explicit confirmation before calling in.
enum ClaudeHookInstaller {
    /// The Claude Code hook events we register, each mapped to the state argument
    /// passed to `pet_hook_status.py`. Kept in the same order and mapping as
    /// `scripts/install_claude_hooks.py`'s HOOK_EVENTS.
    private static let hookEvents: [(event: String, state: String)] = [
        ("Stop", "done"),
        ("SessionEnd", "remove"),
    ]

    enum InstallError: LocalizedError {
        case bundledScriptMissing
        case settingsUnreadable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledScriptMissing:
                return "앱 번들에서 훅 스크립트를 찾지 못했습니다."
            case .settingsUnreadable(let path):
                return "설정 파일을 읽지 못했습니다: \(path)"
            case .writeFailed(let detail):
                return "설정 파일 쓰기에 실패했습니다: \(detail)"
            }
        }
    }

    private static var homeDir: URL {
        // Test hook: point the installer at a throwaway home so the headless
        // self-test (CONNORPET_SELFTEST=hooks) never touches the real
        // ~/.claude/settings.json. Unset in normal runs.
        if let override = ProcessInfo.processInfo.environment["CONNORPET_HOOK_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var settingsURL: URL {
        homeDir.appendingPathComponent(".claude/settings.json")
    }

    /// Where the bundled hook handler is copied to. A stable, app-independent
    /// path so the hook keeps working even if the .app is moved or updated
    /// (install re-copies it, so a newer app refreshes the script in place).
    private static var installedScriptURL: URL {
        homeDir.appendingPathComponent(".claude/pet/pet_hook_status.py")
    }

    /// The command string written into settings.json for a given state. The
    /// path is quoted in case the home directory contains spaces.
    private static func command(for state: String) -> String {
        "python3 \"\(installedScriptURL.path)\" \(state)"
    }

    /// We recognize our own hook entries by the script filename in the command —
    /// both the current `pet_hook_status.py` and the legacy `claude_hook_status.py`,
    /// so a re-install migrates an old six-hook install and either installer path
    /// (script or app) detects/removes what the other added.
    private static func isPetEntry(_ hook: [String: Any]) -> Bool {
        guard (hook["type"] as? String) == "command",
              let command = hook["command"] as? String else { return false }
        return command.contains("pet_hook_status.py") || command.contains("claude_hook_status.py")
    }

    /// True when at least one of our hook entries is present in settings.json —
    /// scanning *all* events (not just the current set) so a legacy six-hook
    /// install still reads as installed. Drives the menu item's checkmark.
    static func isInstalled() -> Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            for block in (value as? [[String: Any]] ?? []) {
                let entries = block["hooks"] as? [[String: Any]] ?? []
                if entries.contains(where: isPetEntry) { return true }
            }
        }
        return false
    }

    // MARK: - Install / uninstall

    /// Copies the bundled hook handler to a stable path and merges our hook blocks
    /// into settings.json. Clears any prior entries of ours first (a legacy
    /// six-hook install, or a previous run) so it always converges to exactly
    /// `hookEvents` — this is what makes re-running safe and migrating automatic.
    /// Never touches existing (non-ours) hook blocks.
    @discardableResult
    static func install() throws -> [String] {
        try installBundledScript()

        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        _ = removePetEntries(from: &hooks) // migrate/dedupe before adding

        var added: [String] = []
        for (event, state) in hookEvents {
            // Always add our own dedicated block (never merge into a matcher-scoped
            // one, which would silently narrow when our hook fires).
            var blocks = hooks[event] as? [[String: Any]] ?? []
            blocks.append(["hooks": [["type": "command", "command": command(for: state)]]])
            hooks[event] = blocks
            added.append(event)
        }

        settings["hooks"] = hooks
        try saveSettings(settings)
        return added
    }

    /// Removes only the entries we added (current or legacy naming), dropping any
    /// block/event that becomes empty. Leaves the copied script file in place —
    /// harmless, and a re-install reuses it.
    @discardableResult
    static func uninstall() throws -> [String] {
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return [] }
        let removed = removePetEntries(from: &hooks)
        settings["hooks"] = hooks
        try saveSettings(settings)
        return removed
    }

    /// Strips every entry we own from all events, dropping blocks (and events)
    /// that become empty. Mutates `hooks` in place; returns the events touched.
    /// Shared by install (migrate) and uninstall — mirrors `remove_pet_entries`
    /// in install_claude_hooks.py.
    @discardableResult
    private static func removePetEntries(from hooks: inout [String: Any]) -> [String] {
        var removed: [String] = []
        for event in Array(hooks.keys) {
            guard let blocks = hooks[event] as? [[String: Any]] else { continue }
            var remainingBlocks: [[String: Any]] = []
            for var block in blocks {
                let blockHooks = block["hooks"] as? [[String: Any]] ?? []
                let kept = blockHooks.filter { !isPetEntry($0) }
                if kept.count != blockHooks.count {
                    removed.append(event)
                    if kept.isEmpty { continue }
                    block["hooks"] = kept
                }
                remainingBlocks.append(block)
            }
            if remainingBlocks.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remainingBlocks
            }
        }
        return Array(Set(removed))
    }

    // MARK: - Bundled script

    private static func installBundledScript() throws {
        guard let bundledURL = AppDelegate.resourceBundle.url(
            forResource: "pet_hook_status", withExtension: "py", subdirectory: "hooks"
        ) else {
            throw InstallError.bundledScriptMissing
        }
        let fm = FileManager.default
        let dest = installedScriptURL
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: bundledURL, to: dest)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - settings.json read/write

    /// Reads settings.json as a loose JSON object, preserving every key we don't
    /// touch. An empty/missing file is treated as `{}` — same as the Python
    /// installer — so a first-time user with no settings.json still installs.
    private static func loadSettings() throws -> [String: Any] {
        let path = settingsURL.path
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL) else {
            throw InstallError.settingsUnreadable(path)
        }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw InstallError.settingsUnreadable(path)
        }
        return dict
    }

    /// Backs up the existing file (timestamped), then writes atomically via a
    /// temp file + replace — mirroring save_settings() in the Python installer.
    private static func saveSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            if fm.fileExists(atPath: settingsURL.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = settingsURL.appendingPathExtension("pet-backup.\(stamp)")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: settingsURL, to: backup)
            }

            var data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            )
            data.append(0x0A) // trailing newline, like the Python writer

            let tmp = settingsURL.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: settingsURL.path) {
                _ = try fm.replaceItemAt(settingsURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: settingsURL)
            }
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }
}
