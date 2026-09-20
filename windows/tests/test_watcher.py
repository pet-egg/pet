"""상태 워처의 파일 파싱·엣지 감지 검증 (임시 HOME 을 시드).

pid_alive 는 현재 프로세스(os.getpid())로 확실히 살아 있는 세션을 만든다.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pet_win import animation as anim  # noqa: E402
from pet_win import status_watcher as sw  # noqa: E402


def _seed_session(home, name, status, session_id="sess-1"):
    sess_dir = os.path.join(home, ".claude", "sessions")
    os.makedirs(sess_dir, exist_ok=True)
    with open(os.path.join(sess_dir, f"{os.getpid()}.json"), "w") as f:
        json.dump({
            "sessionId": session_id, "pid": os.getpid(), "status": status,
            "name": name, "cwd": "/tmp/x",
            "statusUpdatedAt": 9_999_999_999_999,
        }, f)


def _watcher_with_home(monkeypatch, home):
    monkeypatch.setattr(sw, "_home", lambda: home)
    return sw.ClaudeCodeStatusWatcher()


def test_busy_maps_to_running(tmp_path, monkeypatch):
    home = str(tmp_path)
    _seed_session(home, "web", "busy")
    w = _watcher_with_home(monkeypatch, home)
    assert w.poll().animation == anim.RUNNING


def test_waiting_maps_to_frozen(tmp_path, monkeypatch):
    home = str(tmp_path)
    _seed_session(home, "web", "waiting")
    w = _watcher_with_home(monkeypatch, home)
    assert w.poll().animation == anim.WAITING


def test_idle_is_sleep(tmp_path, monkeypatch):
    home = str(tmp_path)
    _seed_session(home, "web", "idle")
    w = _watcher_with_home(monkeypatch, home)
    assert w.poll().animation == anim.IDLE


def test_busy_then_idle_makes_done(tmp_path, monkeypatch):
    home = str(tmp_path)
    w = _watcher_with_home(monkeypatch, home)
    _seed_session(home, "web", "busy")
    assert w.poll().animation == anim.RUNNING
    _seed_session(home, "web", "idle")   # busy→idle 엣지
    assert w.poll().animation == anim.REVIEW  # done → 하트


def test_dead_pid_session_ignored(tmp_path, monkeypatch):
    home = str(tmp_path)
    sess_dir = os.path.join(home, ".claude", "sessions")
    os.makedirs(sess_dir, exist_ok=True)
    with open(os.path.join(sess_dir, "999999.json"), "w") as f:
        json.dump({"sessionId": "dead", "pid": 2_000_000_000,
                   "status": "busy", "name": "z"}, f)
    w = _watcher_with_home(monkeypatch, home)
    assert w.poll().animation == anim.IDLE  # 죽은 pid → 무시


if __name__ == "__main__":
    import pytest
    raise SystemExit(pytest.main([__file__, "-v"]))
