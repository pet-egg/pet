#!/usr/bin/env python3
"""
Injects/clears synthetic entries in Orca's real last-status.json so you can
watch ConnorPet react without needing an actual Orca agent running.

Every entry this script writes is keyed under a "connor-pet-test:" prefix, so
it can never collide with or clobber a real Orca pane (those are UUIDs) —
`clear-all` only ever removes connor-pet-test:* keys, real entries are left
untouched. Orca itself only rewrites this file when a real hook event fires,
so an injected entry is safe to leave in place for as long as you want to
watch it, as long as no real agent activity happens in the meantime.

Usage:
  python3 tooling/scripts/simulate_agent.py set <pane-name> <working|blocked|waiting|done>
  python3 tooling/scripts/simulate_agent.py clear <pane-name>
  python3 tooling/scripts/simulate_agent.py clear-all
  python3 tooling/scripts/simulate_agent.py list

Examples (matches ConnorPet's precedence: waiting > working > done > idle):
  python3 tooling/scripts/simulate_agent.py set web-app working
  python3 tooling/scripts/simulate_agent.py set api-server blocked   # pet should flip to "waiting"
  python3 tooling/scripts/simulate_agent.py clear api-server         # back to "running"
  python3 tooling/scripts/simulate_agent.py clear-all                # back to "idle"
"""
import json
import os
import sys
import time
import uuid

STATUS_PATH = os.path.expanduser("~/Library/Application Support/Orca/agent-hooks/last-status.json")
VALID_STATES = {"working", "blocked", "waiting", "done"}
PREFIX = "connor-pet-test:"


def load():
    if not os.path.exists(STATUS_PATH):
        return {"version": 2, "entries": {}, "authorityCommitments": {}}
    with open(STATUS_PATH) as f:
        return json.load(f)


def save(data):
    os.makedirs(os.path.dirname(STATUS_PATH), exist_ok=True)
    tmp_path = f"{STATUS_PATH}.connor-pet-test-{uuid.uuid4().hex}.tmp"
    with open(tmp_path, "w") as f:
        json.dump(data, f)
    os.replace(tmp_path, STATUS_PATH)  # atomic, same pattern Orca's own writer uses


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return

    cmd = args[0]
    data = load()
    entries = data.setdefault("entries", {})

    if cmd == "set":
        if len(args) != 3 or args[2] not in VALID_STATES:
            print(f"usage: set <pane-name> <{'|'.join(sorted(VALID_STATES))}>")
            return
        pane_name, state = args[1], args[2]
        key = PREFIX + pane_name
        entries[key] = {
            "state": state,
            "worktreeId": pane_name,
            "receivedAt": int(time.time() * 1000),
            "stateStartedAt": int(time.time() * 1000),
        }
        save(data)
        print(f"set {pane_name!r} -> {state}")

    elif cmd == "clear":
        if len(args) != 2:
            print("usage: clear <pane-name>")
            return
        key = PREFIX + args[1]
        if entries.pop(key, None) is not None:
            save(data)
            print(f"cleared {args[1]!r}")
        else:
            print(f"no test entry named {args[1]!r}")

    elif cmd == "clear-all":
        removed = [k for k in list(entries) if k.startswith(PREFIX)]
        for k in removed:
            del entries[k]
        save(data)
        print(f"cleared {len(removed)} test entr{'y' if len(removed) == 1 else 'ies'}")

    elif cmd == "list":
        test_entries = {k[len(PREFIX):]: v for k, v in entries.items() if k.startswith(PREFIX)}
        print(json.dumps(test_entries, indent=2))

    else:
        print(__doc__)


if __name__ == "__main__":
    main()
