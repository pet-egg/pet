#!/usr/bin/env python3
"""
Installs the connor-pet Claude Code hooks into ~/.claude/settings.json (see
README.md "Claude Code 훅으로 헤롱헤롱/실패까지 보기"). This is the scripted
equivalent of pasting the JSON snippet in by hand — it merges into whatever
hooks are already there instead of clobbering them, resolves the path to
`pet_hook_status.py` from this script's own location (so it works regardless of
where the repo is cloned), and is safe to re-run (each run converges to exactly
our current set).

Working/blocked/idle now come straight from Claude Code's own
~/.claude/sessions/<pid>.json (see ClaudeCodeStatusWatcher.swift), so only two
hooks remain — the states that file can't express: Stop (턴 종료 → 헤롱헤롱/리뷰
대기, 마지막 툴이 에러면 실패) and SessionEnd (정리). Older installs of ours wired
six events (UserPromptSubmit/PreToolUse/Notification/PermissionRequest/Stop/
SessionEnd) — re-running install migrates those down to the two automatically.

This touches a *global* file that affects every Claude Code session on this
machine, not just this project — it does nothing until you run it yourself.

Usage:
  python3 scripts/install_claude_hooks.py            # install (or migrate)
  python3 scripts/install_claude_hooks.py --uninstall # remove connor-pet's entries
"""
import json
import os
import shutil
import sys
import time

SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
HERE = os.path.dirname(os.path.abspath(__file__))
HOOK_SCRIPT = os.path.join(HERE, "pet_hook_status.py")

# event -> state argument passed to pet_hook_status.py
HOOK_EVENTS = {
    "Stop": "done",
    "SessionEnd": "remove",
}


def command_for(state):
    return f"python3 {HOOK_SCRIPT} {state}"


def is_pet_entry(hook):
    # Recognize both the current handler name and the legacy connor-pet one, so a
    # re-run cleanly migrates an old six-hook install (and either installer path
    # can remove what the other added).
    cmd = hook.get("command")
    return (
        hook.get("type") == "command"
        and isinstance(cmd, str)
        and ("pet_hook_status.py" in cmd or "claude_hook_status.py" in cmd)
    )


def remove_pet_entries(hooks):
    """Strip every entry we own from all events, dropping blocks (and events)
    that become empty as a result. Returns the sorted list of events touched."""
    removed = []
    for event in list(hooks.keys()):
        blocks = hooks[event]
        remaining_blocks = []
        for block in blocks:
            block_hooks = block.get("hooks", [])
            kept = [h for h in block_hooks if not is_pet_entry(h)]
            if len(kept) != len(block_hooks):
                removed.append(event)
                block["hooks"] = kept
                if not kept:
                    continue  # a block we created solely for our hook — drop it
            remaining_blocks.append(block)
        hooks[event] = remaining_blocks
        if not hooks[event]:
            del hooks[event]
    return sorted(set(removed))


def load_settings():
    if not os.path.exists(SETTINGS_PATH):
        return {}
    with open(SETTINGS_PATH) as f:
        return json.load(f)


def save_settings(settings):
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    if os.path.exists(SETTINGS_PATH):
        backup_path = SETTINGS_PATH + f".pet-backup.{int(time.time())}"
        shutil.copy2(SETTINGS_PATH, backup_path)
        print(f"backed up existing settings to {backup_path}")
    tmp_path = SETTINGS_PATH + f".tmp.{os.getpid()}"
    with open(tmp_path, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, SETTINGS_PATH)


def install():
    settings = load_settings()
    hooks = settings.setdefault("hooks", {})

    # Clear any prior entries of ours first (a legacy six-hook install, or a
    # previous run) so we always converge to exactly HOOK_EVENTS and never
    # duplicate. This is what makes re-running safe and migrating automatic.
    migrated = remove_pet_entries(hooks)

    added = []
    for event, state in HOOK_EVENTS.items():
        # Always add our own dedicated block (never merge into a matcher-scoped
        # one, which would silently narrow when our hook fires).
        hooks.setdefault(event, []).append(
            {"hooks": [{"type": "command", "command": command_for(state)}]}
        )
        added.append(event)

    save_settings(settings)

    stale = sorted(set(migrated) - set(added))
    if stale:
        print(f"migrated (removed now-unneeded hooks): {', '.join(stale)}")
    print(f"installed hooks for: {', '.join(sorted(added))}")
    print(f"wrote {SETTINGS_PATH}")


def uninstall():
    settings = load_settings()
    hooks = settings.get("hooks", {})
    removed = remove_pet_entries(hooks)
    save_settings(settings)
    if removed:
        print(f"removed connor-pet hooks from: {', '.join(removed)}")
    else:
        print("no connor-pet hooks were installed")


def main():
    if "--uninstall" in sys.argv[1:]:
        uninstall()
    else:
        install()


if __name__ == "__main__":
    main()
