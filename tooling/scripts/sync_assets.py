#!/usr/bin/env python3
"""정본(assets/ · tooling/hooks/) → 각 앱이 필요로 하는 사본을 채운다.

왜 필요한가: SwiftPM 은 리소스를 **타깃 소스 트리 안**에 둬야 번들한다(심링크는
번들에 깨진 링크로 복사돼 실행 즉시 크래시 — 검증됨). 그래서 mac 앱의
`Resources/{pets,effects,hooks}` 는 git 에 두지 않고(정본은 assets/·tooling/hooks/),
빌드 전에 이 스크립트가 **실파일로 복사**해 채운다. windows 앱은 assets/ 를 직접
읽으므로 sync 가 필요 없다(참고용으로만 확인).

또한 Orca 임포트 번들(`dist/orca/<slug>.codex-pet/`)을 assets/pets 에서 생성한다.

사용:
  python3 tooling/scripts/sync_assets.py           # 정본 → mac 미러 + dist/orca 생성
  python3 tooling/scripts/sync_assets.py --check    # 미러가 정본과 일치하는지 검사(CI용)
  python3 tooling/scripts/sync_assets.py --orca      # Orca 번들만 생성
"""
from __future__ import annotations

import filecmp
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))          # tooling/scripts → repo

ASSETS_PETS = os.path.join(REPO_ROOT, "assets", "pets")
ASSETS_EFFECTS = os.path.join(REPO_ROOT, "assets", "effects")
HOOK_SRC = os.path.join(REPO_ROOT, "tooling", "hooks", "pet_hook_status.py")

MAC_RES = os.path.join(REPO_ROOT, "apps", "macos", "Sources", "ConnorPet", "Resources")
MAC_PETS = os.path.join(MAC_RES, "pets")
MAC_EFFECTS = os.path.join(MAC_RES, "effects")
MAC_HOOKS = os.path.join(MAC_RES, "hooks")

ORCA_DIR = os.path.join(REPO_ROOT, "dist", "orca")

# Orca 임포트 번들을 만들 기본형 슬러그(= 메뉴에서 고를 수 있는 17종).
# apps/*/… 의 availablePetSlugs / AVAILABLE_PET_SLUGS 와 같은 목록.
ORCA_SLUGS = [
    "totodile", "ditto", "charmander", "squirtle", "geodude", "eevee",
    "chikorita", "torchic", "togepi", "tepig", "snorlax", "gengar",
    "diglett", "pikachu", "larvitar", "dratini", "bichon",
]


def _copy_tree(src, dst):
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def sync_mac():
    """정본 → mac 타깃 미러(pets·effects·hooks)를 실파일로 채운다."""
    _copy_tree(ASSETS_PETS, MAC_PETS)
    _copy_tree(ASSETS_EFFECTS, MAC_EFFECTS)
    os.makedirs(MAC_HOOKS, exist_ok=True)
    shutil.copy2(HOOK_SRC, os.path.join(MAC_HOOKS, "pet_hook_status.py"))
    print(f"[sync] mac 미러 갱신: {os.path.relpath(MAC_PETS, REPO_ROOT)}, "
          f"{os.path.relpath(MAC_EFFECTS, REPO_ROOT)}, "
          f"{os.path.relpath(MAC_HOOKS, REPO_ROOT)}")


def gen_orca():
    """assets/pets → dist/orca/<slug>.codex-pet 생성(기본형 17종)."""
    os.makedirs(ORCA_DIR, exist_ok=True)
    n = 0
    for slug in ORCA_SLUGS:
        src = os.path.join(ASSETS_PETS, slug)
        if not os.path.isdir(src):
            print(f"[sync] 경고: assets/pets/{slug} 없음 — 건너뜀", file=sys.stderr)
            continue
        dst = os.path.join(ORCA_DIR, f"{slug}.codex-pet")
        if os.path.isdir(dst):
            shutil.rmtree(dst)
        os.makedirs(dst)
        shutil.copy2(os.path.join(src, "spritesheet.png"),
                     os.path.join(dst, "spritesheet.png"))
        shutil.copy2(os.path.join(src, "pet.json"),
                     os.path.join(dst, "pet.json"))
        n += 1
    print(f"[sync] Orca 번들 {n}종 생성: {os.path.relpath(ORCA_DIR, REPO_ROOT)}/")


def _dir_matches(src, dst):
    if not os.path.isdir(dst):
        return False
    cmp = filecmp.dircmp(src, dst)
    if cmp.left_only or cmp.right_only or cmp.diff_files or cmp.funny_files:
        return False
    for sub in cmp.common_dirs:
        if not _dir_matches(os.path.join(src, sub), os.path.join(dst, sub)):
            return False
    return True


def check():
    """mac 미러가 정본과 일치하는지 검사. 불일치·누락이면 exit 1."""
    problems = []
    if not _dir_matches(ASSETS_PETS, MAC_PETS):
        problems.append("Resources/pets ≠ assets/pets")
    if not _dir_matches(ASSETS_EFFECTS, MAC_EFFECTS):
        problems.append("Resources/effects ≠ assets/effects")
    mac_hook = os.path.join(MAC_HOOKS, "pet_hook_status.py")
    if not (os.path.isfile(mac_hook) and filecmp.cmp(HOOK_SRC, mac_hook, shallow=False)):
        problems.append("Resources/hooks/pet_hook_status.py ≠ tooling/hooks/…")
    if problems:
        print("[sync --check] 미러가 정본과 다릅니다 — `python3 tooling/scripts/sync_assets.py` 실행 필요:",
              file=sys.stderr)
        for p in problems:
            print("  - " + p, file=sys.stderr)
        return 1
    print("[sync --check] 미러가 정본과 일치합니다.")
    return 0


def main(argv):
    if "--check" in argv:
        return check()
    if "--orca" in argv:
        gen_orca()
        return 0
    sync_mac()
    gen_orca()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
