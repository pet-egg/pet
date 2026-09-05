# connor-pet

Orca 또는 Claude Code의 프로젝트/에이전트 상태에 반응하는 데스크톱 펫 (리아코/Totodile 등 9종, 메뉴바에서 전환). 자세한 배경·아키텍처·동작 방식은 `README.md`가 최신 소스이므로 거기를 먼저 읽을 것.

## 구조

- `ConnorPet/` — 실제 결과물인 독립 macOS 앱 (Swift Package, Xcode 불필요)
  - `Sources/ConnorPet/OrcaStatusWatcher.swift` — `last-status.json` 폴링(1s) + 상태 집계 (Orca 소스)
  - `Sources/ConnorPet/ClaudeCodeStatusWatcher.swift` — `~/.claude/sessions/*.json`(항상) + `~/.claude/connor-pet-status.json`(훅 설치 시)을 250ms마다 폴링해 병합 (Claude Code 소스, 기본값)
  - `Sources/ConnorPet/ClaudeDesktopStatusWatcher.swift` — Claude 데스크톱 앱 소스. 렌더러 CPU(신호1)+알림센터 DB(신호2)를 500ms 폴링해 잠듦/달리기/얼음/헤롱헤롱 판정. AX가 Claude 웹 콘텐츠를 안 뿜어서 CPU 휴리스틱을 씀
  - `Sources/ConnorPet/ClaudeProcessActivity.swift` — Claude 프로세스 트리 CPU 샘플러(`proc_pid_rusage`, mach 틱→ns timebase 변환). "생성 중=달리기" 신호
  - `Sources/ConnorPet/NotificationCenterDB.swift` — macOS 알림센터 SQLite DB 읽기(Full Disk Access 필요). Claude 완료 알림="헤롱헤롱" 신호. `isReadable`이 사실상 "FDA 권한 있음" 프록시(baseline은 이 readable 여부로만 잡는다 — 비어 있어도 첫 실제 알림이 헤롱헤롱을 띄우도록)
  - `Sources/ConnorPet/FullDiskAccess.swift` — FDA 권한 감지(`isGranted()`=알림센터 DB 읽기 가능 여부) + `시스템 설정 › 전체 디스크 접근` 창 열기(`openSettings()`). 앱이 직접 부여할 수 없어(재실행 필요) 안내만 함. AppDelegate 메뉴의 "전체 디스크 접근 권한 (헤롱헤롱 알림)" 항목이 이걸 호출(권한 여부=체크 표시)
  - `Sources/ConnorPet/UpdaterManager.swift` — Sparkle 자동 업데이트 래퍼. 실행 시 `checkForUpdateInformation()`으로 **UI 없이 조용히** 확인 → 메뉴로만 "업데이트 있음" 알림(팝업/토스트 없음), 사용자가 메뉴를 눌러야 `checkForUpdates()`로 정식 설치. 자동 확인/다운로드는 꺼 둠. `isConfigured`(Info.plist에 SUFeedURL 있음)일 때만 켜져서 `swift run` 개발 빌드는 설정-오류 팝업 없이 넘어감. EdDSA(SUPublicEDKey)로 검증하므로 ad-hoc/미공증 배포에서도 동작. AppDelegate 메뉴에 현재버전 표시 + 업데이트 항목을 붙인다
  - `Sources/ConnorPet/PetAnimationState.swift` — 우선순위 로직 포팅 + `AgentStatusWatching` 프로토콜 (`acknowledgeDone()`으로 헤롱헤롱 호버-해제) + 토큰/진화 필드
  - `Sources/ConnorPet/TokenUsage.swift` — 트랜스크립트 JSONL에서 실제 토큰 사용량 합산(`TranscriptTokenReader`, mtime 캐시) + 토큰→경험치%/진화단계 매핑(`XPModel`)
  - `Sources/ConnorPet/SpriteSheet.swift`, `PetView.swift`(펫 아래 경험치 바 포함), `PetWindow.swift` — 렌더링
  - `Sources/ConnorPet/BattleService.swift` — 같은 wifi 발견(Bonjour, `NWListener`/`NWBrowser`) + 대전 신청/수락 핸드셰이크(length-prefixed JSON over `NWConnection`)
  - `Sources/ConnorPet/BattleSimulation.swift` — seed 하나로 양쪽이 똑같이 계산하는 결정론적 대전 시뮬레이션(명중/회피 포함, 순수 함수). 승패 난수는 직접 구현한 seed 고정 정수 PRNG(`DeterministicRNG`) — 표준 `random(using:)`/GameplayKit은 버전·기기 간 불일치 위험이라 안 씀
  - `Sources/ConnorPet/BattleWindow.swift` — 작은 LCD형 대전 화면(디지몬 다마고치 스타일, 가운데 뜨는 `.nonactivatingPanel`). **한 번에 펫 하나만** 표시(내 펫=왼쪽 끝·오른쪽으로 발사, 상대=오른쪽 끝·왼쪽으로 발사), 발사체가 화면 밖으로 나가면 플래시 컷으로 **화면 전환**해 상대 펫 등장. 불꽃은 `CAEmitterLayer`(additive), 회피는 뒤집기+백홉 + HP + WIN/LOSE
  - `Sources/ConnorPet/BattleChallengeDialog.swift` — 대전 신청 수락/거절 모달(`BattleDialog`). accessory 앱이라 `NSAlert`이 폴더/앱 아이콘을 띄우는 문제를 피하려고, 커스텀 borderless `NSPanel`(canBecomeKey override)에 **"BATTLE" 배너**(코드로 그린 그라디언트) + 초록 수락 버튼(layer-backed `PillButton`, `bezelColor`은 불안정해서 안 씀)로 직접 그림. `runModal`로 동기 반환
  - `Sources/ConnorPet/BattleSelfTest.swift` — `CONNORPET_SELFTEST=battle swift run`으로 도는 헤드리스 핸드셰이크 검증(한 프로세스에서 A/B 발견→신청→수락→결과 합의까지 확인, `SELFTEST PASS`)
  - `Sources/ConnorPet/AppDelegate.swift` — 앱 연결, 메뉴바 아이콘/펫 선택/소스 선택/경험치 바 토글/진화 사용 토글/**Claude Code 상태 훅 설치 토글**/**전체 디스크 접근 권한 열기**/대전 메뉴 + 경험치%에 따른 진화 스프라이트 교체(`evolutionChains`, 임계치·on-off는 사용자 설정)
  - `Sources/ConnorPet/ClaudeHookInstaller.swift` — `scripts/install_claude_hooks.py`를 Swift로 포팅한 인앱 설치기. DMG로 설치해 저장소가 없는 사용자를 위해, 번들에 넣어 둔 훅 핸들러(`Resources/hooks/claude_hook_status.py`)를 `~/.claude/connor-pet/`로 복사한 뒤 `~/.claude/settings.json`에 같은 6개 훅을 병합/제거(`JSONSerialization`으로 느슨하게 읽어 기존 설정·다른 훅은 보존, 쓰기 전 타임스탬프 백업). AppDelegate 메뉴의 "Claude Code 상태 훅 (얼음/헤롱헤롱)" 항목이 이걸 호출(설치 여부=체크 표시)
  - `Sources/ConnorPet/HookInstallSelfTest.swift` — `CONNORPET_SELFTEST=hooks swift run`으로 도는 헤드리스 설치기 검증(임시 홈에 실제 `settings.json`을 시드해 설치→재설치 무동작→제거까지, 남의 훅이 보존되는지 확인, `SELFTEST PASS`)
  - `Sources/ConnorPet/Resources/pets/<slug>/` — 펫별 `spritesheet.png` + `pet.json` 번들 사본
- `<slug>.codex-pet/` (totodile/ditto/charmander/squirtle/geodude/eevee/chikorita/torchic/togepi) — Orca에 직접 임포트 가능한 번들
- `scripts/build_sheet.py` — PokeAPI에서 스프라이트를 다시 받아 각 펫의 시트를 재생성 (`PETS` 리스트가 소스 오브 트루스)
- `scripts/make_app.sh` — release 빌드를 독립 실행형 `ConnorPet.app`으로 감싸서 `~/Applications`에 설치 (터미널과 무관하게 상주시키는 정식 실행 경로)
- `scripts/simulate_agent.py` — 실제 에이전트 없이 `last-status.json`에 가짜 상태 주입 (Orca 소스 전용)
- `scripts/install_claude_hooks.py` — 위 훅 핸들러를 `~/.claude/settings.json`에 병합/제거(`--uninstall`)하는 설치 스크립트. 기존 훅(matcher 걸린 것 포함) 안 건드리고, 재실행해도 중복 안 됨
- `scripts/claude_hook_status.py` — Claude Code 훅 핸들러 (선택 설치, README "Claude Code 훅으로 얼음/헤롱헤롱까지 보기" 참고). `~/.claude/settings.json`은 전역 설정이라 **사용자 명시적 동의 없이 이 저장소가 대신 실행하지 않는다** — 스크립트/README/메뉴바 버튼으로 안내만 하고, 사용자가 직접 돌리거나(스크립트) 메뉴에서 명시적으로 눌러야(인앱) 실행. 이 파일의 사본이 `ConnorPet/Sources/ConnorPet/Resources/hooks/claude_hook_status.py`에도 있다(아래 동기화 규칙 참고)
- `preview/index.html` — 브라우저 전용 미리보기 (Orca 설치 불필요)
- `.github/workflows/build-pet-dmg.yml` — base pet 하나만 골라 `.app`/`.dmg`로 빌드하는 수동(`workflow_dispatch`) CI 파이프라인. `pet` 드롭다운 옵션이 `availablePetSlugs`와 동기화되어 있어야 함(아래 "작업 시 반드시 지킬 것" 참고)

## 빌드 / 실행 / 테스트

```sh
cd ConnorPet
swift build          # 컴파일만 확인
swift run            # 개발 중 실행 (터미널의 자식 프로세스 — 터미널 닫으면 죽는다)
CONNORPET_DEBUG=1 swift run   # 상태 판정 로그를 stderr로 출력
```

사용자가 실제로 쓰는 상주 실행은 `.app` 번들 쪽이다 (저장소 루트에서):
```sh
./scripts/make_app.sh                  # ~/Applications/ConnorPet.app 생성·교체
open -a ~/Applications/ConnorPet.app
```
리소스를 `Bundle.module`로 읽으므로 번들에는 바이너리와 함께 SwiftPM이 만든 `ConnorPet_ConnorPet.bundle`이 `Contents/Resources/`에 들어가야 한다. 바이너리만 복사하면 스프라이트를 못 찾아 실행 즉시 `fatalError`로 죽는다.

에이전트 상태 없이 테스트:
```sh
python3 scripts/simulate_agent.py set web-app working
python3 scripts/simulate_agent.py clear-all
```

UI/동작을 변경했으면 반드시 `swift run`으로 실제 앱을 띄워서 확인할 것 (빌드 성공 ≠ 동작 확인).

## 작업 시 반드시 지킬 것

- **README.md ↔ GitHub repo description 항상 일치**: 이 저장소의 목적·구성을 바꾸는 작업(기능 추가/제거, 앱 이름 변경, 아이콘·동작 변경 등)을 하면 `README.md`를 갱신하고, repo description도 같은 내용으로 맞출 것. 확인/변경 명령:
  ```sh
  gh repo view --json description
  gh repo edit --description "<새 설명>"
  ```
  README와 실제 동작이 어긋나는 부분(예: 코드에서 바뀐 아이콘·플래그·경로가 README에 옛날 그대로 남아있는 경우)을 발견하면 관련 작업이 아니어도 그 자리에서 같이 고칠 것.
- **훅 핸들러 두 벌 항상 일치**: `scripts/claude_hook_status.py`(저장소/스크립트 설치용)와 `ConnorPet/Sources/ConnorPet/Resources/hooks/claude_hook_status.py`(앱 번들에 넣어 메뉴바 버튼이 `~/.claude/connor-pet/`로 복사하는 사본)는 **바이트 단위로 동일**해야 한다. 한쪽을 고치면 반드시 다른 쪽에 복사할 것(`cp scripts/claude_hook_status.py ConnorPet/Sources/ConnorPet/Resources/hooks/claude_hook_status.py`). 어긋나면 스크립트로 설치한 사용자와 앱으로 설치한 사용자의 동작이 달라진다. 변경했다면 `CONNORPET_SELFTEST=hooks swift run`으로 설치기 회귀도 함께 확인.
- **새 포켓몬(펫) 추가 시 GitHub Actions 목록도 같이 갱신**: `AppDelegate.swift`의 `availablePetSlugs`에 슬러그를 추가하면(`scripts/build_sheet.py`의 `PETS`도 함께), `.github/workflows/build-pet-dmg.yml`의 `workflow_dispatch.inputs.pet.options`에도 같은 펫을 `"<한글 이름> (<영문 slug 대문자화>)"` 형식(각 펫 `pet.json`의 `displayName`과 동일한 표기)으로 추가할 것. 둘이 어긋나면 Actions에서 그 펫을 선택할 방법이 없어진다 — 실제로 토게피 추가 때 이 목록을 빠뜨렸던 적이 있음.
- **브랜치 전략: GitHub Flow**: `main`은 항상 배포 가능한 상태로 유지하고, 모든 작업은 `main`에서 분기한 **기능 브랜치**에서 한다. 브랜치 이름은 `feature/<간단한-설명>`(kebab-case) 형식으로 짓는다 (예: `feature/lan-multiplayer-battle`). 작업이 끝나면 그 기능 브랜치를 push하고 `main`으로 향하는 PR을 열어 리뷰 후 병합한다. `main`에 직접 push하지 않는다.
- **커밋 메시지는 항상 한글로 작성**: 제목/본문 모두 한글로 쓸 것 (`Co-Authored-By:` 트레일러 등 고정 형식 줄은 예외).
- **`main` 브랜치는 보호 룰셋이 없음**: 룰셋상으로는 write 권한이 있는 협업자가 PR/승인 없이 `main`에 직접 push할 수 있고 force-push/브랜치 삭제도 막혀있지 않지만, **위 브랜치 전략(GitHub Flow)에 따라 직접 push하지 말고 기능 브랜치 + PR로 진행할 것**. 협업자 현황 확인 명령: `gh api repos/pet-egg/pet/collaborators --jq '.[] | {login, permissions}'`. 룰셋 현황 확인 명령: `gh api repos/pet-egg/pet/rulesets`.
