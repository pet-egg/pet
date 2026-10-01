"""펫 성별 — 포켓몬 본가 성비(gender rate)로 부화 시 한 번만 배정.

macOS `PetGender.swift` 포팅. 수컷 ♂(파랑)/암컷 ♀(분홍), 메타몽은 무성(기호 없음).
배정 결과는 **기본형 slug 기준**으로 저장한다(진화해도 같은 성별 — 이름과 같은 규칙).
경험치(petTokens)와 별도 키라, 업데이트해도 경험치는 그대로 유지되고 성별만 새로 배정된다.
"""
from __future__ import annotations

import random

MALE = "male"
FEMALE = "female"
GENDERLESS = "genderless"

# 암컷 확률(8분위, PokeAPI gender_rate 표기). -1 = 무성. 기본형 slug 기준.
# 스타터·단일계열 = 1/8, 데구리/팬텀/디그다/피카츄/애버라스/미뇽 계열 = 4/8,
# 메타몽 = 무성, 비숑(포켓몬 아님)은 50:50.
FEMALE_RATE_BY_BASE = {
    "totodile": 1,
    "charmander": 1,
    "squirtle": 1,
    "eevee": 1,
    "chikorita": 1,
    "torchic": 1,
    "togepi": 1,
    "tepig": 1,
    "snorlax": 1,
    "geodude": 4,
    "gengar": 4,
    "diglett": 4,
    "pikachu": 4,
    "larvitar": 4,
    "dratini": 4,
    "ditto": -1,
    "bichon": 4,
    "pinkbean": -1,  # 유일 초월자(메이플) — 무성(메타몽과 같게)
}

# 기호와 색(RGB). 색칠은 app.py 가 QColor 로 한다.
SYMBOL = {MALE: "♂", FEMALE: "♀", GENDERLESS: None}
COLOR_RGB = {MALE: (66, 143, 255), FEMALE: (255, 107, 179)}


def female_rate(base: str) -> int:
    """모르는 펫은 50:50(표에 빠져도 무성이 되진 않게)."""
    return FEMALE_RATE_BY_BASE.get(base, 4)


def roll(base: str, rng=None) -> str:
    """확률에 따라 성별 하나를 뽑는다(저장 안 함). rng 는 0..7 정수를 주는 함수."""
    rate = female_rate(base)
    if rate < 0:
        return GENDERLESS
    draw = rng() if rng is not None else random.randrange(8)
    return FEMALE if draw < rate else MALE


def symbol(gender: str):
    return SYMBOL.get(gender)
