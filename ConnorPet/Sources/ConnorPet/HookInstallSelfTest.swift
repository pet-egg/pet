import Foundation

/// Headless test for the Claude Code hook installer, run via
/// `CONNORPET_SELFTEST=hooks swift run`. Points `ClaudeHookInstaller` at a
/// throwaway home (via CONNORPET_HOOK_HOME) seeded with a realistic
/// settings.json — the caller's real ~/.claude/settings.json if present, so we
/// exercise the merge against actual foreign hooks — then asserts:
///
///   • install() adds our two events (Stop/SessionEnd) and migrates away a
///     legacy connor-pet entry (claude_hook_status.py), converging to exactly
///     two entries; a second install stays at two (no duplication),
///   • every pre-existing foreign hook survives untouched,
///   • uninstall() removes exactly our entries and restores the original doc.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runHookInstallSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let fm = FileManager.default
    let tmpHome = fm.temporaryDirectory
        .appendingPathComponent("connorpet-hooktest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    let claudeDir = tmpHome.appendingPathComponent(".claude", isDirectory: true)
    let settingsURL = claudeDir.appendingPathComponent("settings.json")
    try? fm.removeItem(at: tmpHome)
    try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

    // Seed with the real settings.json when available (best coverage — real
    // foreign hooks), otherwise a small hand-built doc with a matcher-scoped
    // block we must not merge into.
    let realSettings = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    let seed: Data
    if let real = try? Data(contentsOf: realSettings), !real.isEmpty {
        // Strip any connor-pet entries already present so we test a clean install.
        seed = stripConnorPetEntries(from: real) ?? real
        print("[selftest] seeded from real ~/.claude/settings.json")
    } else {
        let doc: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "echo foreign"]]]
                ]
            ],
        ]
        seed = try! JSONSerialization.data(withJSONObject: doc)
        print("[selftest] seeded from synthetic settings.json")
    }
    try! seed.write(to: settingsURL)

    setenv("CONNORPET_HOOK_HOME", tmpHome.path, 1)

    func loadHooks() -> [String: Any] {
        let data = (try? Data(contentsOf: settingsURL)) ?? Data()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return obj["hooks"] as? [String: Any] ?? [:]
    }

    func foreignEntryCount(_ hooks: [String: Any]) -> Int {
        var n = 0
        for (_, blocks) in hooks {
            for block in (blocks as? [[String: Any]] ?? []) {
                for hk in (block["hooks"] as? [[String: Any]] ?? []) {
                    if !isPetCommand(hk["command"] as? String ?? "") { n += 1 }
                }
            }
        }
        return n
    }

    let before = loadHooks()
    let foreignBefore = foreignEntryCount(before)

    if ClaudeHookInstaller.isInstalled() { fail("reports installed before any install") }

    // Simulate a legacy six-hook install (claude_hook_status.py) to prove
    // install() detects and migrates it away.
    if var doc = (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: settingsURL)) ?? Data())) as? [String: Any] {
        var hooks = doc["hooks"] as? [String: Any] ?? [:]
        var blocks = hooks["Notification"] as? [[String: Any]] ?? []
        blocks.append(["hooks": [["type": "command", "command": "python3 /old/claude_hook_status.py blocked"]]])
        hooks["Notification"] = blocks
        doc["hooks"] = hooks
        try! JSONSerialization.data(withJSONObject: doc).write(to: settingsURL)
    }
    if !ClaudeHookInstaller.isInstalled() { fail("legacy connor-pet entry not detected as installed") }

    // First install.
    let added: [String]
    do { added = try ClaudeHookInstaller.install() }
    catch { fail("install threw: \(error)") }
    if !ClaudeHookInstaller.isInstalled() { fail("not installed after install()") }
    if Set(added) != Set(["Stop", "SessionEnd"]) {
        fail("install added unexpected set: \(added)")
    }
    // The legacy entry must be gone after migration.
    if hasLegacyEntry(loadHooks()) { fail("legacy claude_hook_status.py entry survived install()") }

    // The bundled script must have been copied out.
    let script = tmpHome.appendingPathComponent(".claude/pet/pet_hook_status.py")
    if !fm.fileExists(atPath: script.path) { fail("bundled hook script not copied to \(script.path)") }

    // Idempotency: a second install converges to the same set (it purges then
    // re-adds), and — verified by the count check below — never duplicates.
    let addedAgain = (try? ClaudeHookInstaller.install()) ?? ["ERR"]
    if Set(addedAgain) != Set(["Stop", "SessionEnd"]) { fail("second install changed the set: \(addedAgain)") }

    let afterInstall = loadHooks()
    if foreignEntryCount(afterInstall) != foreignBefore {
        fail("foreign hook entries changed on install: \(foreignBefore) -> \(foreignEntryCount(afterInstall))")
    }
    // Exactly two of our entries, no more (migration + idempotency: the legacy
    // entry was folded in, not stacked on top).
    let ourCount = countOurEntries(afterInstall)
    if ourCount != 2 { fail("expected 2 pet entries after install, got \(ourCount)") }

    // Uninstall restores the doc.
    do { _ = try ClaudeHookInstaller.uninstall() }
    catch { fail("uninstall threw: \(error)") }
    if ClaudeHookInstaller.isInstalled() { fail("still installed after uninstall()") }
    let afterUninstall = loadHooks()
    if foreignEntryCount(afterUninstall) != foreignBefore {
        fail("foreign hook entries changed on uninstall: \(foreignBefore) -> \(foreignEntryCount(afterUninstall))")
    }
    if countOurEntries(afterUninstall) != 0 { fail("connor-pet entries remain after uninstall") }

    try? fm.removeItem(at: tmpHome)
    print("[selftest] foreign entries preserved: \(foreignBefore); install/idempotent/uninstall OK")
    print("SELFTEST PASS")
    exit(0)
}

/// Our entries are recognized by either handler filename — matching
/// `ClaudeHookInstaller.isPetEntry` / the Python installer's `is_pet_entry`.
private func isPetCommand(_ cmd: String) -> Bool {
    cmd.contains("pet_hook_status.py") || cmd.contains("claude_hook_status.py")
}

private func hasLegacyEntry(_ hooks: [String: Any]) -> Bool {
    for (_, blocks) in hooks {
        for block in (blocks as? [[String: Any]] ?? []) {
            for hk in (block["hooks"] as? [[String: Any]] ?? []) {
                if (hk["command"] as? String ?? "").contains("claude_hook_status.py") { return true }
            }
        }
    }
    return false
}

private func countOurEntries(_ hooks: [String: Any]) -> Int {
    var n = 0
    for (_, blocks) in hooks {
        for block in (blocks as? [[String: Any]] ?? []) {
            for hk in (block["hooks"] as? [[String: Any]] ?? []) {
                if isPetCommand(hk["command"] as? String ?? "") { n += 1 }
            }
        }
    }
    return n
}

/// Removes connor-pet entries from a raw settings.json Data, dropping blocks and
/// events that become empty — so the self-test always starts from a clean slate
/// even if the seeding file already had our hooks installed.
private func stripConnorPetEntries(from data: Data) -> Data? {
    guard var doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          var hooks = doc["hooks"] as? [String: Any] else { return nil }
    for event in Array(hooks.keys) {
        guard let blocks = hooks[event] as? [[String: Any]] else { continue }
        var kept: [[String: Any]] = []
        for var block in blocks {
            let entries = block["hooks"] as? [[String: Any]] ?? []
            let filtered = entries.filter { !isPetCommand($0["command"] as? String ?? "") }
            if filtered.isEmpty { continue }
            block["hooks"] = filtered
            kept.append(block)
        }
        if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
    }
    doc["hooks"] = hooks
    return try? JSONSerialization.data(withJSONObject: doc)
}
