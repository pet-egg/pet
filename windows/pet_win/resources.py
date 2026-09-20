"""리소스(펫 스프라이트) 경로 해석 — dev 실행과 PyInstaller 번들 둘 다 커버.

- PyInstaller 로 묶인 .exe: 리소스는 `sys._MEIPASS/pets` 에 들어간다.
- 소스에서 그냥 실행: 저장소의 `ConnorPet/Sources/ConnorPet/Resources/pets` 를 쓴다.
- 개발 편의로 `windows/pet_win/../pets` 같은 로컬 복사본도 탐색한다.
"""
from __future__ import annotations

import os
import sys


def _candidates():
    here = os.path.dirname(os.path.abspath(__file__))
    win_dir = os.path.dirname(here)          # windows/
    repo_root = os.path.dirname(win_dir)     # 저장소 루트
    paths = []
    # PyInstaller onefile/onedir 번들.
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        paths.append(os.path.join(meipass, "pets"))
    # 실행 파일 옆(onedir).
    paths.append(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "pets"))
    # 로컬 복사본.
    paths.append(os.path.join(win_dir, "pets"))
    # 저장소 원본(macOS 앱과 공유).
    paths.append(os.path.join(
        repo_root, "ConnorPet", "Sources", "ConnorPet", "Resources", "pets"))
    return paths


def pets_dir() -> str:
    for p in _candidates():
        if os.path.isdir(p):
            return p
    # 못 찾으면 마지막 후보를 반환(에러 메시지에 경로가 보이게).
    return _candidates()[-1]


def pet_dir(slug: str) -> str:
    return os.path.join(pets_dir(), slug)


def available_slugs_on_disk():
    root = pets_dir()
    if not os.path.isdir(root):
        return []
    return sorted(
        d for d in os.listdir(root)
        if os.path.isfile(os.path.join(root, d, "pet.json"))
    )
