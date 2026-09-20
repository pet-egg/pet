"""크로스플랫폼 로직 테스트 — Mac·Windows(CI) 어디서든 headless 로 돈다.

애니메이션 우선순위/decay, XP 모델, 토큰 accrual, 세션파일 파싱을 검증한다.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pet_win import animation as anim  # noqa: E402
from pet_win import petmeta, xpmodel   # noqa: E402
from pet_win.tokenusage import TranscriptTokenReader  # noqa: E402


NOW = 1_000_000_000_000.0


def _entry(state, age_ms=0, working_mode=None, transcript=None):
    return anim.AgentStatusEntry(
        pane_key=f"s:{state}", state=state, updated_at=NOW - age_ms,
        working_mode=working_mode, transcript_path=transcript)


# ── 애니메이션 우선순위 ────────────────────────────────────────
def test_priority_waiting_wins():
    r = anim.agent_state_animation(
        [_entry("working"), _entry("waiting"), _entry("done")], now=NOW)
    assert r.animation == anim.WAITING


def test_priority_failed_over_working():
    r = anim.agent_state_animation([_entry("working"), _entry("failed")], now=NOW)
    assert r.animation == anim.FAILED


def test_priority_working_over_done():
    r = anim.agent_state_animation([_entry("done"), _entry("working")], now=NOW)
    assert r.animation == anim.RUNNING


def test_done_is_review():
    assert anim.agent_state_animation([_entry("done")], now=NOW).animation == anim.REVIEW


def test_idle_default():
    assert anim.agent_state_animation([], now=NOW).animation == anim.IDLE


def test_monitoring_working_not_running():
    r = anim.agent_state_animation(
        [_entry("working", working_mode="monitoring")], now=NOW)
    assert r.animation == anim.IDLE


def test_stale_entry_skipped():
    r = anim.agent_state_animation(
        [_entry("working", age_ms=31 * 60 * 1000)], now=NOW)
    assert r.animation == anim.IDLE


# ── decay ──────────────────────────────────────────────────────
def test_decay_failed_to_done():
    out = anim.decay_stale_states([_entry("failed", age_ms=40_000)], NOW)
    assert out[0].state == "done"


def test_decay_failed_to_idle():
    out = anim.decay_stale_states(
        [_entry("failed", age_ms=40_000 + 6 * 60 * 1000)], NOW)
    assert out[0].state == "idle"


def test_decay_done_to_idle():
    out = anim.decay_stale_states([_entry("done", age_ms=6 * 60 * 1000)], NOW)
    assert out[0].state == "idle"


def test_decay_working_to_idle():
    out = anim.decay_stale_states([_entry("working", age_ms=16 * 60 * 1000)], NOW)
    assert out[0].state == "idle"


def test_suppress_acknowledged_done():
    e = _entry("done", age_ms=1000)
    out = anim.suppress_acknowledged_done([e], acknowledged_at_ms=NOW)
    assert out[0].state == "idle"
    # 더 새로운 done 은 살아남는다.
    e2 = anim.AgentStatusEntry(pane_key="x", state="done", updated_at=NOW + 5000)
    out2 = anim.suppress_acknowledged_done([e2], acknowledged_at_ms=NOW)
    assert out2[0].state == "done"


# ── XP 모델 ────────────────────────────────────────────────────
def test_xp_stage():
    assert xpmodel.stage(0) == 0
    assert xpmodel.stage(199_000_000) == 0
    assert xpmodel.stage(200_000_000) == 1
    assert xpmodel.stage(500_000_000) == 2
    assert xpmodel.stage(999_000_000) == 2


def test_xp_progress():
    p = xpmodel.progress(100_000_000)
    assert abs(p.percent - 0.5) < 1e-9
    assert p.target == 200_000_000
    p2 = xpmodel.progress(600_000_000)
    assert p2.percent == 1.0 and p2.target is None


# ── 진화 사슬 ──────────────────────────────────────────────────
def test_display_slug():
    assert petmeta.display_slug("totodile", 0) == "totodile"
    assert petmeta.display_slug("totodile", 1) == "croconaw"
    assert petmeta.display_slug("totodile", 2) == "feraligatr"
    assert petmeta.display_slug("totodile", 5) == "feraligatr"  # clamp
    assert petmeta.display_slug("ditto", 2) == "ditto"          # 진화 없음
    assert petmeta.display_slug("eevee", 2) == "vaporeon"       # 1단계뿐 → clamp


# ── 토큰 accrual ───────────────────────────────────────────────
def _write_jsonl(path, turns):
    with open(path, "w", encoding="utf-8") as f:
        for (inp, out, cc, cr) in turns:
            f.write(json.dumps({"message": {"usage": {
                "input_tokens": inp, "output_tokens": out,
                "cache_creation_input_tokens": cc,
                "cache_read_input_tokens": cr}}}) + "\n")


def test_token_reader_excludes_cache_read(tmp_path):
    p = str(tmp_path / "t.jsonl")
    _write_jsonl(p, [(100, 50, 10, 9999)])
    r = TranscriptTokenReader()
    assert r.tokens(p) == 160  # cache_read(9999) 제외


def test_token_accrual_first_sight_zero(tmp_path):
    p = str(tmp_path / "t.jsonl")
    _write_jsonl(p, [(100, 50, 10, 0)])
    r = TranscriptTokenReader()
    e = [anim.AgentStatusEntry(pane_key="x", state="idle", updated_at=NOW,
                               transcript_path=p)]
    assert r.accrued(e) == 0  # 처음 보는 파일은 기준선만
    # 파일이 커지면 증가분만 계산.
    time.sleep(0.01)
    _write_jsonl(p, [(100, 50, 10, 0), (200, 100, 0, 0)])
    assert r.accrued(e) == 300


if __name__ == "__main__":
    import pytest
    raise SystemExit(pytest.main([__file__, "-v"]))
