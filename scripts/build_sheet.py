#!/usr/bin/env python3
"""
Builds each configured Pokémon's `<slug>.codex-pet/{spritesheet.png,pet.json}`
(Orca-importable bundle) plus its copy under
`ConnorPet/Sources/ConnorPet/Resources/pets/<slug>/` (the ConnorPet app's
bundled resource, picked from the menu-bar pet switcher) from PokeAPI's public
gen5 battle sprites. Reproducible: re-running this script re-downloads the
source frames and regenerates every bundle from scratch, so the two copies of
each pet's assets can never drift out of sync.

Requires: pillow (`pip install pillow`)

Usage: python3 scripts/build_sheet.py
"""
import json
import math
import os
import urllib.request

from PIL import Image, ImageDraw, ImageEnhance, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
CACHE_DIR = os.path.join(HERE, ".cache")
APP_RESOURCES_DIR = os.path.join(REPO_ROOT, "ConnorPet", "Sources", "ConnorPet", "Resources", "pets")

# 프레임 한 칸의 크기. 기본은 200 이지만 펫마다 다를 수 있다 — pet.json 이
# frame 크기를 들고 있고 앱은 그 값을 읽는다.
#
# 한때 파이리만 320 이었다 — 불뿜기 불길을 시트 안에 그리려니 자리가 모자랐기
# 때문이다. 지금은 불길을 시트가 아니라 **별도 창**에 그리므로(FlameWindow.swift)
# 프레임을 넓힐 이유가 없어졌다. 시트에는 펫의 반동 동작만 들어간다.
FRAME_DEFAULT = 200
# 파이리만 400 인 이유는 불길과 무관하다(불길은 별도 창에 그린다). 캐릭터를 다른
# 펫의 2배 크기로 보여 주기 위해서다. 창만 2배로 키우면 200px 소스를 1.8배로 늘려
# 그리게 돼 도트가 뭉개지므로, 스프라이트를 정수배로 두 배(4배 → 8배 확대) 다시 굽고
# 프레임도 같이 넓힌다.
# 진화하면 덩치가 커진다. 기본형은 다른 펫과 같은 크기(프레임 200)이고, 진화형만
# 프레임을 넓혀 화면상 두 배쯤으로 보이게 한다. 진화형은 원본 도트가 더 크기 때문에
# 같은 화면 크기를 내려면 프레임이 더 넓어야 한다(480).
# 프레임은 스프라이트가 들어갈 만큼만 잡는다. 창 크기가 프레임에 비례하므로
# (window = 90 x FRAME/200) 필요 이상으로 넓히면 펫 주변 투명 영역만 커지고,
# 그 영역도 클릭을 받는다.
FRAME_BY_PET = {
    "charmeleon": 360, "charizard": 400,
    "wartortle": 280, "blastoise": 400,
}
FRAME = FRAME_DEFAULT
SPRITE_TARGET = SPRITE_TARGET_DEFAULT if False else (170, 150)

# 스프라이트를 프레임 안 어느 크기까지 키울지. 기본값은 좌우 이동·점프 오프셋이
# 들어갈 여백을 남기도록 잡혀 있다.
SPRITE_TARGET_DEFAULT = (170, 150)
# 목표는 "화면에 찍히는 캐릭터 높이"를 계열 안에서 맞추는 것이다. 정수 배율만 쓰므로
# 원하는 배율이 나오도록 목표 크기를 잡아 뒀다 (파이리 8배 / 리자드 6배 / 리자몽 4배,
# 꼬부기 8배 / 어니부기 6배 / 거북왕 5배).
# 화면에 찍히는 높이는 프레임과 무관하게 "준비된 스프라이트 높이 x 0.45" 다.
# 단계마다 눈에 띄게 차이가 나도록 배율을 골랐다. 2단계를 키우는 대신 1단계를
# 줄였다 — 화면을 너무 많이 차지하면 곤란하기 때문이다.
#
#   파이리 76pt → 리자드 126pt(x5) → 리자몽 160pt(x4)
#   꼬부기 58pt → 어니부기 103pt(x4) → 거북왕 148pt(x5)
SPRITE_TARGET_BY_PET = {
    "charmeleon": (340, 290), "charizard": (360, 370),
    "wartortle": (250, 235), "blastoise": (360, 340),
}
ROWS_ORDER = [
    "idle", "running-right", "running-left", "waving",
    "jumping", "failed", "waiting", "running", "review"
]

# 행별 프레임 수와 프레임당 지속시간(ms).
#
# 예전에는 모든 행이 4프레임이었다. 원본(PokeAPI gen5 배틀 스프라이트)은 55프레임짜리
# 애니메이션 GIF인데 그중 4장만 쓰고 버렸기 때문에, 재생이 "네 장 슬라이드쇼"처럼 보였다.
# 아래처럼 더 촘촘히 샘플링하면 원본이 들고 있던 움직임이 그대로 살아나 GIF처럼 이어진다.
# 루프 총 길이는 예전과 비슷하게 유지하고 프레임만 잘게 쪼갠 것이다.
#
# 속도 기준: 원본 gen5 GIF 는 55프레임 x 100ms = 5.5초 루프다. 12프레임으로 샘플링해
# "원본과 같은 속도"로 재생하려면 프레임당 458ms 가 필요하다. 아래 값은 그 자연 속도를
# 기준으로 모션마다 몇 배 빠르게 돌릴지를 정한 것이다 — 처음에는 자연 속도의 6~9배로
# 잡아서 캐릭터가 안절부절못하는 것처럼 보였다.
#
#   name: (프레임 수, 프레임당 ms)   # 자연 속도 대비
FRAME_SPEC = {
    "idle":          (12, 400),   # 1.1x — 잠듦. 원본 호흡 속도 거의 그대로
    "running-right": (12, 120),   # 3.8x — 드래그로 끌려다니는 중이라 제일 빠르다
    "running-left":  (12, 120),   # 3.8x
    "waving":        (10, 160),   # 3.4x — 말하는 동안
    "jumping":       (10, 90),    # 6.1x — 점프는 짧고 빨라야 탄력이 산다
    "failed":        (10, 130),   # 4.2x — 떨림
    "waiting":       (8, 300),    # 2.3x — 얼음. 포즈 고정, 반짝임만 흐른다
    "running":       (12, 180),   # 2.5x — 작업 중
    "review":        (12, 220),   # 2.1x — 헤롱헤롱
    "fire-breath":   (10, 110),   # 5.0x — 불뿜기. 짧고 세게
    "water-gun":     (10, 110),   # 5.0x — 물뿜기
}
COLS = max(n for n, _ in FRAME_SPEC.values())

# 속성기 — 그 포켓몬의 타입에 묶이므로 전 펫 공통 행일 수 없다. 여기 등록된 펫만
# 해당 행을 갖고, 앱은 매니페스트에 그 행이 있는 펫에서만 메뉴를 활성화한다.
#
# mouth 는 이펙트가 나오는 입 위치인데, **스프라이트 크기에 대한 비율**이다.
# 프레임 절대좌표나 스프라이트 로컬 픽셀로 두면 확대 배율을 바꿀 때 같이 움직이지
# 않아 어긋난다 — 실제로 파이리를 4배에서 8배로 키웠을 때 불길이 입이 아니라
# 이마에서 나오고 있었다.
SKILLS = {
    "charmander": {"row": "fire-breath", "effect": "fire_jet.png",  "mouth": (0.268, 0.369)},
    "charmeleon": {"row": "fire-breath", "effect": "fire_jet.png",  "mouth": (0.130, 0.230)},
    "charizard":  {"row": "fire-breath", "effect": "fire_jet.png",  "mouth": (0.160, 0.560)},
    "squirtle":   {"row": "water-gun",   "effect": "water_jet.png", "mouth": (0.179, 0.360)},
    "wartortle":  {"row": "water-gun",   "effect": "water_jet.png", "mouth": (0.280, 0.340)},
    "blastoise":  {"row": "water-gun",   "effect": "water_jet.png", "mouth": (0.300, 0.400)},
}
EXTRA_ROWS = {slug: [cfg["row"]] for slug, cfg in SKILLS.items()}

EFFECTS_DIR = os.path.join(HERE, "effects")
# 불길 끝과 프레임 왼쪽 변 사이에 남길 여백. 0 이면 변에 닿아 잘린 것처럼 보인다.
JET_MARGIN = 8


def spec(name):
    n, ms = FRAME_SPEC[name]
    return n, [ms] * n


def lerp_key(keys, t):
    """예전 4프레임용 키프레임 배열을 임의 프레임 수로 보간한다.

    t 는 루프 위상 [0,1). 키는 루프이므로 마지막 키에서 첫 키로 되돌아가며 잇는다.
    덕분에 오버레이(하트/Zzz/반짝임)의 기존 연출을 그대로 두고 프레임만 늘릴 수 있다.
    """
    n = len(keys)
    x = (t % 1.0) * n
    i = int(x) % n
    j = (i + 1) % n
    f = x - int(x)
    return keys[i] + (keys[j] - keys[i]) * f

# Every pet the ConnorPet menu-bar switcher offers. Add an entry here (plus a
# re-run of this script) to add a new selectable Pokémon.
PETS = [
    {
        "slug": "totodile",
        "dex_id": 158,
        "out_dir_name": "totodile.codex-pet",
        "id": "totodile-riako",
        "display_name": "리아코 (Totodile)",
        "description": (
            "Custom connor-pet build: Totodile / 리아코 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "ditto",
        "dex_id": 132,
        "out_dir_name": "ditto.codex-pet",
        "id": "ditto-metamong",
        "display_name": "메타몽 (Ditto)",
        "description": (
            "Custom connor-pet build: Ditto / 메타몽 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "charmander",
        "dex_id": 4,
        "out_dir_name": "charmander.codex-pet",
        "id": "charmander-pairi",
        "display_name": "파이리 (Charmander)",
        "description": (
            "Custom connor-pet build: Charmander / 파이리 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "squirtle",
        "dex_id": 7,
        "out_dir_name": "squirtle.codex-pet",
        "id": "squirtle-kkobugi",
        "display_name": "꼬부기 (Squirtle)",
        "description": (
            "Custom connor-pet build: Squirtle / 꼬부기 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "geodude",
        "dex_id": 74,
        "out_dir_name": "geodude.codex-pet",
        "id": "geodude-kkomadol",
        "display_name": "꼬마돌 (Geodude)",
        "description": (
            "Custom connor-pet build: Geodude / 꼬마돌 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "eevee",
        "dex_id": 133,
        "out_dir_name": "eevee.codex-pet",
        "id": "eevee-ibui",
        "display_name": "이브이 (Eevee)",
        "description": (
            "Custom connor-pet build: Eevee / 이브이 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "chikorita",
        "dex_id": 152,
        "out_dir_name": "chikorita.codex-pet",
        "id": "chikorita-chikorita",
        "display_name": "치코리타 (Chikorita)",
        "description": (
            "Custom connor-pet build: Chikorita / 치코리타 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "torchic",
        "dex_id": 255,
        "out_dir_name": "torchic.codex-pet",
        "id": "torchic-achamo",
        "display_name": "아차모 (Torchic)",
        "description": (
            "Custom connor-pet build: Torchic / 아차모 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "togepi",
        "dex_id": 175,
        "out_dir_name": "togepi.codex-pet",
        "id": "togepi-togepi",
        "display_name": "토게피 (Togepi)",
        "description": (
            "Custom connor-pet build: Togepi / 토게피 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "tepig",
        "dex_id": 498,
        "out_dir_name": "tepig.codex-pet",
        "id": "tepig-ttukkuri",
        "display_name": "뚜꾸리 (Tepig)",
        "description": (
            "Custom connor-pet build: Tepig / 뚜꾸리 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "snorlax",
        "dex_id": 143,
        "out_dir_name": "snorlax.codex-pet",
        "id": "snorlax-jamanbo",
        "display_name": "잠만보 (Snorlax)",
        "description": (
            "Custom connor-pet build: Snorlax / 잠만보 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "gengar",
        "dex_id": 94,
        "out_dir_name": "gengar.codex-pet",
        "id": "gengar-pantom",
        "display_name": "팬텀 (Gengar)",
        "description": (
            "Custom connor-pet build: Gengar / 팬텀 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "diglett",
        "dex_id": 50,
        "out_dir_name": "diglett.codex-pet",
        "id": "diglett-diguda",
        "display_name": "디그다 (Diglett)",
        "description": (
            "Custom connor-pet build: Diglett / 디그다 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
    {
        "slug": "pikachu",
        "dex_id": 25,
        "out_dir_name": "pikachu.codex-pet",
        "id": "pikachu-pikachu",
        "display_name": "피카츄 (Pikachu)",
        "description": (
            "Custom connor-pet build: Pikachu / 피카츄 reacts to live Orca agent/project status, "
            "skinned as Pokémon status conditions — blocked/waiting=Freeze, done=Infatuation, "
            "nothing=Sleep, working=running (unchanged). Built from PokeAPI gen5 battle sprites."
        ),
    },
]


# Evolved forms, built by the exact same pipeline and bundled only as ConnorPet
# app resources (orca_bundle=False). The app swaps these in automatically as
# token-usage XP rises — see AppDelegate.evolutionChains, which must stay in
# sync with the (base → [stage1, stage2]) mapping implied here. Ditto has no
# evolution, so it isn't listed. Eevee is given a single evolution (Vaporeon).
_EVOLUTIONS = [
    # (slug, dex_id, display_name)
    ("croconaw", 159, "크로콘 (Croconaw)"),
    ("feraligatr", 160, "장크로다일 (Feraligatr)"),
    ("charmeleon", 5, "리자드 (Charmeleon)"),
    ("charizard", 6, "리자몽 (Charizard)"),
    ("wartortle", 8, "어니부기 (Wartortle)"),
    ("blastoise", 9, "거북왕 (Blastoise)"),
    ("graveler", 75, "데구리 (Graveler)"),
    ("golem", 76, "딱구리 (Golem)"),
    ("bayleef", 153, "베이리프 (Bayleef)"),
    ("meganium", 154, "메가니움 (Meganium)"),
    ("combusken", 256, "영뿔 (Combusken)"),
    ("blaziken", 257, "번치코 (Blaziken)"),
    ("vaporeon", 134, "샤미드 (Vaporeon)"),
    ("dugtrio", 51, "닥트리오 (Dugtrio)"),
    ("raichu", 26, "라이츄 (Raichu)"),
]
for _slug, _dex, _name in _EVOLUTIONS:
    PETS.append({
        "slug": _slug,
        "dex_id": _dex,
        "out_dir_name": f"{_slug}.codex-pet",  # unused (orca_bundle=False)
        "id": f"{_slug}-evolved",
        "display_name": _name,
        "orca_bundle": False,
        "description": (
            f"Custom connor-pet build (evolved form): {_name} reacts to live Orca/Claude Code "
            "agent status, skinned as Pokémon status conditions — blocked/waiting=Freeze, "
            "done=Infatuation, nothing=Sleep, working=running. Built from PokeAPI gen5 battle sprites."
        ),
    })


def fetch(url, dest):
    if os.path.exists(dest):
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    print(f"downloading {url}")
    urllib.request.urlretrieve(url, dest)
    return dest


def load_frames(path):
    im = Image.open(path)
    frames = []
    for i in range(im.n_frames):
        im.seek(i)
        frames.append(im.convert("RGBA").copy())
    return frames


# Some Pokémon (e.g. Geodude with its fists spread wide) are noticeably wider
# than tall, so scaling purely by height alone can blow the width past the
# 200px frame and get clipped in paste_centered. Scale by whichever of
# width/height is the tighter constraint instead, so every base sprite fits
# inside (max_w, max_h) regardless of its aspect ratio.
# 원본은 41x42 같은 아주 작은 도트 그림이다. 여기에 3.57배 같은 소수배 NEAREST 확대를
# 걸면 한 도트가 3px 이 되기도 하고 4px 이 되기도 해서, 확대된 그림의 픽셀 격자가
# 들쭉날쭉해진다(도트 그림에서 제일 눈에 띄는 품질 저하다). 들어갈 수 있는 가장 큰
# "정수" 배율로만 키우면 모든 도트가 같은 크기의 정사각형으로 유지돼 선명해진다.
# 배율은 "내림"이 아니라 "반올림"이다. 내림으로 하면 딱 맞는 배율이 2.79 인 꼬마돌이
# 2배까지 떨어져 예전보다 28% 작아진다. 반올림하면 3배(183px)로 예전(170px)보다 오히려
# 커진다. 대신 반올림으로 커진 만큼 프레임 안에서 움직일 여백이 줄어드는데, 그건
# paste_centered 가 오프셋을 잘라내서 처리한다(프레임 밖으로 나가는 일은 없다).
def scale_int_to_fit(img, max_w, max_h):
    w, h = img.size
    factor = max(1, round(min(max_w / w, max_h / h)))
    # 반올림 결과가 프레임 자체를 넘으면 한 단계 내린다.
    while factor > 1 and (w * factor > FRAME - 8 or h * factor > FRAME - 8):
        factor -= 1
    return img.resize((w * factor, h * factor), Image.NEAREST)


# 프레임마다 따로 autocrop 하면 원본 GIF 안에 들어 있는 상하 바운스·몸통 흔들림이
# 전부 화면 중앙으로 재정렬되면서 사라진다. 전 프레임의 합집합 bbox 로 똑같이 잘라야
# 프레임 간 상대적인 움직임이 보존된다 — 이게 "GIF처럼 이어져 보이는" 실제 이유다.
def union_bbox(frames):
    boxes = [f.getbbox() for f in frames]
    boxes = [b for b in boxes if b]
    if not boxes:
        return None
    return (min(b[0] for b in boxes), min(b[1] for b in boxes),
            max(b[2] for b in boxes), max(b[3] for b in boxes))


def prepare_frames(frames, max_w=None, max_h=None):
    if max_w is None or max_h is None:
        max_w, max_h = SPRITE_TARGET
    box = union_bbox(frames)
    cropped = [f.crop(box) if box else f for f in frames]
    return [scale_int_to_fit(c, max_w, max_h) for c in cropped]


def sample(frames, n, start=0.0, span=1.0):
    """루프 재생용으로 n장을 고르게 뽑는다.

    i/n 을 쓰는 이유: i/(n-1) 로 뽑으면 마지막 프레임이 첫 프레임과 같아져
    루프가 한 박자 멈춘 것처럼 보인다.
    """
    last = len(frames) - 1
    return [frames[max(0, min(last, int(round((start + span * (i / n)) * last))))] for i in range(n)]


def load_effect(name):
    """scripts/effects/ 의 이펙트 스프라이트를 읽는다.

    캐릭터 스프라이트와 달리 이건 PokeAPI 에서 받을 수 없어서 저장소에 커밋해
    둔다(생성형 이미지라 재실행으로 똑같이 다시 만들 수 없다). 파일이 없으면
    해당 연출만 건너뛴다 — 없다고 빌드가 실패하면 안 된다.
    """
    path = os.path.join(EFFECTS_DIR, name)
    if not os.path.exists(path):
        return None
    return Image.open(path).convert("RGBA")


def blank_canvas():
    return Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))


def applied_offset(sprite, dx, dy=0, scale=1.0):
    """paste_centered 가 실제로 적용하게 될 dx/dy 를 미리 알려 준다.

    paste_centered 는 스프라이트가 프레임을 벗어나지 않도록 오프셋을 잘라낸다.
    불뿜기처럼 스프라이트 위에 이펙트를 얹는 연출은 입 좌표를 이 오프셋으로
    계산하므로, 잘린 값을 모르면 불길이 입에서 떨어져 나온다.
    """
    w, h = sprite.size
    if scale != 1.0:
        w, h = max(1, round(w * scale)), max(1, round(h * scale))
    cx, cy = (FRAME - w) // 2, (FRAME - h) // 2
    return max(0, min(FRAME - w, cx + dx)) - cx, max(0, min(FRAME - h, cy + dy)) - cy


def paste_centered(sprite, dx=0, dy=0, scale=1.0):
    """스프라이트를 프레임 중앙에 놓고 dx/dy 만큼 민다.

    dx/dy 는 프레임 안에 완전히 들어가도록 잘린다. 예전에는 자르지 않아서 점프
    최고점(dy=-34)에서 머리 위쪽이 실제로 잘려 나가고 있었다. 배율을 키운 펫일수록
    여백이 적으므로 잘리는 폭은 펫마다 다르다 — 잘리느니 덜 움직이는 쪽이 낫다.
    """
    canvas = blank_canvas()
    s = sprite
    if scale != 1.0:
        w, h = s.size
        s = s.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.NEAREST)
    w, h = s.size
    cx, cy = (FRAME - w) // 2, (FRAME - h) // 2
    x = max(0, min(FRAME - w, cx + dx))
    y = max(0, min(FRAME - h, cy + dy))
    canvas.alpha_composite(s, (x, y))
    return canvas


def tint(img, color, strength):
    r, g, b, a = img.split()
    base = Image.merge("RGB", (r, g, b))
    solid = Image.new("RGB", img.size, color)
    blended = Image.blend(base, solid, strength)
    br, bg, bb = blended.split()
    return Image.merge("RGBA", (br, bg, bb, a))


def desaturate(img, sat, bright):
    r, g, b, a = img.split()
    rgb = Image.merge("RGB", (r, g, b))
    rgb = ImageEnhance.Color(rgb).enhance(sat)
    rgb = ImageEnhance.Brightness(rgb).enhance(bright)
    br, bg, bb = rgb.split()
    return Image.merge("RGBA", (br, bg, bb, a))


def flip(img):
    return img.transpose(Image.FLIP_LEFT_RIGHT)


# Pokémon status-condition skins for the priority states from
# PetAnimationState.swift: blocked/waiting -> Freeze, done -> Infatuation,
# nothing -> Sleep. These layer a drawn overlay on top of the tinted sprite
# instead of relying on tint/desaturate alone, since a color shift by itself
# reads as a mood filter rather than a distinct status (see connor-pet
# artifact "얼음 연출 비교" — bubble read as soap-bubble, angular ice crystal
# read as "frozen" and matches the actual in-game status-effect art style).
def _load_font(size):
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def draw_ice_crystal(frame, shimmer=1.0):
    """Encase the sprite in an angular ice crystal (not a round bubble) —
    a faceted polygon plus three shards poking past its edges."""
    size = frame.size[0]
    inset = 25
    x0, y0, x1, y1 = inset, inset, size - inset, size - inset
    w, h = x1 - x0, y1 - y0

    def pt(fx, fy):
        return (x0 + fx * w, y0 + fy * h)

    overlay = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    outline_pts = [pt(*p) for p in [
        (0.50, 0.02), (0.78, 0.14), (1.00, 0.40), (0.92, 0.74),
        (0.68, 0.98), (0.32, 0.94), (0.04, 0.68), (0.10, 0.30),
    ]]
    fill_a = int(130 * shimmer)
    draw.polygon(outline_pts, fill=(150, 205, 245, fill_a))
    draw.polygon(outline_pts, outline=(230, 248, 255, 235), width=3)

    highlight_pts = [pt(*p) for p in [(0.50, 0.02), (0.78, 0.14), (0.50, 0.46), (0.10, 0.30)]]
    draw.polygon(highlight_pts, fill=(255, 255, 255, int(120 * shimmer)))

    shadow_pts = [pt(*p) for p in [(0.68, 0.98), (0.92, 0.74), (0.50, 0.46), (0.32, 0.94)]]
    draw.polygon(shadow_pts, fill=(30, 80, 150, int(100 * shimmer)))

    shards = [
        [(x0 + 0.10 * w, y0 - 4), (x0 + 0.30 * w, y0 - 4), (x0 + 0.20 * w, y0 - 22)],
        [(x1 + 4, y0 + 0.28 * h), (x1 + 4, y0 + 0.46 * h), (x1 + 20, y0 + 0.36 * h)],
        [(x0 + 0.28 * w, y1 + 4), (x0 + 0.46 * w, y1 + 4), (x0 + 0.36 * w, y1 + 20)],
    ]
    for shard in shards:
        draw.polygon(shard, fill=(220, 240, 255, int(160 * shimmer)))
        draw.polygon(shard, outline=(235, 250, 255, 220), width=2)

    return Image.alpha_composite(frame, overlay)


def draw_heart(draw, cx, cy, size, alpha):
    r = size / 2
    draw.ellipse([cx - r, cy - r * 1.3, cx, cy - 0.1 * r], fill=(255, 130, 185, alpha))
    draw.ellipse([cx, cy - r * 1.3, cx + r, cy - 0.1 * r], fill=(255, 130, 185, alpha))
    draw.polygon([(cx - r, cy - 0.4 * r), (cx + r, cy - 0.4 * r), (cx, cy + r * 1.1)], fill=(255, 130, 185, alpha))


# 오버레이들은 원래 4프레임 고정 인덱스를 받았다. 이제 행마다 프레임 수가 다르므로
# 루프 위상 t(0~1)를 받아 기존 키프레임을 보간한다 — 연출은 그대로, 움직임만 촘촘해진다.
def draw_hearts(frame, t):
    """Floating hearts for the Infatuation skin, timed to rise + fade across
    the row's loop like the CSS heartFloat keyframes."""
    overlay = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    alphas = [0, 190, 230, 90]
    dy = [10, 0, -12, -24]
    draw_heart(draw, frame.size[0] * 0.68, frame.size[1] * 0.30 + lerp_key(dy, t),
               20, int(lerp_key(alphas, t)))
    alt = t + 0.5
    draw_heart(draw, frame.size[0] * 0.32, frame.size[1] * 0.22 + lerp_key(dy, alt),
               14, int(lerp_key(alphas, alt)))
    return Image.alpha_composite(frame, overlay)


def draw_zzz(frame, t):
    """Drifting "Zzz" for the Sleep skin, timed like the CSS zzzFloat keyframes.

    예전에는 시스템 폰트로 "Zzz" 를 그렸다. 도트 그림 옆에 벡터 글꼴이 얹혀 이질적이라
    도트로 그린 이펙트 스프라이트로 바꿨다. 파일이 없으면 예전 방식으로 돌아간다 —
    이펙트가 없다고 빌드가 실패하면 안 된다.

    크기와 이동 폭은 프레임 크기에 비례한다. 예전에는 절대 픽셀이라 400px 프레임을
    쓰는 펫(파이리·꼬부기)에서 Zzz 만 절반 크기로 보였다.
    """
    scale = FRAME / FRAME_DEFAULT
    alphas = [0, 210, 130, 0]
    dx = [0, 4, 12, 20]
    dy = [8, -2, -14, -26]
    alpha = int(lerp_key(alphas, t))
    x = frame.size[0] * 0.62 + lerp_key(dx, t) * scale
    y = frame.size[1] * 0.10 + lerp_key(dy, t) * scale

    sprite = load_effect("zzz.png")
    overlay = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    if sprite is not None:
        w = max(1, round(46 * scale))
        h = max(1, round(sprite.height * w / sprite.width))
        sprite = sprite.resize((w, h), Image.NEAREST)
        # 프레임마다 투명도가 달라야 떠오르며 사라지는 연출이 된다.
        sa = sprite.split()[-1].point(lambda v: v * alpha // 255)
        sprite.putalpha(sa)
        overlay.alpha_composite(sprite, (round(x), round(y)))
    else:
        draw = ImageDraw.Draw(overlay)
        draw.text((x, y), "Zzz", font=_load_font(round(22 * scale)),
                  fill=(210, 230, 255, alpha))
    return Image.alpha_composite(frame, overlay)


def build_pet(pet):
    global FRAME, SPRITE_TARGET
    FRAME = FRAME_BY_PET.get(pet["slug"], FRAME_DEFAULT)
    SPRITE_TARGET = SPRITE_TARGET_BY_PET.get(pet["slug"], SPRITE_TARGET_DEFAULT)
    dex_id = pet["dex_id"]
    front_url = f"https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/{dex_id}.gif"
    front_path = fetch(front_url, os.path.join(CACHE_DIR, f"{dex_id}_front.gif"))

    front_raw = load_frames(front_path)

    # 원본은 55프레임짜리 애니메이션 GIF다. 전 프레임 공통 bbox 로 잘라서
    # 프레임 간 상대 움직임(호흡·바운스)을 보존하고, 정수배로만 확대한다.
    front_base = prepare_frames(front_raw)

    rows = {}
    extra_manifest = {}

    # idle == "nothing is happening" in agentStateAnimation, reskinned as the
    # Sleep status: darker/desaturated + a drifting "Zzz" instead of a plain
    # resting pose.
    n, durs = spec("idle")
    idle_frames = []
    for i, s in enumerate(sample(front_base, n)):
        t = i / n
        sleepy = desaturate(s, 0.4, 0.62)
        frame = paste_centered(sleepy, dy=round(-3 + 3 * math.cos(2 * math.pi * t)))
        idle_frames.append(draw_zzz(frame, t))
    rows["idle"] = {"frames": idle_frames, "durations": durs}

    # 좌우 이동은 원본 프레임이 이미 다리 움직임을 갖고 있으므로 dx 만 얹는다.
    # scale 은 건드리지 않는다 — 소수배 NEAREST 확대가 도트 격자를 다시 망가뜨린다.
    #
    # 방향 주의: gen5 front 스프라이트는 몸이 왼쪽으로 틀어져 있어(픽셀 무게중심이
    # 왼쪽) **왼쪽을 보고 있다.** 그래서 뒤집지 않은 프레임이 running-left 이고,
    # 좌우 반전한 쪽이 running-right 다. 예전에는 이게 반대로 들어가 있어서
    # 오른쪽으로 드래그하면 펫이 왼쪽을 보고 끌려갔다.
    n, durs = spec("running-left")
    run_left_frames = []
    for i, s in enumerate(sample(front_base, n)):
        t = i / n
        run_left_frames.append(paste_centered(
            s,
            dx=round(14 * math.sin(2 * math.pi * t)),
            dy=round(-4 - 4 * math.cos(4 * math.pi * t)),
        ))
    rows["running-left"] = {"frames": run_left_frames, "durations": durs}
    _, durs_right = spec("running-right")
    rows["running-right"] = {"frames": [flip(f) for f in run_left_frames], "durations": durs_right}

    # waving 은 펫이 말하는 동안 재생된다. 예전에는 뒷모습(back) 스프라이트로 만들어서
    # 브리핑을 읽어 주는 내내 등을 돌리고 있었다. 앞모습으로 굽고, 좌우로 살짝 흔들리는
    # 리듬을 줘서 running(위아래 바운스)과 구분되게 한다.
    n, durs = spec("waving")
    rows["waving"] = {
        "frames": [paste_centered(
                       s,
                       dx=round(4 * math.sin(2 * math.pi * i / n)),
                       dy=round(-3 - 3 * math.cos(4 * math.pi * i / n)))
                   for i, s in enumerate(sample(front_base, n))],
        "durations": durs,
    }

    # 점프만 scale 을 쓴다 — 여기서의 스쿼시&스트레치는 의도된 연출이라
    # 도트 격자가 살짝 흐트러지는 것보다 탄력이 살아나는 쪽이 낫다.
    n, durs = spec("jumping")
    jump_frames = []
    for i, s in enumerate(sample(front_base, n)):
        t = i / n
        arc = math.sin(math.pi * t)
        jump_frames.append(paste_centered(s, dy=round(14 - 48 * arc), scale=0.94 + 0.10 * arc))
    rows["jumping"] = {"frames": jump_frames, "durations": durs}

    n, durs = spec("failed")
    fail_frames = []
    for i, s in enumerate(sample(front_base, n)):
        t = i / n
        tinted = tint(s, (220, 40, 40), 0.45 if i % 2 == 0 else 0.2)
        fail_frames.append(paste_centered(
            tinted, dx=round(6 * math.sin(6 * math.pi * t)), dy=round(2 + 4 * t)))
    rows["failed"] = {"frames": fail_frames, "durations": durs}

    # blocked/waiting wins the priority check immediately, so it's reskinned
    # as Freeze: held on one pose (frozen == not moving) and encased in an
    # angular ice crystal, with a faint shimmer across the loop instead of
    # actual motion.
    n, durs = spec("waiting")
    freeze_pose = paste_centered(front_base[0])
    icy = tint(desaturate(freeze_pose, 0.35, 1.1), (170, 215, 250), 0.6)
    rows["waiting"] = {
        "frames": [draw_ice_crystal(icy, shimmer=lerp_key([0.85, 1.0, 1.0, 0.85], i / n))
                   for i in range(n)],
        "durations": durs,
    }

    n, durs = spec("running")
    rows["running"] = {
        "frames": [paste_centered(s, dy=round(-5 - 5 * math.cos(2 * math.pi * i / n)))
                   for i, s in enumerate(sample(front_base, n))],
        "durations": durs,
    }

    # done is the completion state, reskinned as Infatuation: a warm pink
    # tint (replacing the old gold) plus floating hearts instead of just a
    # color shift.
    # 속성기 — SKILLS 에 등록된 펫만. 숨을 들이켰다가(뒤로 젖힘) 앞으로 내뿜는다.
    # 펫이 왼쪽을 보고 있으므로 이펙트도 왼쪽으로 나간다.
    if pet["slug"] in SKILLS:
        skill = SKILLS[pet["slug"]]
        n, durs = spec(skill["row"])
        breath_frames = []
        # 프레임마다 입이 어디로 가는지와 불길이 얼마나 커졌는지. 불길 자체는
        # 시트에 없고 앱이 별도 창에 그리므로, 앱이 이 값을 읽어 위치를 맞춘다.
        mouth_by_frame = []
        src = sample(front_base, n)
        for i, sprite in enumerate(src):
            # 0~2 준비, 3~7 분사, 8~9 회복.
            #
            # 분사 중에는 펫이 **오른쪽으로** 밀린다. 반동이라 그림상 자연스럽기도
            # 하지만, 실질적인 이유는 불길이 나갈 자리를 왼쪽에 만들어 주는 것이다.
            # 예전에는 반대로 왼쪽으로 기울여서 여유를 더 깎아 먹었다.
            recoil = max(0, (FRAME - src[0].width) // 2 - 4)   # 프레임 안에서 밀 수 있는 한계
            if i < 3:
                dx, grow = round(recoil * (i / 6)), 0.0
            elif i < 8:
                k = (i - 3) / 4                      # 0 → 1
                dx, grow = round(recoil * (0.55 + 0.45 * k)), 0.45 + 0.55 * k
            else:
                dx, grow = round(recoil * (0.3 - 0.3 * (i - 8))), 0.0
            frame = paste_centered(sprite, dx=dx, dy=-2)
            # 스프라이트가 프레임 끝에 닿으면 dx 가 잘린다. 잘린 뒤의 값이라야
            # 앱이 계산할 입 좌표와 어긋나지 않는다.
            adx, ady = applied_offset(sprite, dx, dy=-2)
            sx = (FRAME - sprite.width) // 2 + adx
            sy = (FRAME - sprite.height) // 2 + ady
            mouth_by_frame.append({
                "x": sx + round(skill["mouth"][0] * sprite.width),
                "y": sy + round(skill["mouth"][1] * sprite.height),
                "grow": round(grow, 3),
            })
            breath_frames.append(frame)
        rows[skill["row"]] = {"frames": breath_frames, "durations": durs}
        extra_manifest["skill"] = {
            "row": skill["row"],
            "effect": skill["effect"],
            "mouthByFrame": mouth_by_frame,
        }

    n, durs = spec("review")
    review_frames = []
    for i, s in enumerate(sample(front_base, n)):
        t = i / n
        pulse = 0.5 - 0.5 * math.cos(2 * math.pi * t)
        tinted = tint(s, (255, 140, 190), 0.15 + 0.35 * pulse)
        frame = paste_centered(tinted, dy=round(-3 - 3 * math.cos(2 * math.pi * t)))
        review_frames.append(draw_hearts(frame, t))
    rows["review"] = {"frames": review_frames, "durations": durs}

    row_order = ROWS_ORDER + [r for r in EXTRA_ROWS.get(pet["slug"], []) if r in rows]
    sheet_w = FRAME * COLS
    sheet_h = FRAME * len(row_order)
    sheet = Image.new("RGBA", (sheet_w, sheet_h), (0, 0, 0, 0))

    manifest_animations = {}
    for row_idx, name in enumerate(row_order):
        data = rows[name]
        for col_idx, frame in enumerate(data["frames"]):
            sheet.alpha_composite(frame, (col_idx * FRAME, row_idx * FRAME))
        manifest_animations[name] = {
            "row": row_idx,
            "frames": len(data["frames"]),
            "frameDurationsMs": data["durations"]
        }

    manifest = {
        "id": pet["id"],
        "displayName": pet["display_name"],
        "description": pet["description"],
        "spritesheetPath": "spritesheet.png",
        "frame": {"width": FRAME, "height": FRAME},
        "fps": 6,
        "defaultAnimation": "idle",
        "animations": manifest_animations,
        **extra_manifest,
    }

    # Orca-importable bundle (Settings → Experimental → Pet → Import). Skipped
    # for evolved forms (orca_bundle=False): those aren't user-selectable pets,
    # the app just swaps them in as XP rises, so they'd only clutter the repo
    # root with bundles no one imports.
    if pet.get("orca_bundle", True):
        out_dir = os.path.join(REPO_ROOT, pet["out_dir_name"])
        os.makedirs(out_dir, exist_ok=True)
        sheet.save(os.path.join(out_dir, "spritesheet.png"), optimize=True)
        with open(os.path.join(out_dir, "pet.json"), "w") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)

    # ConnorPet app's bundled copy, picked from the menu-bar pet switcher (or,
    # for evolved forms, swapped in automatically) — written from the same
    # in-memory sheet/manifest so it can never drift from any Orca bundle above.
    app_dir = os.path.join(APP_RESOURCES_DIR, pet["slug"])
    os.makedirs(app_dir, exist_ok=True)
    sheet.save(os.path.join(app_dir, "spritesheet.png"), optimize=True)
    with open(os.path.join(app_dir, "pet.json"), "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)

    print(f"wrote {app_dir}/ ({sheet.size[0]}x{sheet.size[1]})")


def main():
    for pet in PETS:
        build_pet(pet)

    # Old flat Resources/{spritesheet.png,pet.json} layout is superseded by
    # per-pet Resources/pets/<slug>/ subfolders now that there's more than one.
    old_flat_dir = os.path.join(REPO_ROOT, "ConnorPet", "Sources", "ConnorPet", "Resources")
    for name in ("spritesheet.png", "pet.json"):
        stale = os.path.join(old_flat_dir, name)
        if os.path.exists(stale):
            os.remove(stale)


if __name__ == "__main__":
    main()
