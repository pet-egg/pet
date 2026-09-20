"""펫 애니메이션 상태 우선순위 로직 (PetAnimationState.swift 포팅).

macOS 앱의 `agentStateAnimation` / `decayStaleStates` / `suppressAcknowledgedDone`
를 파이썬으로 그대로 옮긴 순수 함수 모음. UI·플랫폼 의존이 전혀 없어 그대로
테스트할 수 있다. 값 문자열("working"/"blocked"/"waiting"/"done"/"failed")과
임계치(30분 stale, 30s/5m/15m decay)는 Swift 원본과 바이트 단위로 일치시켰다.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


# 펫이 취할 수 있는 애니메이션 이름 = pet.json 의 animations 키와 1:1.
# (Swift PetAnimationName 의 rawValue 와 동일)
IDLE = "idle"
RUNNING = "running"
WAITING = "waiting"
REVIEW = "review"
JUMPING = "jumping"
WAVING = "waving"
FAILED = "failed"
FIRE_BREATH = "fire-breath"
WATER_GUN = "water-gun"
RUNNING_RIGHT = "running-right"
RUNNING_LEFT = "running-left"


# Freshness gate — 30분 지난 상태는 무시(agent-status-types.ts 포팅).
AGENT_STATUS_STALE_AFTER_MS = 30 * 60 * 1000

# 각 임시 상태가 의미를 갖는 시간. 지나면 한 단계 내려간다.
DECAY_FAILED_MS = 30 * 1000          # failed → done (30초)
DECAY_DONE_MS = 5 * 60 * 1000        # done → idle (5분)
DECAY_WORKING_MS = 15 * 60 * 1000    # working → idle (15분)


@dataclass
class AgentStatusEntry:
    """한 세션(=Claude Code 프로세스)의 상태 스냅샷."""
    pane_key: str
    state: str                       # working | blocked | waiting | done | failed | idle
    updated_at: float                # ms epoch
    working_mode: Optional[str] = None
    worktree_id: Optional[str] = None
    transcript_path: Optional[str] = None


@dataclass
class AnimationResult:
    animation: str
    trace: list = field(default_factory=list)
    gained_tokens: float = 0.0


def decay_stale_states(entries, now):
    """임시 상태를 시간에 따라 한 단계씩 내린다.

    failed → done(30s) → idle(30s+5m), done → idle(5m), working → idle(15m).
    """
    out = []
    for e in entries:
        age = now - e.updated_at
        decayed = None
        if e.state == "failed" and age > DECAY_FAILED_MS + DECAY_DONE_MS:
            decayed = "idle"
        elif e.state == "failed" and age > DECAY_FAILED_MS:
            decayed = "done"
        elif e.state == "done" and age > DECAY_DONE_MS:
            decayed = "idle"
        elif e.state == "working" and age > DECAY_WORKING_MS:
            decayed = "idle"
        if decayed is None:
            out.append(e)
        else:
            out.append(AgentStatusEntry(
                pane_key=e.pane_key, state=decayed, updated_at=e.updated_at,
                working_mode=e.working_mode, worktree_id=e.worktree_id,
                transcript_path=e.transcript_path,
            ))
    return out


def is_entry_fresh(entry, now, stale_after_ms=AGENT_STATUS_STALE_AFTER_MS):
    return now - entry.updated_at <= stale_after_ms


def suppress_acknowledged_done(entries, acknowledged_at_ms):
    """사용자가 이미 확인(호버)한 done 을 idle 로 낮춰 review 가 다시 안 뜨게.

    더 새로운 done(updated_at > acknowledged_at_ms)이 와야 review 가 부활한다.
    """
    out = []
    for e in entries:
        if e.state == "done" and e.updated_at <= acknowledged_at_ms:
            out.append(AgentStatusEntry(
                pane_key=e.pane_key, state="idle", updated_at=e.updated_at,
                working_mode=e.working_mode, worktree_id=e.worktree_id,
                transcript_path=e.transcript_path,
            ))
        else:
            out.append(e)
    return out


def agent_state_animation(entries, retained_count=0, now=0.0,
                          stale_after_ms=AGENT_STATUS_STALE_AFTER_MS):
    """모든 세션을 훑어 가장 급한 상태 하나를 애니메이션으로 고른다.

    우선순위: waiting/blocked(얼음) → failed(실패) → working(서있기) →
    done/retained(하트) → idle(잠듦). blocked/waiting 은 발견 즉시 단락한다.
    """
    trace = []
    has_working = has_done = has_failed = False

    for e in entries:
        if not is_entry_fresh(e, now, stale_after_ms):
            trace.append(f"{e.pane_key}: stale → skipped")
            continue
        if e.state in ("blocked", "waiting"):
            trace.append(f"{e.pane_key}: {e.state} → top-priority, short-circuit")
            return AnimationResult(animation=WAITING, trace=trace)
        if e.state == "failed":
            has_failed = True
            trace.append(f"{e.pane_key}: failed → candidate")
        elif e.state == "working" and e.working_mode != "monitoring":
            has_working = True
            trace.append(f"{e.pane_key}: working → candidate")
        elif e.state == "done":
            has_done = True
            trace.append(f"{e.pane_key}: done → candidate")

    if has_failed:
        return AnimationResult(animation=FAILED, trace=trace)
    if has_working:
        return AnimationResult(animation=RUNNING, trace=trace)
    if has_done or retained_count > 0:
        return AnimationResult(animation=REVIEW, trace=trace)
    return AnimationResult(animation=IDLE, trace=trace)
