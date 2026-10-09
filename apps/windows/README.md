# pet — 윈도우용 버전

macOS 앱(`apps/macos/`)의 크로스플랫폼 포트. AppKit UI 대신 **Python + PySide6(Qt)**
로 다시 그렸고, 상태 판정 로직과 펫 스프라이트(`assets/pets`)는
macOS 앱과 **그대로 공유**한다(소스 오브 트루스가 한 곳).

## 지금 되는 것

- 투명·항상 위·테두리 없는 창에 펫 스프라이트를 그리고 드래그로 옮긴다.
- 시스템 트레이 메뉴에서 펫 17종 전환 / 진화 사용 / 경험치 바 항상 표시 / 경험치 초기화 / 종료.
- **Claude Code 상태**(`~/.claude/sessions/*.json` + 선택적 `~/.claude/pet-status.json`)를
  250ms 폴링해:
  - `busy` → 서있기(running), `waiting` → 얼음(waiting), `idle` → 잠듦(idle)
  - `busy→idle` 전이(Stop 엣지)를 감지해 **헤롱헤롱(done)**, 트랜스크립트 꼬리의 마지막
    `tool_result` 가 에러면 **실패(failed)**
  - 트랜스크립트 JSONL 토큰(`input+output+cache_creation`, cache_read 제외)으로
    경험치·진화(2억 → 5억 토큰) 계산
- 펫 위 호버로 헤롱헤롱 확인(acknowledge), 창 위치·선택·경험치는 `QSettings`(Windows 레지스트리)에 저장.
- **인앱 자동 업데이트**(`pet_win/updater.py`, 맥 Sparkle 대응) — 아래 참고.

> macOS 전용 기능(대전/노려보기·Claude Desktop AX 감지·알림센터 DB·Orca 소스)은 아직
> 포팅하지 않았다. Windows 에서 Orca 세션 제외 로직은 파일이 없어 자연히 no-op.

## 자동 업데이트 (`updater.py`)

맥이 Sparkle 로 하듯 윈도우도 같은 개념을 직접 구현했다 — **frozen `pet.exe` + Windows 에서만** 활성.

1. 시작 3초 뒤(및 트레이 "업데이트 확인") `releases/latest/download/windows-appcast.json`
   (`{version, url, edSignature, notes}`)을 읽어 현재 버전(`_version.py`, CI가 태그로 주입)과 비교.
2. 새 버전이면 `pet.exe` 를 내려받아 **맥 Sparkle 과 같은 EdDSA(Ed25519) 공개키**
   (`updater.PUBLIC_KEY_B64`)로 서명 검증(PyNaCl). 미서명 배포라 이 서명이 무결성의 유일한 담보.
3. 검증되면 **팝업 없이 트레이 메뉴로만** "업데이트 설치 (vX)" 를 노출(Sparkle UX). 사용자가 누르면
   실행 중 exe 를 `pet.old.exe` 로 rename(윈도우는 실행 중 exe 도 rename 가능)한 뒤 새 exe 를
   제자리에 놓고 재실행한다. 남은 `pet.old.exe` 는 다음 시작 때 삭제.

서명: CI(`build-release.yml`)의 `release` 잡이 맥 appcast 와 **같은 `SPARKLE_EDDSA_PRIVATE_KEY`**
로 `pet.exe` 를 Ed25519 서명해 `windows-appcast.json` 을 만든다(공개키는 코드에 임베드).

## 개발 실행

```sh
cd apps/windows
python -m venv .venv && . .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt                 # PySide6
python main.py
```

## 테스트 (headless — 디스플레이 불필요)

```sh
cd apps/windows
pip install pytest
QT_QPA_PLATFORM=offscreen python -m pytest tests -v   # Windows: set QT_QPA_PLATFORM=offscreen
```

- `tests/test_logic.py` — 애니메이션 우선순위/decay, XP 모델, 토큰 accrual
- `tests/test_watcher.py` — 세션파일 파싱·busy→idle 엣지·죽은 pid 무시
- `tests/test_gui_smoke.py` — 오프스크린으로 17종 전부 로드·전 상태 렌더·메뉴 구성

## .exe 빌드

로컬:

```sh
cd apps/windows
pip install pyinstaller Pillow
pyinstaller pet.spec --noconfirm      # dist/pet.exe
```

CI: `v*` 태그를 푸시하면 `.github/workflows/build-release.yml` 의 `build-windows` 잡이
windows-latest 에서 헤드리스 테스트 → PyInstaller 빌드 → 실제 exe 5초 스모크를 하고,
`release` 잡이 **맥 `pet.dmg` 와 함께 같은 릴리스에 `pet.exe`** 를 올린다(맥·윈도우 통합).

```sh
git tag v0.2.0 && git push origin v0.2.0   # 맥 dmg + 윈도우 exe 동시 빌드·릴리스
```

macOS 빌드(`v*` 태그 → pet.dmg)와 태그 네임스페이스가 분리돼 있어 서로 안 부딪힌다.
