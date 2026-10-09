"""펫 메타데이터 — 선택 가능한 슬러그, 진화 사슬, 표시형 계산.

AppDelegate.swift 의 availablePetSlugs / evolutionChains / displaySlug 포팅.
"""
from __future__ import annotations

# 메뉴/트레이에서 고를 수 있는 펫(모두 미진화 기본형). Swift availablePetSlugs 와 동일 순서.
AVAILABLE_PET_SLUGS = [
    "totodile", "ditto", "charmander", "squirtle", "geodude", "eevee",
    "chikorita", "torchic", "togepi", "tepig", "munchlax", "gastly",
    "diglett", "pichu", "larvitar", "dratini", "bichon", "pinkbean",
]

# 기본형(미진화체) → 진화형 목록(1차, 2차). 빈 배열이면 진화 없음.
# pikachu→pichu, gengar→gastly, snorlax→munchlax 로 모두 미진화체에서 시작한다.
EVOLUTION_CHAINS = {
    "totodile": ["croconaw", "feraligatr"],
    "charmander": ["charmeleon", "charizard"],
    "squirtle": ["wartortle", "blastoise"],
    "geodude": ["graveler", "golem"],
    "chikorita": ["bayleef", "meganium"],
    "torchic": ["combusken", "blaziken"],
    # 이브이는 분기 진화(8종) — 고정 사슬이 없다. 사용자가 2억 토큰 도달 시 고른 진화형을
    # 저장하고 display_slug 가 eevee_choice 로 받는다(미선택이면 이브이 유지). EEVEELUTION_SLUGS 참고.
    "eevee": [],
    "diglett": ["dugtrio"],
    "pichu": ["pikachu", "raichu"],
    "gastly": ["haunter", "gengar"],
    "munchlax": ["snorlax"],
    "tepig": ["pignite", "emboar"],
    "larvitar": ["pupitar", "tyranitar"],
    "dratini": ["dragonair", "dragonite"],
    "ditto": [],
    "togepi": ["togetic", "togekiss"],
    "pinkbean": [],
}

# 이브이 분기 진화 후보 8종(도감순). mac AppDelegate.eeveelutionSlugs 와 동일 순서.
EEVEELUTION_SLUGS = ["vaporeon", "jolteon", "flareon", "espeon",
                     "umbreon", "leafeon", "glaceon", "sylveon"]


def display_slug(base_slug: str, stage: int, eevee_choice: str | None = None) -> str:
    """기본형 + 진화단계 → 실제로 화면에 그릴 슬러그.

    이브이는 분기 진화라 고정 사슬 대신 eevee_choice(고른 진화형)를 한 칸 사슬로 쓴다 —
    미선택이면 스테이지가 올라도 이브이를 유지(사용자가 고를 때까지). (mac displaySlugForTest 과 짝)"""
    if base_slug == "eevee":
        if stage <= 0 or not eevee_choice:
            return base_slug
        return eevee_choice
    if stage <= 0:
        return base_slug
    chain = EVOLUTION_CHAINS.get(base_slug, [])
    if not chain:
        return base_slug
    idx = min(stage, len(chain)) - 1
    return chain[idx]
