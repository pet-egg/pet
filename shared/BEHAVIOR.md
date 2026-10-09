# 펫 동작 스펙 (두 구현의 계약)

mac 앱(Swift, `apps/macos`)과 windows 앱(Python, `apps/windows`)은 **코드를 공유하지
않고** 각자 포팅한다. 이 문서가 둘이 반드시 똑같이 지켜야 할 **계약**이다. 값·임계치를
바꾸면 두 구현을 모두 고치고 여기 숫자도 갱신한다.

원본(권위): mac 쪽 `ClaudeCodeStatusWatcher.swift` / `PetAnimationState.swift` /
`TokenUsage.swift`. windows 포트: `apps/windows/pet_win/{status_watcher,animation,tokenusage,xpmodel}.py`.

## 상태 소스 (Claude Code)

- 세션 파일: `~/.claude/sessions/<pid>.json` — 필드 `sessionId`, `pid`, `status`,
  `waitingFor?`, `statusUpdatedAt`|`updatedAt`, `name`, `cwd`. `pid` 가 죽었으면 무시.
- 훅 오버레이(선택): `~/.claude/pet-status.json` — `entries[key].{state, updatedAt|receivedAt, providerSession.id}`.
- Orca 제외: `~/Library/Application Support/Orca/agent-hooks/last-status.json` 의
  `entries[*].providerSession.id` 에 든 세션은 건너뛴다(macOS 전용, 없으면 no-op).
- 폴링 주기: **250ms**.

### status → 내부 상태
| 세션 `status` | 내부 |
|---|---|
| `busy` | working |
| `waiting` | blocked |
| 그 외 | idle |

### done/failed 합성 (훅 없이)
`busy→idle` 전이(Stop 엣지)를 감지한 순간 완료를 각인한다. 트랜스크립트 꼬리
(마지막 256KB, 최대 80줄)에서 **마지막 `tool_result` 의 `is_error` 가 참이면 failed,
아니면 done.** idle 세션에 훅 오버레이(done/failed)가 있으면 그 값이 우선.

## 애니메이션 우선순위
프레시(30분 이내)한 세션들을 훑어 가장 급한 하나를 고른다:

1. `blocked`/`waiting` → **waiting(얼음)** — 발견 즉시 단락(최우선)
2. `failed` → **failed(실패)**
3. `working`(단, `workingMode == "monitoring"` 제외) → **running(서있기)**
4. `done` 또는 retained>0 → **review(하트)**
5. 그 외 → **idle(잠듦)**

## 상태 decay (시간에 따라 한 단계 강등)
| 전이 | 조건 |
|---|---|
| failed → done | 30초 경과 |
| failed → idle | 30초 + 5분 경과 |
| done → idle | 5분 경과 |
| working → idle | 15분 경과 |

프레시 게이트: `now - updatedAt <= 30분`. 확인(호버)한 done 은 더 새로운 done 이 올
때까지 idle 로 억제.

## 토큰 → 경험치 / 진화
- 누적 토큰 = 트랜스크립트 JSONL 의 `message.usage` 에서
  `input_tokens + output_tokens + cache_creation_input_tokens` 합.
  **`cache_read_input_tokens` 는 제외**(캐시 히트는 새 작업이 아님).
- 증가분만 지금 화면의 펫에게 적립(처음 보는 트랜스크립트는 기준선만 잡음).
- 진화 임계치: **stage 1 = 200,000,000 토큰**, **stage 2 = 500,000,000 토큰**.
- 경험치 바 = 다음 임계치까지의 비율(0~1), 최종 단계면 가득.
- **EXP 눈금·진화보너스는 진화 수와 무관하다.** 임계치(2억/5억)와 만렙(5억), 그리고
  대전 진화보너스(stage 0·1·2 → ×1.0·1.15·1.30, 정규화 후 최대 파워 1.0)는 **펫을
  인자로 받지 않고 토큰·stage 만 본다**. 따라서 진화가 없거나(ditto) 1진화만
  있는 펫(eevee·munchlax·diglett)도 **똑같이 최대경험치(5억)까지 쌓고, stage 2 에서
  +30% 보너스를 받는다**. 스프라이트만 마지막 진화형에서 멈출 뿐(캡), 눈금·보너스는
  2진화 펫과 동일하다. 회귀 방지: `CONNORPET_SELFTEST=evolution`.

## 진화 사슬
**모든 펫은 미진화 기본형에서 시작한다**(피카츄는 피츄부터).
`totodile→croconaw→feraligatr`, `charmander→charmeleon→charizard`,
`squirtle→wartortle→blastoise`, `geodude→graveler→golem`,
`chikorita→bayleef→meganium`, `torchic→combusken→blaziken`,
`diglett→dugtrio`, `pichu→pikachu→raichu`,
`gastly→haunter→gengar`, `munchlax→snorlax`, `tepig→pignite→emboar`,
`togepi→togetic→togekiss`,
`larvitar→pupitar→tyranitar`, `dratini→dragonair→dragonite`.
`ditto`/`bichon`/`pinkbean` 은 진화 없음.

### 이브이 분기 진화 (사용자 선택)
이브이는 진화형이 8종(`vaporeon`·`jolteon`·`flareon`·`espeon`·`umbreon`·`leafeon`·
`glaceon`·`sylveon`)이라 **고정 사슬이 없다**. 대신:
- **stage 1(2억 토큰)에 도달하고 아직 진화형을 안 고른 상태**면 펫 위에 클릭-가능
  "✨ 진화!" 말풍선(win: 트레이 풍선)을 띄운다. 누르면 **온보딩식 8종 선택 그리드**가 뜬다.
- 고른 진화형은 **기본형(`eevee`) 기준으로 저장**(성별과 같은 규칙 — 경험치와 별개 키).
  저장되면 `display_slug(eevee, stage≥1)` 이 그 진화형을 그린다. 미선택이면 스테이지가
  올라도 이브이를 유지한다.
- 진화형은 모두 **1단계**로 취급(대전 파워 역매핑 포함). stage·눈금·보너스는 다른 펫과 동일.
- 선택은 메뉴/설정에서 언제든 바꿀 수 있다(진화는 이브이에게 영구 고정이 아니다).

## 성별 (gender)
- **부화(처음 키우기 시작) 시 확률로 한 번만** 정하고, 그 뒤로는 바뀌지 않는다.
  경험치와 **완전히 별도 저장**이라 업데이트해도 경험치는 유지되고 성별만 새로 배정된다.
- **기본형 slug 기준으로 저장**(진화해도 같은 성별 — 이름과 같은 규칙).
- 암컷 확률은 포켓몬 본가 성비(PokeAPI `gender_rate`, 8분위). `-1` = 무성:
  - **1/8 암컷**(♂ 87.5%): `totodile` `charmander` `squirtle` `eevee` `chikorita`
    `torchic` `togepi` `tepig` `munchlax`
  - **4/8(50:50)**: `geodude` `gastly` `diglett` `pichu` `larvitar` `dratini` · `bichon`(비포켓몬, 50:50로 둠)
  - **무성**: `ditto` (기호 없음)
- 표시: 이름 **오른쪽**에 수컷 `♂`(파랑) / 암컷 `♀`(분홍), 무성은 기호 없음.
  맥은 호버 이름표(이름 줄)에 붙이고, 윈도우는 이름 표시가 없어 펫 오른쪽 위에 기호만 띄운다.
