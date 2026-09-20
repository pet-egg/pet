"""PyInstaller/개발 실행 진입점 — `python main.py` 또는 빌드된 pet.exe."""
from pet_win.app import main

if __name__ == "__main__":
    raise SystemExit(main())
