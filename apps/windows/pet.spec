# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller 스펙 — 윈도우용 pet.exe 를 만든다.

번들에 펫 스프라이트(pets/)와 앱 아이콘을 포함한다. macOS 앱(ConnorPet)의
Resources/pets 를 그대로 재사용하므로 소스 오브 트루스가 한 곳이다.
`windows/` 에서 `pyinstaller pet.spec` 로 빌드한다.
"""
import os

here = os.path.abspath(SPECPATH)                     # noqa: F821 (PyInstaller 주입) = apps/windows
repo_root = os.path.dirname(os.path.dirname(here))  # apps/windows → repo

# 펫 스프라이트 정본(assets/pets)을 그대로 번들 — mac 앱과 공유하는 단일 소스.
pets_dir = os.path.join(repo_root, "assets", "pets")
icon_png = os.path.join(repo_root, "assets", "app-icon.png")

datas = [(pets_dir, "pets")]
if os.path.isfile(icon_png):
    datas.append((icon_png, "."))

# .exe 아이콘용 .ico 를 png 에서 생성(Windows 는 .ico 필요).
ico_path = None
try:
    from PIL import Image
    if os.path.isfile(icon_png):
        ico_path = os.path.join(here, "pet.ico")
        img = Image.open(icon_png).convert("RGBA")
        img.save(ico_path, sizes=[(16, 16), (32, 32), (48, 48),
                                  (64, 64), (128, 128), (256, 256)])
except Exception as e:  # noqa: BLE001 — 아이콘 없이도 빌드는 되게
    print("아이콘(.ico) 생성 실패, 기본 아이콘 사용:", e)
    ico_path = None

a = Analysis(
    ['main.py'],
    pathex=[here],
    binaries=[],
    datas=datas,
    # PyNaCl(업데이트 Ed25519 검증)의 네이티브 백엔드 — PyInstaller 훅이 대개 잡지만
    # 명시해 둔다.
    hiddenimports=['nacl', 'nacl.signing', 'nacl.exceptions', '_cffi_backend'],
    hookspath=[],
    runtime_hooks=[],
    excludes=['tkinter'],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='pet',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    runtime_tmpdir=None,
    console=False,            # 창(트레이) 앱 — 콘솔 안 뜨게
    icon=ico_path,
)
