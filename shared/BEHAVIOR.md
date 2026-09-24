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

## 진화 사슬
`totodile→croconaw→feraligatr`, `charmander→charmeleon→charizard`,
`squirtle→wartortle→blastoise`, `geodude→graveler→golem`,
`chikorita→bayleef→meganium`, `torchic→combusken→blaziken`,
`eevee→vaporeon`, `diglett→dugtrio`, `pikachu→raichu`,
`larvitar→pupitar→tyranitar`, `dratini→dragonair→dragonite`.
`ditto`/`togepi`/`snorlax`/`gengar`/`bichon` 은 진화 없음.
