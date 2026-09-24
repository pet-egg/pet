"""트랜스크립트 JSONL 토큰 합산 + 증가분(accrual) 계산.

TokenUsage.swift 의 TranscriptTokenReader 포팅. 세션당 누적 토큰은
`input + output + cache_creation`(cache_read 는 제외 — 캐시 히트는 새 작업이
아니므로)로 세고, mtime 캐시로 파일이 안 바뀌면 재계산하지 않는다.
`accrued` 는 마지막 폴링 이후 늘어난 분량만 돌려준다 — 경험치는 지금 화면의
펫에게만 들어가야 하므로 첫 등장 파일은 기준값만 잡고 증가로 세지 않는다.
"""
from __future__ import annotations

import json
import os


class TranscriptTokenReader:
    def __init__(self):
        # path -> (mtime, cumulative_tokens)
        self._cache = {}
        # path -> 마지막으로 본 누적값 (증가분 계산 기준선)
        self._baseline = {}

    def tokens(self, path: str) -> float:
        """트랜스크립트 파일의 누적 토큰. mtime 이 그대로면 캐시 반환."""
        if not path:
            return 0.0
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            # 일시적으로 못 읽으면 마지막 알던 값 유지.
            cached = self._cache.get(path)
            return cached[1] if cached else 0.0

        cached = self._cache.get(path)
        if cached and cached[0] == mtime:
            return cached[1]

        total = 0.0
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except (json.JSONDecodeError, ValueError):
                        continue
                    usage = (((obj or {}).get("message") or {}).get("usage")) or {}
                    total += _num(usage.get("input_tokens"))
                    total += _num(usage.get("output_tokens"))
                    total += _num(usage.get("cache_creation_input_tokens"))
                    # cache_read_input_tokens 는 일부러 제외.
        except OSError:
            cached = self._cache.get(path)
            return cached[1] if cached else 0.0

        self._cache[path] = (mtime, total)
        return total

    def accrued(self, entries) -> float:
        """마지막 폴링 이후 늘어난 토큰의 합(증가분).

        각 트랜스크립트 경로별로 이번 누적값과 기준선을 비교해 증가분만 더한다.
        처음 보는 경로는 기준선만 등록(앱 재시작/펫 전환 시 옛 토큰이 새 펫에게
        쏟아지지 않게).
        """
        paths = []
        seen = set()
        for e in entries:
            p = getattr(e, "transcript_path", None)
            if p and p not in seen:
                seen.add(p)
                paths.append(p)

        gained = 0.0
        for p in paths:
            now = self.tokens(p)
            if p in self._baseline:
                if now > self._baseline[p]:
                    gained += now - self._baseline[p]
            self._baseline[p] = now
        return gained


def _num(v) -> float:
    try:
        return float(v) if v is not None else 0.0
    except (TypeError, ValueError):
        return 0.0
