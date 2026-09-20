"""Claude Code 상태 워처 (ClaudeCodeStatusWatcher.swift 포팅).

`~/.claude/sessions/<pid>.json`(권위 소스) + `~/.claude/pet-status.json`(훅 오버레이,
선택)을 폴링해 펫 애니메이션을 정한다. 세션 status(busy→working / waiting→blocked /
그 외→idle)가 달리기·얼음·잠듦을, busy→idle 전이(Stop 엣지)가 done/failed(헤롱헤롱/실패)를
만든다 — 훅 없이도 워처가 직접 감지한다. Orca(macOS 전용)가 띄운 세션은 제외한다.

플랫폼 의존은 pid_alive() 하나뿐이라 로직 전체를 어디서든 테스트할 수 있다.
"""
from __future__ import annotations

import glob
import json
import os
import sys
import time

from . import animation as anim
from .tokenusage import TranscriptTokenReader


def _home() -> str:
    return os.path.expanduser("~")


def claude_dir() -> str:
    return os.path.join(_home(), ".claude")


def pid_alive(pid: int) -> bool:
    """프로세스가 살아 있는지 — 죽은 세션파일을 빨리 버리기 위함.

    POSIX 는 kill(pid, 0), Windows 는 OpenProcess 로 확인한다.
    """
    if pid <= 0:
        return False
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            return False
        try:
            code = wintypes.DWORD()
            if kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return code.value == STILL_ACTIVE
            return True  # 핸들은 열렸으니 존재는 함
        finally:
            kernel32.CloseHandle(handle)
    else:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True  # 존재하지만 우리 소유가 아님
        except OSError:
            return False


class ClaudeCodeStatusWatcher:
    def __init__(self):
        self._token_reader = TranscriptTokenReader()
        self._transcript_path_cache = {}      # sessionId -> jsonl path
        self._last_busy_idle = {}             # sessionId -> "working"|"blocked"|"idle"
        self._completion = {}                 # sessionId -> (state, at_ms)
        self._orca_seen_ids = set()           # Orca 가 관리한다고 본 sessionId 누적
        self._acknowledged_at_ms = 0.0

    # ── 공개 API ────────────────────────────────────────────────
    def poll(self) -> anim.AnimationResult:
        """한 번 폴링해 애니메이션 결과를 계산한다."""
        now = time.time() * 1000.0
        sessions = self._read_sessions()
        hook_entries = self._read_hook_entries()
        orca_ids = self._read_orca_managed_ids()
        self._orca_seen_ids |= orca_ids
        # 사라진 세션의 Orca id 는 정리.
        self._orca_seen_ids &= set(sessions.keys()) | orca_ids

        entries = []
        for sid, s in sessions.items():
            if sid in self._orca_seen_ids:
                continue  # Orca 소스가 담당 → 이중집계 방지
            transcript = self._transcript_path(sid)

            # busy→idle 엣지 감지 → done/failed 각인.
            prev = self._last_busy_idle.get(sid)
            if s["busy_idle"] in ("working", "blocked"):
                self._completion.pop(sid, None)
            elif s["busy_idle"] == "idle" and prev == "working":
                errored = self._last_tool_errored(transcript)
                self._completion[sid] = ("failed" if errored else "done", now)
            self._last_busy_idle[sid] = s["busy_idle"]

            state = s["busy_idle"]
            updated_at = s["updated_at"]
            if s["busy_idle"] == "idle":
                hook = hook_entries.get(sid)
                if hook and hook["state"] in ("done", "failed"):
                    state = hook["state"]
                    updated_at = hook["updated_at"]
                elif sid in self._completion:
                    st, at = self._completion[sid]
                    state, updated_at = st, at

            entries.append(anim.AgentStatusEntry(
                pane_key=f"claude-code:{s['name'] or sid}",
                state=state,
                updated_at=updated_at,
                worktree_id=s["cwd"],
                transcript_path=transcript,
            ))

        decayed = anim.decay_stale_states(entries, now)
        suppressed = anim.suppress_acknowledged_done(decayed, self._acknowledged_at_ms)
        result = anim.agent_state_animation(suppressed, retained_count=0, now=now)
        result.gained_tokens = self._token_reader.accrued(entries)
        return result

    def acknowledge_done(self):
        """호버로 헤롱헤롱을 확인 — 더 새로운 done 이 올 때까지 review 억제."""
        self._acknowledged_at_ms = time.time() * 1000.0

    # ── 파일 읽기 ────────────────────────────────────────────────
    def _read_sessions(self):
        out = {}
        pattern = os.path.join(claude_dir(), "sessions", "*.json")
        for path in glob.glob(pattern):
            parsed = self._parse_session_file(path)
            if parsed:
                out[parsed[0]] = parsed[1]
        return out

    def _parse_session_file(self, path):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                root = json.load(f)
        except (OSError, ValueError):
            return None
        if not isinstance(root, dict):
            return None
        sid = root.get("sessionId")
        pid = root.get("pid")
        if not isinstance(sid, str) or not isinstance(pid, (int, float)):
            return None
        if not pid_alive(int(pid)):
            return None

        status = root.get("status")
        if status == "busy":
            busy_idle = "working"
        elif status == "waiting":
            busy_idle = "blocked"
        else:
            busy_idle = "idle"

        updated_at = root.get("statusUpdatedAt")
        if not isinstance(updated_at, (int, float)):
            updated_at = root.get("updatedAt")
        if not isinstance(updated_at, (int, float)):
            updated_at = time.time() * 1000.0

        return sid, {
            "name": root.get("name"),
            "cwd": root.get("cwd"),
            "busy_idle": busy_idle,
            "updated_at": float(updated_at),
        }

    def _read_hook_entries(self):
        """~/.claude/pet-status.json 오버레이(선택). sessionId -> {state, updated_at}."""
        path = os.path.join(claude_dir(), "pet-status.json")
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                root = json.load(f)
        except (OSError, ValueError):
            return {}
        out = {}
        entries = (root or {}).get("entries") or {}
        if not isinstance(entries, dict):
            return {}
        for key, entry in entries.items():
            if not isinstance(entry, dict):
                continue
            sid = (((entry.get("providerSession") or {}).get("id")) or key)
            state = entry.get("state")
            updated_at = entry.get("updatedAt")
            if not isinstance(updated_at, (int, float)):
                updated_at = entry.get("receivedAt")
            if not isinstance(updated_at, (int, float)):
                updated_at = time.time() * 1000.0
            if isinstance(state, str):
                out[sid] = {"state": state, "updated_at": float(updated_at)}
        return out

    def _read_orca_managed_ids(self):
        """Orca(macOS)의 last-status.json 에서 관리 중인 sessionId 집합.

        Windows·Orca 미설치면 파일이 없어 빈 집합 → 아무것도 제외 안 함.
        """
        candidates = [
            os.path.join(_home(), "Library", "Application Support", "Orca",
                         "agent-hooks", "last-status.json"),
        ]
        ids = set()
        for path in candidates:
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    root = json.load(f)
            except (OSError, ValueError):
                continue
            entries = (root or {}).get("entries") or {}
            if isinstance(entries, dict):
                for entry in entries.values():
                    if isinstance(entry, dict):
                        sid = ((entry.get("providerSession") or {}).get("id"))
                        if isinstance(sid, str):
                            ids.add(sid)
        return ids

    # ── 트랜스크립트 ─────────────────────────────────────────────
    def _transcript_path(self, session_id: str):
        """~/.claude/projects/**/<sessionId>.jsonl 를 글롭으로 찾아 캐시."""
        if session_id in self._transcript_path_cache:
            return self._transcript_path_cache[session_id]
        pattern = os.path.join(claude_dir(), "projects", "**", f"{session_id}.jsonl")
        matches = glob.glob(pattern, recursive=True)
        if matches:
            self._transcript_path_cache[session_id] = matches[0]
            return matches[0]
        return None

    def _last_tool_errored(self, transcript_path) -> bool:
        """트랜스크립트 꼬리의 마지막 tool_result 가 에러인지."""
        if not transcript_path:
            return False
        try:
            with open(transcript_path, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                start = max(0, size - 256 * 1024)
                f.seek(start)
                tail = f.read().decode("utf-8", errors="replace")
        except OSError:
            return False
        lines = [ln for ln in tail.split("\n") if ln.strip()]
        if start > 0 and lines:
            lines = lines[1:]  # 첫 줄은 잘렸을 수 있음
        if len(lines) > 80:
            lines = lines[-80:]
        for raw in reversed(lines):
            try:
                obj = json.loads(raw)
            except (json.JSONDecodeError, ValueError):
                continue
            content = (((obj or {}).get("message") or {}).get("content"))
            if not isinstance(content, list):
                continue
            for block in reversed(content):
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    return bool(block.get("is_error", False))
        return False
