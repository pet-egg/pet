"""토큰 → 경험치%/진화단계 매핑 (TokenUsage.swift 의 XPModel 포팅).

임계치는 Swift 원본과 동일: stage 1 = 2억 토큰, stage 2 = 5억 토큰.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

STAGE_TOKENS = [200_000_000, 500_000_000]


@dataclass
class Progress:
    percent: float          # 0.0 ~ 1.0 (다음 진화까지)
    tokens: float
    target: Optional[float]  # 다음 임계치, 최종 단계면 None


def stage(tokens: float) -> int:
    """진화 단계 (0=기본형, 1=1차, 2=2차)."""
    return sum(1 for t in STAGE_TOKENS if tokens >= t)


def progress(tokens: float) -> Progress:
    """경험치 바 채움. 다음 진화 임계치에 정규화한 0~1."""
    target = next((t for t in STAGE_TOKENS if tokens < t), None)
    if target is None:
        return Progress(percent=1.0, tokens=tokens, target=None)
    pct = max(0.0, min(1.0, tokens / target))
    return Progress(percent=pct, tokens=tokens, target=target)


MAX_TOKENS = STAGE_TOKENS[-1]
