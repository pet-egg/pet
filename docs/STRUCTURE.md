# 저장소 구조 (모노레포)

두 개의 네이티브 데스크톱 앱(mac=Swift/AppKit, windows=Python/PySide6)이 **데이터
(스프라이트+매니페스트)와 동작 스펙**을 공유하는 모노레포다. 로직 코드는 언어가
달라 공유하지 않고 각자 포팅하되, `shared/BEHAVIOR.md` 를 계약으로 삼는다.
(Flutter 의 `lib/ + macos/ + windows/ + assets/`, 모노레포의 `apps/ + packages/`
패턴을 따랐다.)

```
pet/
├─ apps/                      배포되는 앱(각각 네이티브)
│  ├─ macos/                  Swift/AppKit — pet.app/dmg (구 ConnorPet/)
│  │  └─ Sources/ConnorPet/   SwiftPM 타깃 이름은 ConnorPet 유지
│  │     └─ Resources/        source-icons(committed) + pets·effects·hooks(생성물, gitignore)
│  └─ windows/                Python/PySide6 — pet.exe (구 windows/)
│     └─ pet_win/             상태워처·XP·애니메이션·스프라이트 로딩
├─ assets/                    ★ 에셋 정본(단일 소스)
│  ├─ pets/<slug>/{spritesheet.png,pet.json}   기본형+진화형 36종
│  ├─ effects/                fire_jet·water_jet·zzz
│  └─ app-icon.png
├─ shared/                    두 구현의 계약
│  ├─ BEHAVIOR.md             상태머신·decay·XP 임계치·진화 사슬
│  └─ pet-manifest.schema.json  pet.json JSON Schema
├─ tooling/
│  ├─ scripts/                build_sheet·sync_assets·simulate_agent·install_claude_hooks·make_app.sh
│  └─ hooks/pet_hook_status.py  ★ Claude Code 훅 정본(단일 소스)
├─ dist/                      생성물(gitignore)
│  └─ orca/<slug>.codex-pet/  Orca 임포트 번들 — sync_assets 가 assets/pets 에서 생성
├─ preview/index.html         브라우저 미리보기
├─ .github/workflows/         build-release.yml (v* → 맥 dmg + 윈도우 exe 통합 릴리스)
└─ README.md  CLAUDE.md  install.sh(맥)  install.ps1(윈도우)
```

## 단일 소스 규칙 (중복 제거)

개편 전엔 같은 에셋이 3곳(`*.codex-pet/`, mac Resources, windows가 참조), 훅이
2곳(scripts + mac 번들), 이펙트가 2곳에 **복제**돼 있었다. 지금은:

| 무엇 | 정본 | 사본(생성물) |
|---|---|---|
| 펫 스프라이트 | `assets/pets/` | mac `Resources/pets`(sync), `dist/orca/*`(sync), win 번들(pet.spec) |
| 이펙트 | `assets/effects/` | mac `Resources/effects`(sync) |
| Claude Code 훅 | `tooling/hooks/pet_hook_status.py` | mac `Resources/hooks/*`(sync) |
| 동작 스펙 | `shared/BEHAVIOR.md` | 두 앱 코드가 각자 포팅 |

## SwiftPM 제약이 핵심

SwiftPM 은 리소스를 **타깃 소스 트리 안**에 둬야 번들한다. 심링크로 밖을 가리키면
번들에 **깨진 심링크**로 복사돼 실행 즉시 크래시한다(검증됨). 그래서 mac 타깃의
`Resources/{pets,effects,hooks}` 는 git 에 두지 않고(gitignore) **빌드 전에
`sync_assets.py` 가 정본에서 실파일로 복사**해 채운다.

```sh
python3 tooling/scripts/sync_assets.py           # 정본 → mac 미러 + dist/orca 생성
python3 tooling/scripts/sync_assets.py --check    # 미러가 정본과 일치하는지(CI)
```

`make_app.sh` 와 CI(build-release.yml)는 `swift build` 전에 sync 를 먼저 돌린다.
`build_sheet.py` 도 정본을 다시 구운 뒤 sync 를 호출한다. **fresh clone 에서 mac 을
빌드하려면 먼저 sync 를 한 번 돌려야 한다.** windows 는 `assets/pets` 를 직접 읽어
sync 가 필요 없다.
