"""펫 메타데이터 — 선택 가능한 슬러그, 진화 사슬, 표시형 계산.

AppDelegate.swift 의 availablePetSlugs / evolutionChains / displaySlug 포팅.
"""
from __future__ import annotations

# 메뉴/트레이에서 고를 수 있는 펫(기본형). Swift availablePetSlugs 와 동일 순서.
AVAILABLE_PET_SLUGS = [
    "totodile", "ditto", "charmander", "squirtle", "geodude", "eevee",
    "chikorita", "torchic", "togepi", "tepig", "snorlax", "gengar",
    "diglett", "pikachu", "larvitar", "dratini", "bichon",
]

# 기본형 → 진화형 목록(1차, 2차). 빈 배열이면 진화 없음.
EVOLUTION_CHAINS = {
    "totodile": ["croconaw", "feraligatr"],
    "charmander": ["charmeleon", "charizard"],
    "squirtle": ["wartortle", "blastoise"],
    "geodude": ["graveler", "golem"],
    "chikorita": ["bayleef", "meganium"],
    "torchic": ["combusken", "blaziken"],
    "eevee": ["vaporeon"],
    "diglett": ["dugtrio"],
    "pikachu": ["raichu"],
    "larvitar": ["pupitar", "tyranitar"],
    "dratini": ["dragonair", "dragonite"],
    "ditto": [],
    "togepi": [],
    "snorlax": [],
    "gengar": [],
}


def display_slug(base_slug: str, stage: int) -> str:
    """기본형 + 진화단계 → 실제로 화면에 그릴 슬러그."""
    if stage <= 0:
        return base_slug
    chain = EVOLUTION_CHAINS.get(base_slug, [])
    if not chain:
        return base_slug
    idx = min(stage, len(chain)) - 1
    return chain[idx]
