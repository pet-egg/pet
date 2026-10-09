# pet

[Orca](https://github.com/stablyai/orca) · [Claude Code](https://claude.com/claude-code) · [Claude 데스크톱 앱](https://claude.ai/download)의 상태에 반응하는 데스크톱 펫입니다. 포켓몬·비숑(동물)·핑크빈(메이플스토리) 등 **18종**을 메뉴바에서 전환할 수 있고, 에이전트의 **실제 토큰 사용량**만큼 경험치가 쌓여 펫이 **진화**합니다. 같은 Wi-Fi의 다른 사용자와 **1:1 대전**도 지원합니다. macOS·Windows 모두 지원합니다.

> 📦 **이 저장소는 배포 전용입니다.** 다운로드·설치·자동업데이트만 제공하며, 소스 코드는 비공개로 관리됩니다.

## 설치

### macOS

Homebrew (권장):

```sh
brew install --cask pet-egg/pet/pet
```

또는 원라이너 — 최신 `pet.dmg` 를 받아 `/Applications` 에 설치하고 quarantine 플래그까지 벗긴 뒤 실행합니다(이미 있으면 업데이트로 교체):

```sh
curl -fsSL "https://raw.githubusercontent.com/pet-egg/pet/main/install.sh?$(date +%s)" | bash
```

### Windows

PowerShell 한 줄 — 최신 `pet.exe` 를 받아 `%LOCALAPPDATA%\pet` 에 설치하고 시작 메뉴 바로가기를 만듭니다:

```powershell
irm https://raw.githubusercontent.com/pet-egg/pet/main/install.ps1 | iex
```

### 수동 다운로드

- macOS: [`pet.dmg`](https://github.com/pet-egg/pet/releases/latest/download/pet.dmg)
- Windows: [`pet.exe`](https://github.com/pet-egg/pet/releases/latest/download/pet.exe)

> **안정화 버전**을 받으려면 `PET_CHANNEL=stable`(맥) 또는 `-Stable`(윈도우)을 붙이세요. 최신 마이너 라인 직전의 검증된 패치를 받습니다.

## 자동 업데이트

- **macOS** — [Sparkle](https://sparkle-project.org/)로 인앱 자동 업데이트를 지원합니다(EdDSA 서명 검증). 메뉴에서 "업데이트 확인"으로 설치합니다.
- **Windows** — 인앱 업데이터가 최신 릴리스를 받아 교체합니다.

## 출처 / 라이선스

포켓몬 스프라이트는 [PokeAPI](https://pokeapi.co/), 핑크빈은 [maplestory.io](https://maplestory.io) 에서 받았습니다. 개인·학습용 프로젝트입니다. © 각 저작권자.
