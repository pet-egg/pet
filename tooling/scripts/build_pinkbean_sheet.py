#!/usr/bin/env python3
"""
핑크빈(Pink Bean) 펫 스프라이트시트 재생성기 — **유일한 비포켓몬 펫 전용**.

다른 펫은 PokeAPI 에서 받아 `tooling/scripts/build_sheet.py` 가 굽지만, 핑크빈은
포켓몬이 아니라 **메이플스토리** 캐릭터라 PokeAPI 에 없다. 그래서 이 펫만 별도
스크립트로, 메이플 클라이언트 에셋을 추출/공개하는 커뮤니티 API `maplestory.io`
에서 공식 스프라이트를 받아 정본 `assets/pets/pinkbean/{spritesheet.png,pet.json}`
을 만든다. (mac 미러·Orca 번들은 `sync_assets.py` 가 정본에서 생성한다.)

소스 모션(GMS 230):
  - 8820001 (핑크빈 펫 폼): move / skill1 / stand / skill3 / attack1 / die1
  - 8820000 (핑크빈, 이모트 보유): skill6 (파란 베개에 누워 Zzz 자는 수면)

상태 → pet.json 애니메이션 행(다른 펫과 같은 9행 포맷):
  idle          ← 8820000 skill6 수면 프레임 (흑백으로 구움)   — 잠듦 Zzz
  running(±)    ← 8820001 move                                 — 작업 중
  waiting       ← 8820001 skill1 (금빛 마법진)                  — 얼음/대기
  review        ← 8820001 stand                                — 완료(하트)
  jumping       ← 8820001 skill3 (초록 해골 구슬)               — 마우스 호버
  waving        ← 8820001 attack1                              — 말하기
  failed        ← 8820001 die1 (어둠 고치 변신)                — 실패

재현성: 재실행하면 GIF 를 다시 받아 정본을 다시 굽는다. 이후 `sync_assets.py` 를
돌려 mac 미러를 갱신할 것. © Nexon — 개인/학습용 참고.

Requires: pillow (`pip install pillow`)
Usage:
  python3 tooling/scripts/build_pinkbean_sheet.py
  python3 tooling/scripts/sync_assets.py      # 정본 → mac 미러 반영
"""
import io
import json
import os
import urllib.request

from PIL import Image, ImageSequence, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))  # tooling/scripts → repo
OUT_DIR = os.path.join(REPO_ROOT, "assets", "pets", "pinkbean")
CACHE_DIR = os.path.join(HERE, ".cache", "pinkbean")

API = "https://maplestory.io/api/GMS/230/mob"
HDR = {"User-Agent": "Mozilla/5.0"}

FW = FH = 220          # 프레임 한 칸(px). pet.json 이 들고 있고 앱이 읽는다.
TARGET_BODY_H = 150    # 셀 안에서 핑크빈 몸통 높이(px) 목표
BOTTOM_MARGIN = 26     # 발을 셀 바닥에서 띄우는 여백(경험치 바 자리)


def fetch(url):
    for _ in range(6):  # maplestory.io 는 첫 렌더에 500 후 캐시되는 버릇이 있어 재시도
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=HDR), timeout=40) as r:
                if r.status == 200:
                    return r.read()
        except Exception:
            pass
    raise RuntimeError(f"fetch failed: {url}")


def load_anim_gif(mob, anim):
    """한 애니메이션의 정렬된 GIF(프레임끼리 앵커가 맞춰진 합성본)를 프레임 리스트로."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, f"{mob}_{anim}.gif")
    if not os.path.exists(path):
        with open(path, "wb") as f:
            f.write(fetch(f"{API}/{mob}/render/{anim}"))
    im = Image.open(path)
    return [f.convert("RGBA") for f in ImageSequence.Iterator(im)]


def body_anchor(frame):
    bb = frame.getbbox()
    if not bb:
        return (frame.width / 2, frame.height)
    return ((bb[0] + bb[2]) / 2.0, bb[3])  # 불투명 영역 바닥-중앙 = 발


def cell_from(frame, anchor, scale, grayscale=False, flip=False):
    img = frame
    ax, ay = anchor
    if flip:
        img = ImageOps.mirror(img)
        ax = frame.width - ax
    img = img.resize((max(1, int(round(img.width * scale))),
                      max(1, int(round(img.height * scale)))), Image.LANCZOS)
    cell = Image.new("RGBA", (FW, FH), (0, 0, 0, 0))
    ox = int(round(FW / 2.0 - ax * scale))
    oy = int(round(FH - BOTTOM_MARGIN - ay * scale))
    cell.alpha_composite(img, (ox, oy))
    if grayscale:
        r, g, b, a = cell.split()
        gray = ImageOps.grayscale(Image.merge("RGB", (r, g, b)))
        cell = Image.merge("RGBA", (gray, gray, gray, a))
    return cell


def build_anim(mob, anim, idxs, scale, grayscale=False, flip=False, ref=None, perframe=False):
    frames = load_anim_gif(mob, anim)
    if perframe:
        # 피사체가 캔버스를 가로질러 이동하는 경우(die1): 프레임마다 제 바닥-중앙으로 정렬
        return [cell_from(frames[i], body_anchor(frames[i]), scale, grayscale, flip) for i in idxs]
    anchor = body_anchor(frames[ref if ref is not None else idxs[0]])
    return [cell_from(frames[i], anchor, scale, grayscale, flip) for i in idxs]


def main():
    R = range
    stand0 = load_anim_gif(8820001, "stand")[0]
    sb = stand0.getbbox()
    scale = TARGET_BODY_H / (sb[3] - sb[1])

    # (행이름, mob, anim, 프레임 인덱스, 옵션, 프레임당 ms)
    specs = [
        ("idle",          8820000, "skill6",  list(R(62, 85)),  dict(grayscale=True, ref=66), 150),
        ("running",       8820001, "move",    list(R(0, 8)),    dict(),              95),
        ("running-right", 8820001, "move",    list(R(0, 8)),    dict(),              95),
        ("running-left",  8820001, "move",    list(R(0, 8)),    dict(flip=True),     95),
        ("waiting",       8820001, "skill1",  list(R(0, 16)),   dict(),              110),
        ("review",        8820001, "stand",   list(R(0, 6)),    dict(),              180),
        ("jumping",       8820001, "skill3",  list(R(2, 14)),   dict(),              80),
        ("waving",        8820001, "attack1", list(R(0, 27, 2)), dict(),             90),
        ("failed",        8820001, "die1",    list(R(0, 58, 3)), dict(perframe=True), 110),
    ]

    rows = []
    anims = {}
    for row, (name, mob, anim, idxs, opt, dur) in enumerate(specs):
        cells = build_anim(mob, anim, idxs, scale, **opt)
        rows.append(cells)
        anims[name] = {"row": row, "frames": len(cells), "frameDurationsMs": [dur] * len(cells)}
        print(f"row {row} {name:14s} {len(cells)} frames  ({mob}/{anim})")

    cols = max(len(c) for c in rows)
    sheet = Image.new("RGBA", (cols * FW, len(rows) * FH), (0, 0, 0, 0))
    for r, cells in enumerate(rows):
        for c, cell in enumerate(cells):
            sheet.paste(cell, (c * FW, r * FH), cell)

    manifest = {
        "id": "pinkbean-pinkbean",
        "displayName": "핑크빈 (Pink Bean)",
        "description": ("MapleStory Pink Bean (핑크빈) desktop pet. idle=흑백 Zzz 수면, running=걷기, "
                        "waiting=금빛 마법진, review=기본자세, hover(jumping)=초록 해골, failed=어둠 변신. "
                        "Sprites extracted from MapleStory client via maplestory.io "
                        "(mob 8820000/8820001, GMS 230) — © Nexon."),
        "spritesheetPath": "spritesheet.png",
        "frame": {"width": FW, "height": FH},
        "fps": 10,
        "defaultAnimation": "idle",
        "animations": anims,
    }

    os.makedirs(OUT_DIR, exist_ok=True)
    sheet.save(os.path.join(OUT_DIR, "spritesheet.png"))
    with open(os.path.join(OUT_DIR, "pet.json"), "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print("wrote", os.path.relpath(OUT_DIR, REPO_ROOT),
          "— 이제 `python3 tooling/scripts/sync_assets.py` 로 mac 미러 갱신")


if __name__ == "__main__":
    main()
