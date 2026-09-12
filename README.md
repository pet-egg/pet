# pet

실제 [Orca](https://github.com/stablyai/orca), [Claude Code](https://claude.com/claude-code), 또는 [Claude 데스크톱 앱](https://claude.ai/download)의 프로젝트/에이전트 상태에 반응하는 데스크톱 펫 — 리아코 (Totodile), 메타몽 (Ditto), 파이리 (Charmander), 꼬부기 (Squirtle), 꼬마돌 (Geodude), 이브이 (Eevee), 치코리타 (Chikorita), 아차모 (Torchic), 토게피 (Togepi), 뚜꾸리 (Tepig), 잠만보 (Snorlax), 팬텀 (Gengar) 중 메뉴바 아이콘에서 언제든 전환 가능합니다. Orca에 임포트하는 `.codex-pet` 번들이 아니라, **완전히 별개의 macOS 앱**으로 만들었습니다. Orca/Claude Code/Claude 앱과 다른 프로세스로 떠 있으면서, 바깥에서 그 상태를 읽어옵니다. 여기에 더해, 같은 Wi-Fi에서 앱을 켜둔 사람끼리 **디지몬 다마고치 스타일 1:1 대전**도 할 수 있습니다 (아래 "같은 wifi에서 대전하기" 참고).

에이전트의 **실제 토큰 사용량**을 읽어와 펫 아래에 경험치(XP) 바로 보여주고, 경험치가 쌓이면 펫이 **진화**합니다 (리아코→크로콘→장크로다일 등). 자세한 내용은 아래 "토큰 사용량 경험치 바 & 진화" 참고.

![펫 목록](docs/pet-gallery.png)

## 설치

macOS 에서 아래 한 줄이면 됩니다 — 최신 `pet.dmg` 를 받아 `/Applications` 에 설치하고, quarantine 플래그까지 벗긴 뒤 바로 실행합니다 (이미 깔려 있으면 업데이트로 교체):

```sh
curl -fsSL "https://raw.githubusercontent.com/pet-egg/pet/main/install.sh?$(date +%s)" | bash
```

> `?$(date +%s)` 는 raw.githubusercontent.com 의 ~5분 캐시를 우회해 항상 최신 `install.sh` 를 받기 위한 것입니다.

Homebrew 를 쓴다면 (같은 결과, `brew upgrade` 로 업데이트도 됨):

```sh
brew install --cask pet-egg/pet/pet
```

> 서명·공증을 하지 않은 배포본이라, 그냥 더블클릭하면 macOS 가 "손상되었기 때문에 열 수 없음"이라며 앱을 휴지통으로 보내버립니다. 위 스크립트/Cask 가 대신 `xattr` 로 quarantine 을 제거해 이 관문을 넘겨줍니다. 손으로 설치하고 싶으면 아래 **"dmg로 빌드해서 배포하기"** 의 수동 절차를 참고하세요.

---

## 어떻게 가능한가

메뉴바 아이콘에서 상태 소스를 **Claude Desktop**(기본값), **Claude Code**, 또는 **Orca** 중 고를 수 있습니다. 모두 `AgentStatusWatching` 프로토콜을 구현한 워처가 폴링해서 최종 애니메이션을 뽑아냅니다. Claude Code/Orca 소스는 같은 우선순위 로직(`PetAnimationState.swift`의 `agentStateAnimation`, Orca의 `pet-agent-state.ts` 포팅)을 공유합니다:

1. 하나라도 `blocked`/`waiting` → **waiting** (최우선, 즉시 확정)
2. 없고 하나라도 `working` → **running**
3. 없고 하나라도 `done` → **review**
4. 아무것도 없음 → **idle**

우선순위 로직 자체는 Orca 펫과 동일하게 포팅한 것이고, 여기에 각 상태를 포켓몬 상태이상
컨셉으로 다시 스킨했습니다: `waiting`=**얼음(Freeze)**, `review`=**헤롱헤롱(Infatuation)**,
`idle`=**잠듦(Sleep)**. `running`은 원래 그대로입니다.

마우스를 올리면 **jumping**, 드래그하면 마우스를 따라 **running-left**/**running-right**.

### Claude Code 소스 (`ClaudeCodeStatusWatcher.swift`, 기본값)

Claude Code CLI는 실행 중인 프로세스마다 `~/.claude/sessions/<pid>.json`에 자기 상태를 계속 기록합니다 (`claude agents`/`claude agents --json`이 읽는 것과 같은 파일). `ConnorPet`은 이 디렉토리를 **250ms마다** 폴링해서, 살아있는 프로세스(`kill(pid, 0)`으로 확인)의 `status` 필드를 Orca와 같은 상태로 매핑한 뒤 동일한 `agentStateAnimation`에 넣습니다: `busy` → `working`(달리기), `waiting` → `blocked`(얼음, `waitingFor`에 "permission prompt" 등이 담김), 그 외 → `idle`(잠듦). 이 세션 파일은 Claude Code가 **항상 현재값으로 갱신**하고 PID로 키를 잡으므로, 죽은 세션이 유령처럼 남지 않습니다(alive 체크로 걸러짐). 열려있는 **모든** Claude Code 세션(프로젝트 무관)을 집계하는 것도 Orca 소스와 동일합니다.

여기에 더해, 워처는 각 세션의 **`busy → idle` 전이**(턴이 끝나는 바로 그 순간 — Stop 훅이 발화하는 것과 같은 엣지)를 폴링으로 직접 감지해 `done`(헤롱헤롱)을 만듭니다. 그리고 그 시점에 세션 트랜스크립트의 꼬리를 읽어 **마지막 `tool_result`가 에러면 `failed`(실패)**로 올립니다(`lastToolErrored`, 아래 훅 스크립트의 `last_tool_errored`를 Swift로 포팅). 즉 **달리기·얼음·잠듦·헤롱헤롱·실패 다섯 상태 모두 훅 하나 없이 세션 파일만으로** 나옵니다.

> **알아둘 점**: 예전에는 이 세션 파일이 `busy`/`idle`만 안정적으로 채운다고 봤지만, 버전 2.1.197에서 `status: "waiting"` + `waitingFor: "permission prompt"`(권한 승인 대기)가 실제로 채워지는 것을 확인했습니다. 그래서 얼음(권한 대기)까지 세션 파일만으로 표시되고, 헤롱헤롱/실패는 위의 엣지 감지로 만들어내므로 — **모든 상태가 훅 없이** 나옵니다.

> **Orca가 띄운 세션은 제외합니다**: Orca 패널에서 실행한 Claude도 결국 같은 `claude` 프로세스라 `~/.claude/sessions/`에 자기 파일을 씁니다. 그대로 두면 이 소스와 Orca 소스가 같은 세션을 **이중으로** 잡으므로, Claude Code 소스는 Orca 자신의 `last-status.json`을 읽어 그 안의 `providerSession.id`(=sessionId)에 해당하는 세션을 건너뜁니다. 결과적으로 **"Claude Code" = 터미널/독립 실행 세션, "Orca" = Orca 세션**으로 깔끔히 나뉩니다. Orca가 미설치면(파일 없음) 아무것도 제외하지 않아 종전과 동일합니다. Orca는 훅마다 `last-status.json`을 다시 써서 활성 세션의 `id`가 매 스냅샷에 있진 않으므로, sessionId는 세션당 고유하다는 점을 이용해 **"Orca가 한 번이라도 보고한 id"를 누적**해 제외합니다(세션파일이 사라지면 목록에서 정리).

#### Claude Code 훅 (이제 완전히 선택 사항)

달리기·얼음·잠듦·헤롱헤롱·실패는 위에서 설명한 대로 **세션 파일 + 엣지 감지만으로 이미 다 표시됩니다.** 그래도 아래 훅을 설치할 수 있는데, 이제 유일한 이점은 **앱이 꺼져 있던 동안 끝난 턴의 헤롱헤롱/실패가 앱을 다시 켰을 때도 보이는 것**뿐입니다(엣지는 앱이 켜져 있어야 관찰되므로). 훅은 `~/.claude/pet-status.json`에 `done`/`failed`만 기록하고, 워처는 그 세션이 `idle`일 때 자신이 감지한 것 대신(있으면) 훅 값을 씁니다. `ConnorPet`이 사용자 동의 없이 자동으로 설정하지는 않습니다(전역 `~/.claude/settings.json`을 건드리는 일이라 명시적으로 동의한 경우에만 건드리는 게 맞다고 판단했습니다).

**메뉴바 버튼으로 설치 (DMG/앱 사용자 권장)** — 메뉴바 아이콘 메뉴의 **"Claude Code 상태 훅 (헤롱헤롱/실패)"** 을 누르면 바로 설치됩니다. DMG로 설치해 터미널에서 스크립트를 돌릴 수 없는 경우를 위한 경로로, 앱이 번들에 넣어 둔 훅 핸들러를 `~/.claude/pet/pet_hook_status.py`로 복사한 뒤 아래 스크립트와 **똑같은 2개 훅**을 병합합니다(설치 전 확인 창이 뜨고, 기존 `settings.json`은 백업합니다). 체크 표시로 현재 설치 여부를 알 수 있고, 다시 누르면 우리가 추가한 항목만 제거합니다. 예전 6개 훅 설치가 남아 있으면 다시 누를 때 자동으로 2개로 정리(마이그레이션)됩니다. (훅 핸들러는 `python3`로 실행되므로 `python3`가 필요합니다.)

**스크립트로 설치** — 저장소를 클론해 쓰는 경우. 필요한 2개 훅을 `~/.claude/settings.json`에 병합해줍니다. 이미 있는 다른 훅(matcher가 걸린 것 포함)은 절대 건드리지 않고, 이 저장소가 어디 클론됐든 경로도 알아서 맞춰줍니다. 실행 전 기존 파일을 타임스탬프 붙여 백업하고, 몇 번을 다시 실행해도 (예전 6개 훅이 있었다면 2개로 정리하며) 항상 같은 상태로 수렴합니다:

```sh
python3 scripts/install_claude_hooks.py             # 설치 (또는 예전 훅 마이그레이션)
python3 scripts/install_claude_hooks.py --uninstall  # connor-pet이 추가한 항목만 제거
```

**수동 설치**를 원하면 `~/.claude/settings.json`에 아래 내용을 직접 추가해도 됩니다 (이미 다른 `hooks`가 있다면 이벤트별로 병합, 경로는 이 저장소를 클론한 실제 위치로):

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "python3 /path/to/pet/scripts/pet_hook_status.py done" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "python3 /path/to/pet/scripts/pet_hook_status.py remove" }] }
    ]
  }
}
```

경로는 이 저장소를 클론한 실제 위치로 바꿔야 합니다. 각 훅이 하는 일:

| 훅 | 발생 시점 | 기록하는 상태 |
|---|---|---|
| `Stop` | 에이전트가 턴을 마치고 제어권을 사용자에게 돌려줌 | `done` → **헤롱헤롱** (마지막 도구가 실패했으면 `failed` → **실패**) |
| `SessionEnd` | 세션 종료 | 해당 항목 제거 |

> 예전 버전은 여기에 `UserPromptSubmit`/`PreToolUse`(→`working`)와 `PermissionRequest`/`Notification`(→`blocked`)까지 6개를 걸었지만, 달리기/얼음은 이제 세션 파일에서 직접 나오므로 지웠습니다. 재설치하면 남아 있던 옛 훅은 자동으로 정리됩니다. 정리 전이라도, `pet_hook_status.py`는 모르는 인자(`working`/`blocked` 등)로 불리면 **조용히 아무것도 안 하고 종료(exit 0)**하므로 남은 옛 훅이 에러를 뿜지 않습니다 — 스크립트 경로 자체가 깨진 경우(저장소 이동/삭제)만은 스크립트가 못 돌아 재설치/제거가 필요합니다(앱 설치 사용자는 안정 경로 `~/.claude/pet/`를 써서 안 깨집니다).

#### 실패와 시간 감쇠

세션 파일에서 판정한 상태 위에 두 가지가 더 얹혀 있습니다.

**도구 실패 → `failed`(붉은 떨림).** 도구가 실패해도 그건 세션 파일의 `status`에도, 별도 훅
이벤트로도(PostToolUse 훅은 **도구가 실패하면 발화하지 않습니다** — 실제 세션에서 확인) 도달하지
않습니다. 유일하게 남는 곳이 트랜스크립트라, `busy → idle` 엣지를 감지한 그 순간 세션의
트랜스크립트 꼬리를 읽어 가장 마지막 `tool_result`의 `is_error`를 봅니다 — 참이면 `done`을
`failed`로 올립니다. 마지막 것만 보는 이유는, 실패했다가 다시 시도해 성공한 도구는 사용자가
볼 필요가 없고 마지막 도구가 실패한 채로 끝난 턴은 봐야 하기 때문입니다. 트랜스크립트는
수십 MB 라서 끝에서 256KB 만 seek 해서 읽습니다 (31MB 파일 기준 1ms). 이 판정은 워처
안의 `lastToolErrored`(Swift)와 훅 스크립트의 `last_tool_errored`(Python)가 **같은 규칙으로**
합니다 — 훅을 깔았든 안 깔았든 "실패"의 정의가 같도록.

**시간이 지나면 상태가 내려갑니다** — `failed` 30초 → `done`, `done` 5분 → 잠듦.
이 판단은 훅이 아니라 **읽는 쪽(`PetAnimationState.swift` 의 `decayStaleStates`)** 이 합니다.
훅은 세션이 살아 있을 때만 발화하므로, 마지막 세션이 끝나면 파일을 갱신할 주체가 없어져
시간 기반 판단을 쓸 수가 없습니다. 워처는 어차피 폴링하고 있으니 거기서 판단하면 공짜이고,
Orca 소스에도 똑같이 적용됩니다. `달리기(working)`·`얼음(blocked)`은 세션 파일이 매 순간
현재값으로 갱신하므로(레벨 트리거) 감쇠 규칙이 따로 필요 없습니다.

`scripts/pet_hook_status.py`(선택 설치 시)는 각 훅이 stdin으로 받는 JSON(`session_id`/`cwd`/`transcript_path` 포함)을 읽어서 `~/.claude/pet-status.json`을 Orca의 `last-status.json`과 같은 형태로 갱신합니다(동시에 여러 세션이 훅을 발생시켜도 안전하도록 `fcntl.flock`으로 잠그고 원자적으로 씀). `ClaudeCodeStatusWatcher`에서 **권위 소스는 세션 파일**입니다: 달리기/얼음/잠듦은 세션 파일이 정하고, 헤롱헤롱/실패는 워처가 `busy → idle` 엣지에서 직접 만들며, 훅 파일이 있으면 그 세션이 `idle`일 때만 워처가 감지한 것 대신 훅 값으로 덧씌웁니다(살아있는 세션에 대응하는 항목이 없는 훅 항목은 버립니다). 오버레이는 절대 `working`/`blocked`를 강제할 수 없어서, 낡은 훅 항목이 진행 중인 세션을 얼려버리던 예전 버그가 사라졌습니다 — **훅을 설정 안 해도 다섯 상태가 모두 나오고**, 설정하면 앱이 꺼져 있던 동안 끝난 턴의 헤롱헤롱/실패까지 재시작 후에 보이는 것만 더해집니다.

**헤롱헤롱이 사라지는 시점**: `done`은 그 세션이 다시 `working`으로 바뀌기 전까지, 또는 **펫에 마우스를 올리기 전까지** 유지됩니다(둘 중 먼저 오는 쪽). 펫을 호버하면 `AgentStatusWatching.acknowledgeDone()`이 호출되어 그 시점 이전의 `done`은 전부 "확인함" 처리되고, 그 이후에 새로 `done`이 찍히면 다시 나타납니다 — Stop 이벤트 하나가 무한히 헤롱헤롱을 유지하지 않도록 하는 장치입니다.

### Claude Desktop 소스 (`ClaudeDesktopStatusWatcher.swift`)

CLI가 아니라 **Claude 데스크톱 앱**(`com.anthropic.claudefordesktop`)의 상태를 읽습니다. 이 앱은
CLI와 달리 상태를 파일로 남기지 않고(대화 상태는 Electron 메모리/LevelDB/IndexedDB 안), **디버그·
네트워크 우회 스위치가 붙으면 실행 자체를 거부**해서 CDP(원격 디버깅)·프록시 가로채기도 막혀 있습니다.
바깥에서 세션별 상태를 읽을 수 있는 유일한 정식 통로는 **접근성(Accessibility) 트리**였습니다. 여기에
알림센터 신호를 얹어 상태를 만듭니다. 500ms마다 폴링하고, 우선순위는 아래와 같습니다:

1. Claude 앱 미실행 → **idle(잠듦)**
2. **도구/권한 승인 대기**(허용·거부 카드) → **waiting(얼음)** — *신호 3*
3. 응답 생성 중 → **running(달리기)** — *신호 1*
4. 방금 턴이 끝남(미확인) → **review(헤롱헤롱)** — *신호 1의 하강엣지 + 신호 2*
5. 그 외 → **idle(잠듦)**

즉 얼음은 **네가 지금 허용/거부를 눌러 줘야 하는 승인 대기**일 때만 뜹니다. Claude를 켜둔 채 다른 앱을
보고 있어도(백그라운드) 얼음이 아니라 잠듦입니다 — Claude Code/Orca 소스에서 얼음이 "너를 기다림"을
뜻하는 것과 결을 맞춥니다.

**신호 1 — "생성 중인가" (접근성 트리, `ClaudeAXProbe`)**: Claude는 Electron 앱이라 기본 상태에선 AX
트리에 네이티브 메뉴만 보이고 웹 콘텐츠가 안 뜹니다. 하지만 외부 프로세스가 앱 요소에
`AXManualAccessibility = true` 를 세팅하면 Chromium이 웹 콘텐츠의 AX 트리를 만들어 줍니다(예전에
"AX로는 안 보인다"고 판단했던 건 이 플래그를 안 켰기 때문). 트리를 켜면 응답이 스트리밍되는 동안에만
**"응답 중단"(Stop response) 버튼**이 대화 창에 존재하고 턴이 끝나는 순간 사라집니다 — 이 버튼의
존재 여부가 곧 "생성 중"이고, 그 하강엣지(버튼이 사라진 순간)가 "턴 종료 = 헤롱헤롱"입니다. 버튼
레이블은 원격 웹앱이 계정 언어로 렌더하므로 로케일 의존이라, 한국어·영어 문자열을 매칭 목록으로
둡니다(`stopResponseLabels`). 메뉴바(197개)는 건너뛰고 창 서브트리만 노드 수 상한을 두고 훑어 2Hz
폴링이 가벼운데도 Claude에 부담을 주지 않습니다.

Chromium은 이 웹 AX 트리를 **비동기로(창이 뜨고도 2~3초 뒤) 만들고**, 렌더러가 리로드되면 잠깐
날렸다 다시 만듭니다. 이 "트리 공백" 구간엔 창은 읽히지만 웹 버튼이 하나도 없는데, 이걸 "생성 아님 +
승인 아님"으로 확정해 버리면 **Claude를 막 연 직후** 첫 턴·승인 카드를 놓치고 직전 턴의 헤롱헤롱이
그대로 남는 버그가 있었습니다. 그래서 `sample()`은 **창은 있는데 버튼이 0개면**(=트리 미완성) 값을
확정하지 않고 `nil`(판단 불가)을 돌려주며 `AXManualAccessibility`를 다시 세팅하고(같은 pid라 pid 기반
강제는 안 걸리므로), 워처는 그 구간엔 **직전 애니메이션을 유지**해 가짜 전이를 막습니다. 트리는 보통
한두 폴 안에 다시 잡힙니다(창이 아예 없거나 권한이 없는 건 트리 공백이 아니라 그냥 잠듦/degraded로 처리).

이 신호는 **손쉬운 사용(Accessibility) 권한**이 필요합니다. 워처가 켜질 때 권한이 없으면 시스템 권한
요청을 한 번 띄우고, 권한이 없는 동안엔 "생성 중" 감지만 빠진 채(실행/포그라운드 + 알림 기반 완료로)
계속 동작합니다. `시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용`에서 `ConnorPet`을 켜면 재실행
없이 바로 반영됩니다.

**신호 2 — "끝났나" (알림센터 DB, `NotificationCenterDB.swift`)**: Claude 앱이 완료 시 띄우는 macOS
알림(설정 → 알림에서 켜야 함)을 `$DARWIN_USER_DIR/com.apple.notificationcenter/db2/db`(SQLite)에서
읽습니다. `com.anthropic.claudefordesktop` 앱의 새 레코드가 뜨면 "완료"로 봅니다. 실측상 **짧은
채팅 응답에는 지속 알림이 안 남고 긴/에이전트 작업에만** 남기 때문에, 이 신호는 신호 1의 AX
하강엣지(스트리밍이 멈춘 순간 = 턴 종료)를 **확정해주는 보조 신호**로 얹었습니다 — 둘 중 하나만
떠도 헤롱헤롱이 됩니다. 이 DB를 읽으려면 앱에 **전체 디스크 접근(Full Disk Access)** 권한이 필요하고,
권한이 없으면 알림 신호만 빠지고 나머지(AX 기반 완료 감지 포함)는 그대로 동작합니다.

**신호 3 — "승인 기다리는가" (접근성 트리, `ClaudeAXProbe`)**: MCP/도구 호출이나 권한처럼 Claude가
사용자의 **허용/거부**를 기다릴 때, AX 트리에 승인 카드가 뜹니다. 이를 **허용 계열 버튼(`허용`/`Allow`)과
거부 계열 버튼(`거부`/`Deny`)이 동시에 존재**하는지로 감지합니다(둘 다 있어야 승인 카드로 판정 —
설정 어딘가의 단독 "허용" 토글에 오탐하지 않도록). 승인 대기 중에도 **"응답 중단" 버튼은 그대로
남아 있어**(턴 전체를 취소할 수 있으니) 신호 1과 동시에 참이 되는데, 사용자가 지금 눌러 줘야 하는
쪽이 승인이므로 **신호 3이 신호 1보다 우선**해서 얼음이 됩니다. 이 신호도 손쉬운 사용 권한을 씁니다.

권한을 켜려면 메뉴바 아이콘 메뉴의 **"전체 디스크 접근 권한 (헤롱헤롱 알림)"** 을 누르면 됩니다 — 앱이
`시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근` 창을 바로 열어주니, 거기서 `ConnorPet`을 켜고
**앱을 다시 실행**하면 됩니다(이 권한만은 재실행해야 반영됩니다). 메뉴 항목의 체크 표시가 현재 권한
상태를 보여줍니다.

**헤롱헤롱이 사라지는 시점**: Claude Code 소스와 동일하게 **펫에 마우스를 올리면**(`acknowledgeDone()`)
확인 처리되어 사라지고, 새 턴이 시작되거나 안전 타임아웃(기본 5분)이 지나도 해제됩니다.

> **왜 접근성 트리인가**: 데스크톱 앱은 상태를 디스크에 안 남기고 CDP·프록시도 막아 두어, 세션별
> "생성 중"을 정확히 읽을 수 있는 외부 신호가 AX뿐이었습니다("응답 중단" 버튼이라는 semantic
> 신호라 예전의 CPU 휴리스틱보다 훨씬 정확). 권한(손쉬운 사용)이 필요한 대신, 스크롤·레이아웃
> 같은 잡음에 흔들리지 않습니다.

### Orca 소스 (`OrcaStatusWatcher.swift`)

Orca의 훅 서버는 열려있는 모든 에이전트 패널의 상태를 250ms 디바운스로 디스크에 계속 저장합니다 (`src/main/agent-hooks/server/server-persistence.ts`):

```
~/Library/Application Support/Orca/agent-hooks/last-status.json
```

이 파일은 Orca 자신도 재시작 후 상태를 복구할 때 쓰는 파일이라, 바깥에서 읽어도 안전한 정식 대상입니다(해킹이 아님). 대략적인 모양:

```json
{
  "version": 2,
  "entries": {
    "<paneKey>": {
      "state": "working" | "blocked" | "waiting" | "done",
      "worktreeId": "...",
      "receivedAt": 1735000000000
    }
  }
}
```

> **주의 (실제로 부딪힌 문제)**: 실제 파일을 열어보면 항목마다 모양이 다릅니다. 예를 들어 `SubagentStop` 훅에서 온 항목은 `state`/`prompt`/`agentType`이 최상위가 아니라 `payload` 안에 중첩되어 있었습니다. 처음엔 엄격한 Codable 구조체로 파싱했는데, 이 경우 항목 하나가 예상과 다른 모양이면 **파일 전체 파싱이 실패**해서 모든 패널의 상태가 조용히 사라지는 버그가 있었습니다. 지금은 `JSONSerialization`으로 느슨하게 파싱하면서 항목마다 최상위/`payload` 둘 다 확인하도록 고쳤습니다 (`OrcaStatusWatcher.swift`).

`ConnorPet`은 이 파일을 1초마다 폴링(Orca 자신의 쓰기 주기보다 넉넉함)해서, Orca 펫이 쓰는 것과 같은 우선순위 로직(`pet-agent-state.ts`의 `agentStateAnimation`)을 열려있는 **모든** 프로젝트/패널에 대해 그대로 돌립니다:

1. 하나라도 `blocked`/`waiting` → **waiting** (최우선, 즉시 확정)
2. 없고 하나라도 `working` → **running**
3. 없고 하나라도 `done` → **review**
4. 아무것도 없음 → **idle**

우선순위 로직 자체는 Orca 펫과 동일하게 포팅한 것이고, 여기에 각 상태를 포켓몬 상태이상
컨셉으로 다시 스킨했습니다: `waiting`=**얼음(Freeze)**, `review`=**헤롱헤롱(Infatuation)**,
`idle`=**잠듦(Sleep)**. `running`은 원래 그대로입니다.

여기에 Orca 에는 없는 `failed` 상태를 하나 더 두었습니다 — 도구가 에러를 반환했을 때
붉게 떨리는 모션입니다. 우선순위는 `waiting` 바로 아래로, 다른 패널이 돌고 있어도
실패가 묻히지 않습니다.

마우스를 올리면 **jumping**, 드래그하면 마우스를 따라 **running-left**/**running-right**.
`ConnorPet`은 이 파일을 1초마다 폴링(Orca 자신의 쓰기 주기보다 넉넉함)합니다.

### 클릭 / 우클릭

- **좌클릭** — 최근 작업을 브리핑합니다 (아래 "클릭하면 브리핑" 참고). 말하는 동안에는
  **waving** 모션이 재생되고, 말풍선이 떠 있을 때 한 번 더 누르면 닫힙니다.
- **우클릭** — 모션 메뉴. 모션을 직접 골라 고정 재생할 수 있어 에이전트 상태를
  기다리지 않고 확인할 수 있습니다. **고정은 60초 뒤 저절로 풀려** 다시 실시간
  상태를 따릅니다(`자동`을 고르면 기다리지 않고 바로 풀립니다). 손으로 풀 때까지
  남겨 두면 눌러 둔 자세로 펫이 굳어 버리고, 작업이 도는지 보려고 띄운 물건이
  정작 상태를 안 보여 주게 됩니다. 이 펫의 매니페스트에 없는 행은 보이지 않습니다.
- **우클릭 → `s`** — 말하기. 좌클릭과 같은 브리핑인데 펫을 정확히 클릭할 필요가
  없습니다.
- 자고 있을 때 말을 걸면 **먼저 깨어납니다** — 점프 모션을 한 번 재생하고 그게
  끝나면 말풍선이 뜹니다. 잠든 채로 말풍선만 뜨면 깨어난 느낌이 없기 때문입니다.
  자고 있지 않으면 곧장 말합니다. 좌클릭과 `s` 둘 다 같은 경로입니다.
- **우클릭 → `a`** — 불뿜기 (파이리 전용, 아래 참고).

단축키가 붙은 두 항목은 고정 재생이 아니라 그 자리에서 한 번 실행되는 **동작**이고,
끝나면 원래 상태로 돌아갑니다. 나머지 모션은 고르면 그 자세로 고정되고, 60초 뒤
자동으로 풀립니다. 해제 타이머는 `.common` 실행 루프 모드에 겁니다 — 기본 모드로만
걸면 메뉴가 열려 있거나 펫을 끌고 있는 동안 시계가 멈춰서, 손을 떼기 전까지 영영
풀리지 않습니다.

- **우클릭 → `설정…`(⌘,)** — 설정 창을 엽니다 (아래 "설정 창" 참고). 모션 메뉴
  맨 아래, **나가** 바로 위에 있습니다.

메뉴 맨 아래 **나가**로 앱을 끌 수 있습니다(메뉴바 아이콘의 Quit 과 같습니다).
여기에는 일부러 단축키를 붙이지 않았습니다 — 메뉴가 열린 상태에서는 글자 키가 그대로
먹기 때문에(`a`/`s` 가 그렇게 동작합니다) 종료에까지 달면 오타 한 번에 앱이 꺼집니다.
- 드래그와 클릭은 이동 거리로 구분합니다(움직였으면 드래그, 아니면 클릭).

### 설정 창 (`SettingsWindow.swift`)

메뉴바 아이콘은 노치가 있거나 상태 아이콘이 많은 화면에서는 가려져 접근이 안 될
수 있습니다. 그래서 **펫 우클릭 → `설정…`(⌘,)** 으로 여는 설정 창을 두 번째
진입점으로 두어, 메뉴바 아이템에 흩어져 있던 기능을 한 창에 모았습니다:

- **펫** — 펫 선택, 진화 사용, 경험치 바 항상 표시, 모든 경험치 초기화
- **상태 소스** — Claude Code / Orca / Claude Desktop
- **연동** — Claude Code 상태 훅(얼음/헤롱헤롱) 설치, 전체 디스크 접근 권한 열기
- **대전 / 노려보기** — 같은 Wi-Fi에서 발견된 상대에게 대전 신청·노려보기
- **앱** — ConnorPet 종료

메뉴바 메뉴와 **완전히 같은 코드 경로**(`SettingsActionsDelegate`)를 타므로, 어느
쪽에서 바꾸든 동작·저장·다른 쪽 갱신이 동일합니다. 창이 떠 있는 동안 대전 상대가
새로 발견되거나 훅/권한 상태가 바뀌면 자동으로 다시 그려집니다. 룩은 macOS 시스템
설정·Linear 계열의 **무채색 그룹 카드**(둥근 카드 + 섹션 제목 + 행별 라벨/컨트롤)로,
색은 전부 시스템 그레이라 라이트/다크 모드에 자동으로 맞춰집니다. 켜짐 스위치도
시스템 accent 색(환경에 따라 초록 등) 대신 채도를 제거해 항상 그레이(그래파이트)로
보이게 맞췄습니다.

### 상태별로 실제 어떻게 보이는지

리아코 기준 예시입니다 (다른 펫도 스프라이트만 다를 뿐 동일한 리스킨 로직을 그대로 씁니다):

![idle / running / waiting / review](docs/pet-states.png)

- **idle → 잠듦**: 채도/밝기를 크게 낮추고 위로 떠오르며 사라지는 "Zzz"를 얹었습니다. 할 일이
  없을 때는 그냥 자고 있는 걸로.
- **running**: 색 변화 없이 빠른 바운스 루프 그대로 — 변경 없음.
- **waiting → 얼음**: 한 포즈에 고정(=멈춰있음)하고 각진 얼음 결정 오버레이(모서리에 삐죽
  튀어나온 조각 포함)를 씌웠습니다. 채도만 낮췄던 이전 버전보다 "완전히 멈췄음"이 훨씬 명확하게
  전달됩니다.
- **review → 헤롱헤롱**: 골드 톤 대신 핑크 톤 + 떠오르는 하트 이펙트로, "일 끝났다"는 긍정적인
  뉘앙스를 상태이상 컨셉 안에서 표현했습니다.

전부 `scripts/build_sheet.py`의 `tint()`/`desaturate()`에 더해 `draw_ice_crystal()`/
`draw_hearts()`/`draw_zzz()`로 PNG에 직접 구운 것이라, Swift 쪽 코드는 건드리지 않았습니다
(애니메이션 우선순위/재생 로직은 그대로, 스프라이트 픽셀만 다시 구운 것).

## 같은 wifi에서 대전하기 (디지몬 다마고치 스타일)

같은 Wi-Fi에 이 앱을 켜둔 사람끼리 **1:1 대전**을 할 수 있습니다 — 디지몬 다마고치처럼 대전 신청 → 상대가 수락 → 양쪽이 동시에 같은 대전 화면을 봅니다. 대전이 **업무를 방해하지 않도록**, 신청 흐름은 갑작스러운 가운데 모달 대신 작은 말풍선·카운트다운으로 시작합니다.

- 메뉴바 아이콘 → **대전** 서브메뉴에 같은 Wi-Fi에서 실행 중인 다른 앱들이 뜹니다 (없으면 "주변에 상대가 없어요").
- 상대를 고르면 **신청한 쪽**에는 펫 위에 **20초 동안 줄어드는 카운트다운 막대**가 뜹니다. 상대가 수락/거절하면 곧바로 사라지고, 20초 안에 응답이 없으면 **"응답하지 않음"** 안내가 뜹니다.
- **신청받은 쪽**에는 처음부터 가운데 모달이 뜨는 게 아니라, 펫 **오른쪽 위에 작은 흰색 "Challenge" 말풍선**이 **10초간** 뜹니다. 이 말풍선을 **누르면** 그때 예전처럼 가운데 **수락/거절 모달**이 뜨고, 그 모달도 **10초** 안에 수락/거절하지 않으면 스스로 닫혀 무응답으로 처리됩니다. 말풍선을 누르지 않고 10초가 지나도 똑같이 조용히 사라집니다. 어느 쪽이든 신청자 쪽 카운트다운(말풍선 10초 + 모달 10초 = 최대 20초)이 끝나며 "응답하지 않음"으로 정리됩니다.
- 수락하면 양쪽 화면에 디지몬 다마고치 같은 **작은 대전 화면**이 뜹니다. **한 번에 펫 하나만** 나오고(내 펫은 왼쪽 끝에서 오른쪽으로, 상대 펫은 오른쪽 끝에서 왼쪽으로 **불꽃 발사체**를 쏨), 발사체가 화면 밖으로 나가면 **화면이 전환**되어 상대 펫이 등장해 발사체가 반대편에서 들어옵니다. 방어자는 가끔 **회피**(뒤돌아 백홉)해서 발사체가 지나가고, HP를 다 깎으면 **WIN!/LOSE**로 승패를 보여줍니다. 한 번에 한 턴씩 번갈아 진행합니다.

서버가 필요 없습니다. Apple의 **Network.framework**만 씁니다:

- **발견**: 각 앱이 `_connorpet._tcp` Bonjour 서비스를 광고(`NWListener`)하고 동시에 탐색(`NWBrowser`)합니다. TXT 레코드에 인스턴스 UUID·표시 이름·펫 슬러그를 실어, 자기 자신은 걸러내고 상대의 캐릭터까지 그대로 그립니다.
- **핸드셰이크**: 신청/수락/거절은 하나의 TCP 연결(`NWConnection`) 위에서 length-prefixed JSON으로 주고받습니다 (`BattleService.swift`).
- **결정론적 대전**: 수락하는 쪽이 랜덤 `seed` 하나를 정해 보내면, **양쪽이 그 seed로 똑같은 시뮬레이션**(`BattleSimulation.swift`)을 돌려 동일한 라운드·명중/회피·승패를 계산합니다. 프레임 단위 동기화가 필요 없어서(서로 믿을 필요도 없이) 양쪽 화면이 정확히 같은 결과를 냅니다. 역할(신청자=challenger / 수락자=accepter)이 고정이라 누가 어느 쪽에 서는지도 양쪽이 일치합니다. 승패 난수는 **직접 구현한 seed 고정 정수 PRNG**를 씁니다 — 표준 `random(in:using:)`이나 GameplayKit은 Swift 버전·기기 간 결과가 달라질 수 있어(문서로 확인) 락스텝 대전엔 부적합하기 때문입니다.

> **네트워크 주의**: 게스트/회사 Wi-Fi 중 "클라이언트 격리(AP isolation)"가 켜진 곳에서는 같은 네트워크라도 기기끼리 서로 못 봅니다. 그럴 땐 집 Wi-Fi나 핫스팟에서 테스트하세요. macOS 15(Sequoia)부터는 로컬 네트워크 접근 권한 팝업이 뜰 수 있습니다(허용해야 발견됩니다).

핸드셰이크 로직은 실제 앱 없이 헤드리스로 검증할 수 있습니다 — 한 프로세스에서 두 서비스를 띄워 발견→신청→수락→결과 합의까지 확인하고 `SELFTEST PASS`를 찍습니다:

```sh
cd ConnorPet
CONNORPET_SELFTEST=battle swift run
```

## 토큰 사용량 경험치 바 & 진화

에이전트가 토큰을 쓸수록 펫이 "경험치"를 쌓아 진화하는 게임 메커닉을 얹었습니다. 세 부분으로 나뉩니다.

### 1. 토큰 사용량은 어디서 오나 (Claude Code / Orca 공통)

Claude Code는 세션마다 전체 대화 기록을 `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` **트랜스크립트**에 남기고, 각 어시스턴트 메시지의 `message.usage`에 실제 토큰 수(input/output/cache)가 들어있습니다. 세션 파일(`sessions/*.json`)이나 Orca의 `last-status.json` 자체에는 토큰 수가 없어서, 이 트랜스크립트가 유일한 소스입니다.

- **Claude Code 소스**: 살아있는 세션마다 `sessionId`로 트랜스크립트 경로를 찾아(글롭) 합산합니다.
- **Orca 소스**: `last-status.json`의 각 항목이 `providerSession.transcriptPath`로 트랜스크립트 경로를 직접 알려주므로 그대로 읽습니다.

두 소스 모두 `TranscriptTokenReader`(`TokenUsage.swift`)가 파일 수정시각(mtime) 기준으로 캐시하면서, 메시지별 `input + output + cache_creation` 토큰을 누적합니다(문맥을 매 턴 다시 읽는 `cache_read`는 값이 폭증하므로 제외). 살아있는 모든 세션/패널의 합이 곧 경험치입니다.

### 2. 경험치 바 (펫 **아래**)

경험치 바는 펫 **아래**에 그립니다. 게임 UI 관례상 위에 뜨는 바(오버헤드 바)는 체력/상태(LoL 유닛 체력바, RTS 네임플레이트 등)를 뜻하고, 진행도/경험치 바는 화면 하단 HUD에 놓는 것이 표준입니다(WoW 경험치 바 등). 위쪽은 이미 스프라이트의 하트·Zzz·얼음 이펙트가 떠오르는 자리라 시각적으로도 아래가 맞습니다.

바는 **다음 진화까지의 진행률**만큼 채워지고, **채움 색은 진화 단계**를 나타냅니다 — 0단계=초록, 1단계=파랑, 2단계=골드. 마우스를 올리면 펫 아래에 `EXP 15,000,000 / 200,000,000 - 7.50%` 처럼 실제 수치가 뜹니다(분모는 **다음 진화 지점**이라 진화할 때마다 올라가고, 최종 단계에서는 `EXP … - MAX`).

  이 문구는 펫 창 안이 아니라 **별도 창**(`XPDetailWindow`)에 그립니다. 기본형 펫의
  창은 90pt 인데 문구는 200pt 가 넘어서, 펫 창 안에 그리면 뷰가 잘라 버린 채
  `EXP 13,147,288 / 2` 로만 보였습니다. 숫자를 축약하면 들어가지만 실제 값을
  확인하려고 띄우는 문구라 줄이면 의미가 없습니다. 이 창은 `ignoresMouseEvents`
  라 펫의 호버 판정을 가로채지 않습니다 — 마우스를 먹으면 커서가 펫에서 벗어난
  것으로 처리돼 문구가 깜빡입니다.

  기준이 최종 진화(5억)가 아니라 다음 진화인 이유는, 1단계를 갓 지난 시점에도 바가 40%에 머물러 있어 다음 진화가 얼마나 남았는지 읽히지 않았기 때문입니다. 단계마다 다시 차오르는 편이 알아보기 쉽습니다.

### 3. Doc(메뉴바) 아이콘 메뉴 설정

메뉴바 아이콘 메뉴에서 세 가지를 조절합니다(모두 다음 실행에도 복원):

- **"경험치 바 항상 표시"** (체크, 기본 켜짐): 켜면 바가 항상 보이고, 끄면 펫에 **마우스를 올렸을 때만** 나타납니다.
- **"진화 사용"** (체크, 기본 꺼짐): 켜면 경험치 %에 따라 펫이 진화형 스프라이트로 자동 교체되고, 꺼져 있으면(기본값) 경험치가 아무리 쌓여도 펫이 **기본 형태**로 고정됩니다(경험치 바 색도 0단계 색 유지). 진화하지 않게 두고 싶으면 이 토글만 끄면 됩니다.
- **"모든 경험치 초기화"**: 모든 펫의 누적 경험치를 지웁니다. 진화 단계는 경험치에서
  계산되므로 같이 풀리고, 진화형을 보고 있었다면 기본형으로 되돌아갑니다. 되돌릴 수
  없어서 확인 창이 먼저 뜨고, 기본 버튼이 "취소"라 실수로 Return 을 눌러도 진행되지
  않습니다.

### 4. 진화 (경험치 %에 따라)

**"진화 사용" 토글이 켜져 있을 때** 경험치 %가 임계치를 넘으면 펫이 다음 진화형으로 자동 교체됩니다(토글은 기본 꺼짐 — 켜야 아래 동작이 활성화됩니다). 사용자가 메뉴에서 고른 **기본 펫은 그대로 유지**되고, 화면에 그려지는 스프라이트만 진화형으로 바뀝니다(진화형은 메뉴에 별도로 노출되지 않습니다).

- 진화 지점은 **비율이 아니라 실제 토큰 수**로 고정돼 있습니다 (`XPModel.stageTokens`) — **2억 토큰**에서 1단계, **5억 토큰**에서 2단계. 바가 가득 차는 기준(`maxTokens`)은 마지막 진화 지점과 같아서, 바가 꽉 차는 순간이 최종 진화 시점입니다.

  예전에는 "바 만렙 100만 토큰의 10%/30%" 였는데, 실측 하루 사용량이 (입력+출력+캐시생성 기준) 1,500만이라 앱을 켜자마자 바가 가득 차고 **1단계를 건너뛰어 곧장 2단계로** 갔습니다. 1단계 진화형을 볼 수가 없었습니다. 지금 기준이면 1단계까지 약 2주, 2단계까지 약 5주입니다.
- 진화 체인은 다음 도감 번호를 그대로 씁니다(메타몽·토게피·잠만보·팬텀은 진화 없음, 이브이는 데모용으로 샤미드 1단계만):

  | 기본 | 1단계 | 2단계 |
  |---|---|---|
  | 리아코 (Totodile) | 크로콘 (Croconaw) | 장크로다일 (Feraligatr) |
  | 파이리 (Charmander) | 리자드 (Charmeleon) | 리자몽 (Charizard) |
  | 꼬부기 (Squirtle) | 어니부기 (Wartortle) | 거북왕 (Blastoise) |
  | 꼬마돌 (Geodude) | 데구리 (Graveler) | 딱구리 (Golem) |
  | 치코리타 (Chikorita) | 베이리프 (Bayleef) | 메가니움 (Meganium) |
  | 아차모 (Torchic) | 영뿔 (Combusken) | 번치코 (Blaziken) |
  | 이브이 (Eevee) | 샤미드 (Vaporeon) | — |
  | 메타몽 (Ditto) | — | — |
  | 토게피 (Togepi) | — | — |
  | 뚜꾸리 (Tepig) | — | — |
  | 잠만보 (Snorlax) | — | — |
  | 팬텀 (Gengar) | — | — |

  이 매핑은 `AppDelegate.evolutionChains`(Swift)와 `scripts/build_sheet.py`의 `_EVOLUTIONS`가 서로 일치해야 합니다. 진화형 스프라이트도 기본 펫과 똑같은 파이프라인으로 생성되며, 앱 번들 리소스(`Resources/pets/<slug>/`)로만 들어가고 Orca 임포트용 `.codex-pet` 번들은 만들지 않습니다(사용자가 직접 고르는 펫이 아니라서).

## 폴더 구조

```
totodile.codex-pet/     리아코(Totodile) Orca 임포트용 번들 (Settings → Experimental → Pet → Import)
  pet.json                 매니페스트: 9행 스프라이트 레이아웃, 프레임별 타이밍
  spritesheet.png            2400x1800, 최대 12열 x 9행, 프레임 200x200
                               (행마다 프레임 수가 다릅니다 — 남는 칸은 투명)
                               파이리만 3840x3200 / 프레임 320x320 — 아래 참고

ditto.codex-pet/         메타몽(Ditto) Orca 임포트용 번들 — 위와 동일한 구조
charmander.codex-pet/    파이리(Charmander) Orca 임포트용 번들 — 위와 동일한 구조
squirtle.codex-pet/      꼬부기(Squirtle) Orca 임포트용 번들 — 위와 동일한 구조
geodude.codex-pet/       꼬마돌(Geodude) Orca 임포트용 번들 — 위와 동일한 구조
eevee.codex-pet/         이브이(Eevee) Orca 임포트용 번들 — 위와 동일한 구조
chikorita.codex-pet/     치코리타(Chikorita) Orca 임포트용 번들 — 위와 동일한 구조
torchic.codex-pet/       아차모(Torchic) Orca 임포트용 번들 — 위와 동일한 구조
togepi.codex-pet/        토게피(Togepi) Orca 임포트용 번들 — 위와 동일한 구조
tepig.codex-pet/         뚜꾸리(Tepig) Orca 임포트용 번들 — 위와 동일한 구조
snorlax.codex-pet/       잠만보(Snorlax) Orca 임포트용 번들 — 위와 동일한 구조
gengar.codex-pet/        팬텀(Gengar) Orca 임포트용 번들 — 위와 동일한 구조

scripts/build_sheet.py   재현 가능한 생성 스크립트 — `PETS` 리스트에 등록된 각 포켓몬마다
                          PokeAPI의 5세대 배틀 스프라이트를 받아서 `<slug>.codex-pet/`과
                          ConnorPet 앱의 번들 리소스를 함께 재생성합니다 (`python3 scripts/build_sheet.py`)

scripts/make_app.sh        release 빌드를 독립 실행형 ConnorPet.app으로 감싸서 ~/Applications에
                             설치합니다 (터미널과 무관하게 상주, 아래 "실행 방법" 참고)

scripts/simulate_agent.py  실제 에이전트 없이 테스트하기 위한 도구. last-status.json에
                             가짜 패널 상태를 주입/삭제합니다 (아래 "테스트하기" 참고, Orca 소스 전용)

scripts/install_claude_hooks.py  위 훅 설정을 ~/.claude/settings.json에 자동으로 병합/제거하는
                                   설치 스크립트 (`--uninstall`로 원상복구). 기존 훅은 건드리지
                                   않고, 재실행해도 중복 추가되지 않음

scripts/pet_hook_status.py  Claude Code 훅 핸들러 (선택 설치, 위 스크립트가 참조). ~/.claude/
                                 settings.json에 등록해두면 Stop/SessionEnd 훅이 발생할 때 이
                                 스크립트가 실행되어 ~/.claude/pet-status.json을 갱신합니다 (위
                                 "Claude Code 훅으로 헤롱헤롱/실패까지 보기" 참고)

preview/index.html        브라우저 전용 미리보기: 실제 spritesheet.png + pet.json을 그대로
                            불러와서 Orca의 실제 CSS 스텝핑 알고리즘(buildSpriteAnimationCss)으로
                            재생. 여러 프로젝트/에이전트를 흉내내는 컨트롤 패널 포함. Orca 설치 불필요.

ConnorPet/                 진짜 결과물: 독립 실행형 macOS 앱
  Package.swift              (Swift Package, `swift run`만 있으면 됨 — Xcode 불필요)
  Sources/ConnorPet/
    OrcaStatusWatcher.swift    last-status.json 폴링(1s) + 전체 상태 집계 (Orca 소스)
    ClaudeCodeStatusWatcher.swift  ~/.claude/sessions/*.json(권위 소스: 달리기/얼음/잠듦) +
                                    (있다면) 훅이 쓴 pet-status.json(오버레이: 헤롱헤롱/실패)을
                                    250ms마다 폴링해 병합 (Claude Code 소스, 기본값)
    PetAnimationState.swift    포팅한 우선순위 로직 + 드래그 방향 판정 + AgentStatusWatching 프로토콜
                                (acknowledgeDone()으로 헤롱헤롱 호버-해제 처리) + 토큰/진화용 필드
    UpdaterManager.swift        Sparkle 자동 업데이트 래퍼 (실행 시 UI 없이 조용히 확인 →
                                 메뉴로만 알림 → 클릭 시 정식 설치. EdDSA 검증이라 미서명 배포도 OK)
    TokenUsage.swift             트랜스크립트 JSONL에서 실제 토큰 사용량을 mtime 캐시로 합산
                                  (TranscriptTokenReader) + 토큰→경험치%/진화단계 매핑(XPModel)
    SpriteSheet.swift           spritesheet.png를 애니메이션별 프레임 배열로 자름
    PetView.swift                프레임 렌더링, 호버/드래그/클릭/우클릭 모션 메뉴(맨 아래 "설정…"), 펫 아래 경험치 바 그리기
    PetWindow.swift               테두리 없는 투명, 항상 위에 뜨는 NSWindow
    SettingsWindow.swift          우클릭 "설정…"으로 여는 무채색 그룹 카드 설정 창 — 메뉴바 기능을 한 곳에 모음(SettingsActionsDelegate)
    BattleService.swift            같은 wifi 발견(Bonjour, NWListener/NWBrowser) + 대전 신청/수락 핸드셰이크
    BattleSimulation.swift         seed 하나로 양쪽이 똑같이 계산하는 결정론적 대전 시뮬레이션(명중/회피 포함)
    BattleWindow.swift             작은 LCD형 대전 화면 (펫 하나씩, 발사체 화면 밖→화면 전환, 불꽃 CAEmitterLayer + 회피 + HP + WIN/LOSE)
    BattleChallengeDialog.swift    대전 신청 수락/거절 모달 (NSAlert 대신 커스텀 — 폴더 아이콘 자리에 "BATTLE" 배너 + 초록 수락 버튼). "Challenge" 말풍선을 눌러야 뜬다
    ChallengeBubbleWindow.swift    신청받은 쪽에 먼저 뜨는 펫 오른쪽 위 작은 흰색 "Challenge" 말풍선(10초, 클릭 시 모달로)
    ChallengeCountdownWindow.swift 신청한 쪽이 보는 20초 카운트다운 막대(응답 없으면 "응답하지 않음")
    BattleSelfTest.swift           CONNORPET_SELFTEST=battle 로 도는 헤드리스 핸드셰이크 검증
    SessionBrief.swift             ~/.claude/projects 트랜스크립트에서 최근 세션 진행상황 추출
    BriefingSummarizer.swift        claude CLI 로 진행상황을 요약 (캐시 + 백그라운드 갱신)
    SpeechBubbleWindow.swift        말풍선 패널 (펫 위에 뜨고, 화면 밖으로 안 나가게 보정)
    FlameWindow.swift               속성기 이펙트 전용 투명 창 (클릭 통과)
    AppDelegate.swift              전체 연결 + 메뉴바 포켓몬/소스 선택·경험치 바 토글·대전·Quit 메뉴 + 진화 스프라이트 교체
    Resources/effects/              속성기·Zzz 이펙트 스프라이트 (fire_jet, water_jet, zzz)
    Resources/pets/<slug>/          펫별 spritesheet.png + pet.json 번들 사본. 기본 12종(totodile, ditto,
                                     charmander, squirtle, geodude, eevee, chikorita, torchic, togepi, tepig, snorlax, gengar)
                                     + 진화형 13종 (croconaw, feraligatr, charmeleon, charizard, wartortle,
                                     blastoise, graveler, golem, bayleef, meganium, combusken, blaziken, vaporeon)
```

## 실행 방법

### 앱으로 설치해서 상주시키기 (권장)

```sh
./scripts/make_app.sh                  # ~/Applications/ConnorPet.app 생성 (기본값)
open -a ~/Applications/ConnorPet.app   # 실행
```

`scripts/make_app.sh`는 release 빌드를 `.app` 번들로 감싸서 설치합니다. 이렇게 띄우면 **실행한 터미널을 닫아도 펫이 계속 떠 있습니다** (아래 `swift run`은 셸의 자식 프로세스로 실행되기 때문에 터미널을 닫으면 같이 죽습니다). Dock/앱 스위처에는 뜨지 않고 메뉴바에만 남으며(`LSUIElement`), 다음부터는 Spotlight에서 `ConnorPet`으로 바로 실행할 수 있습니다. 종료는 메뉴바 → Quit. 설치 위치를 바꾸고 싶으면 인자로 넘기면 됩니다 (`./scripts/make_app.sh /Applications`).

코드를 고친 뒤에는 스크립트를 다시 실행하면 됩니다 — 떠 있는 인스턴스를 알아서 종료하고 번들을 교체합니다.

> **알아둘 점**: `swift run`은 번들 id가 없고 `.app`은 `io.github.pet-egg.connorpet`을 쓰기 때문에 UserDefaults 도메인이 다릅니다. `.app`으로 처음 실행하면 펫 종류·상태 소스·진화 설정·창 위치가 기본값에서 한 번 다시 시작합니다(이후로는 그대로 유지됩니다).

### 개발 중 실행

```sh
cd ConnorPet
swift run
```

**처음 설치해 최초 1회 실행하면**(재실행은 아님) 2단계 마법사가 뜹니다 — **①펫 고르기**(썸네일
이미지로 12종을 보여줌) → **②사용하는 앱 고르기**(상태 소스: **Claude Desktop / Claude Code / Orca**,
각 항목 왼쪽에 앱 아이콘 표시). 고른 값은 바로 저장되고 이후 실행 때 복원됩니다(둘 다 나중에 메뉴/설정에서 바꿀 수 있음).

> 아이콘 출처: Claude Desktop = Claude 선버스트([Simple Icons](https://simpleicons.org), CC0),
> Claude Code = "Clawd" 픽셀 재현(공식 색 `#da7756`), Orca = 범고래([Twemoji](https://github.com/twitter/twemoji), CC-BY 4.0).

메뉴바에 작은 포켓볼 아이콘이 생깁니다. 클릭하면 위쪽엔 상태 소스로 **Claude Desktop**(기본값)/**Claude Code**/**Orca** 중 하나를 고를 수 있고(체크 표시가 현재 선택), 그 아래 **"경험치 바 항상 표시"** 토글(기본 켜짐, 끄면 호버 시에만 표시), **"진화 사용"** 토글(기본 꺼짐, 켜면 누적 토큰에 따라 진화), 그 아래 **대전**으로 같은 Wi-Fi의 상대에게 대전을 신청하고(위 "같은 wifi에서 대전하기" 참고), 맨 아래 Quit으로 종료합니다. (펫 종류 전환은 펫 우클릭 › "설정…" 또는 메뉴의 "설정…"에서 합니다.) 모든 선택이 다음 실행 때도 그대로 복원됩니다. 펫 자체는 화면 우측 하단 근처에 떠서 다른 창들 위에, 모든 Space에서 보이고, 그 아래에 토큰 사용량 경험치 바가 붙습니다. 선택한 소스가 안 깔려있거나 활동 중인 세션/패널이 없으면 그냥 idle 상태로 가만히 있습니다.

크기는 Orca 자체 기본값(`PET_SIZE_DEFAULT=180`)보다 작게, `90pt`로 맞춰뒀습니다 (`AppDelegate.swift`의 `petSize`). 더 키우거나 줄이고 싶으면 이 값만 바꾸면 됩니다.

## dmg로 빌드해서 배포하기 (GitHub Actions)

`swift run`으로 직접 띄우는 대신 더블클릭으로 설치되는 `.dmg`가 필요하면 `build-pet-dmg.yml` 워크플로우를 씁니다. **`cd ConnorPet && swift run`과 똑같이 12종 펫이 모두 든 단일 앱**(메뉴바에서 전환)을 빌드하며, 산출물 이름은 전부 `pet`으로 고정됩니다:

1. GitHub 저장소의 **Actions** 탭 → **Build Pet DMG** 워크플로우 선택
2. **Run workflow** 클릭 → 실행 (고를 옵션 없음 — 항상 전체 펫 빌드)
3. macOS 러너가 `swift build -c release`로 기본 빌드(전체 펫)를 만들고, `pet.app`(실행 파일명도 `pet`)으로 번들링해서 `pet.dmg`를 만듭니다. 진화형 스프라이트도 리소스 번들(`Resources/pets`) 전체가 함께 들어가 정상 동작하고, 앱 아이콘은 `assets/app-icon.png` 하나로 고정입니다.
4. 실행이 끝나면 **Artifacts**에서 `pet-dmg`(그리고 서명 시크릿이 있으면 `pet-appcast`)를 다운로드

코드서명/공증(notarization)은 하지 않고 ad-hoc 서명만 합니다(`codesign --sign -`). 서명 없이 그대로 두면 손으로 조립한 `.app` 번들이 quarantine 플래그와 맞물려 macOS가 "손상되었기 때문에 열 수 없음"이라며 실행을 거부하는 문제가 있어서, 최소한의 ad-hoc 서명으로 이를 막았습니다.

**다운로드 후 반드시 quarantine을 직접 벗겨줘야 열립니다.** Apple Developer ID 서명이 아니라서 "확인되지 않은 개발자" 경고 정도로 끝나지 않고, 다운로드한 파일(quarantine 플래그가 붙음)을 그대로 더블클릭하면 macOS(특히 Apple Silicon)의 `amfid`가 "adhoc signed or signed by an unknown certificate chain"이라며 실행 자체를 막고 **아무 대화상자도 띄우지 않은 채 앱을 곧장 휴지통으로 옮겨버립니다** — 우클릭 → 열기로도 우회되지 않습니다(실제로 재현해서 확인한 동작입니다).

맨 위 **"설치"** 의 원라이너(`install.sh`)/Homebrew Cask 가 바로 이 과정을 대신 해주므로 보통은 그걸 쓰면 됩니다. 손으로 하려면 아래처럼 터미널에서 quarantine을 지운 뒤 열어야 합니다:

```sh
# dmg를 마운트해서 pet.app을 Applications(또는 원하는 위치)로 옮긴 다음:
xattr -d com.apple.quarantine /Applications/pet.app
open /Applications/pet.app
```

크기는 Orca 자체 기본값(`PET_SIZE_DEFAULT=180`)보다 작게, `90pt`로 맞춰뒀습니다 (`AppDelegate.swift`의 `petSize`). 더 키우거나 줄이고 싶으면 이 값만 바꾸면 됩니다.

## 자동 업데이트 (Sparkle)

서명·공증 안 한 배포본이라도 **[Sparkle](https://sparkle-project.org/)** 로 인앱 업데이트를 합니다. Sparkle 은 Apple Developer ID 대신 **자체 EdDSA 서명**으로 업데이트 파일을 검증하므로 ad-hoc 서명/공증 없이도 동작하고, 설치할 업데이트에서 quarantine 플래그를 벗겨 주기 때문에 **업데이트할 때는 Gatekeeper 첫 실행 관문을 다시 거치지 않습니다** (최초 설치 1회만 통과하면 됨).

동작(팝업/토스트 없음, 메뉴로만 알림):

- **켤 때** — 조용히(`checkForUpdateInformation()`, UI 없음) appcast 를 확인합니다. 피드가 아직 없거나 네트워크 오류면 아무 것도 안 뜨고 그냥 넘어갑니다.
- **메뉴바** — 맨 아래에 항상 현재 버전(`ConnorPet vX.Y (build)`)을 보여 주고, 새 버전이 있으면 `⬆︎ 업데이트 설치 (vX.Y)` 로 바뀝니다. 없으면 `업데이트 확인…`.
- **눌렀을 때** — 그때부터 Sparkle 정식 UI(다운로드 → 검증 → 교체 → 재실행)가 뜹니다.

자동 확인·자동 다운로드는 코드에서 모두 꺼 둡니다(`UpdaterManager.swift`). 버전은 **git 태그가 단일 소스**입니다 — `CFBundleShortVersionString`=최신 태그(`vX.Y.Z`), `CFBundleVersion`=커밋 수(단조 증가라 Sparkle 비교에 안전). `make_app.sh`/CI 가 빌드 시 `git describe` 로 읽어 Info.plist 에 박습니다. 새 버전을 내려면 `git tag vX.Y.Z` 를 달면 됩니다.

### 배포 담당자용 설정 (업데이트를 실제로 켜려면)

앱에는 이미 검증용 **공개키**(`SUPublicEDKey`)와 피드 주소(`SUFeedURL` = `https://pet-egg.github.io/pet/appcast.xml`)가 박혀 있습니다. **한 번만** 아래 두 가지를 준비하면, 그 뒤로는 **`git tag` 푸시 하나로 빌드·릴리스·Pages 배포가 전부 자동**입니다.

**최초 1회 준비**

1. **개인키를 Secret 에 등록** — 공개키와 짝이 되는 개인키는 최초 `generate_keys` 실행 때 만든 사람의 **로그인 키체인**에 있습니다. export 해서(`generate_keys -x private.key`) 저장소 Secret **`SPARKLE_EDDSA_PRIVATE_KEY`** 에 넣습니다. (키를 새로 만들려면 `generate_keys` 로 만들고, 출력된 새 `SUPublicEDKey` 를 `scripts/make_app.sh` 와 `build-pet-dmg.yml` 의 값으로 교체.)
2. **Pages 소스를 "GitHub Actions" 로** — 저장소 **Settings › Pages › Build and deployment › Source** 를 **GitHub Actions** 로 설정합니다. (워크플로의 `publish-appcast` 잡이 `appcast.xml` 을 여기로 배포합니다.)

**릴리스 발행 (버전 낼 때마다)**

```sh
git tag v1.0.0
git push origin v1.0.0
```

태그(`v*`)를 푸시하면 `Build Pet DMG` 워크플로가 자동으로:
- `pet.dmg` + 서명된 `appcast.xml` 빌드 (`git describe` 로 버전 주입)
- **릴리스 생성 + `pet.dmg` 업로드** → 다운로드 URL `https://github.com/pet-egg/pet/releases/latest/download/pet.dmg` (appcast 의 enclosure 와 일치)
- 서명된 **`appcast.xml` 을 Pages 로 배포**

→ 기존 사용자 앱이 다음 실행 때 새 버전을 감지합니다. (배포는 `v*` 태그 푸시로만 트리거됩니다 — 수동 `workflow_dispatch` 트리거는 제거됐습니다.)

> 릴리스에는 서명 키가 필수입니다 — Secret 이 없으면 `appcast.xml` 이 생성되지 않아 `publish-appcast` 잡이 실패합니다(빌드/릴리스 자체는 되지만 자동 업데이트 피드는 안 올라감).

### Homebrew Cask 자동 갱신 (`bump-cask` 잡)

`brew install --cask pet-egg/pet/pet` 은 별도 탭 저장소 **[`pet-egg/homebrew-pet`](https://github.com/pet-egg/homebrew-pet)** 의 `Casks/pet.rb` 를 씁니다. 릴리스 워크플로의 `bump-cask` 잡이 새 태그마다 이 파일의 `version`/`sha256` 을 자동으로 갱신하므로, 태그만 밀면 curl 스크립트와 Homebrew 가 함께 최신이 됩니다.

이 잡은 **다른 저장소(탭)에 push** 해야 해서 기본 `github.token` 으론 안 되고, 탭에 write 권한이 있는 PAT 를 저장소 Secret **`HOMEBREW_TAP_TOKEN`** 에 넣어 두면 동작합니다(**최초 1회만**). Secret 이 없으면 잡이 조용히 건너뛰므로(릴리스는 정상), Homebrew 배포를 안 쓸 거면 설정하지 않아도 됩니다. 탭의 `url`/`zap` 등 나머지는 잡이 `sed` 로 두 줄만 바꾸고 그대로 두므로, 구조를 바꾸려면 탭 저장소의 `Casks/pet.rb` 를 직접 고치면 됩니다.

## 클릭하면 브리핑

펫을 좌클릭하면 최근에 쓴 세션들을 최근 이용 순으로, 세션당 100자·합계 500자 이내로
말풍선에 띄웁니다. 각 줄은 `· [프로젝트] 그 세션을 시작할 때 요청한 내용` 형태입니다.

### 속성기 = "여기까지 정리" 체크포인트

파이리는 **불뿜기**, 꼬부기는 **물뿜기**를 씁니다. 속성기는 그 포켓몬의 타입에 묶이므로
전 펫 공통일 수 없어서, `build_sheet.py` 의 `SKILLS` 에 등록된 펫만 해당 행을 갖습니다.
한 펫에 하나뿐이라 단축키는 `a` 를 공유합니다 — 매니페스트에 그 행이 없는 펫에서는
메뉴 항목이 비활성으로 보입니다.

이펙트가 나오는 입 위치는 **스프라이트 크기에 대한 비율**로 둡니다. 프레임 절대좌표나
스프라이트 로컬 픽셀로 두면 확대 배율을 바꿀 때 같이 움직이지 않습니다 — 실제로
파이리를 4배에서 8배로 키웠을 때 불길이 입이 아니라 이마에서 나오고 있었습니다.

우클릭 메뉴에서 고르거나, 메뉴가 열린 상태에서 `a` 를 누르면 한 번 씁니다.

**불길은 스프라이트시트에 없습니다.** 별도 창(`FlameWindow.swift`)에 그립니다.

스프라이트 행은 프레임 한 칸보다 넓어질 수 없습니다. 불길을 시트 안에 그리려면
프레임을 키워야 하는데, 그러면 **모든 행의 모든 프레임**이 같이 커집니다 — 화면상
675pt 짜리 불길은 프레임 1600px, 시트 19200x16000, 창 720pt 로 계산됐습니다.
별도 창에서는 이미지 하나를 그릴 때 늘리기만 하면 되므로 크기가 공짜이고, 그 창을
`ignoresMouseEvents = true` 로 두면 넓어진 영역이 클릭을 가로채지도 않습니다.

시트에는 펫의 반동 동작만 들어갑니다. 앱이 불길을 어디에 붙일지 알 수 있도록,
`build_sheet.py` 가 프레임마다 입 좌표와 불길 크기를 매니페스트의 `fireBreath.
mouthByFrame` 으로 함께 내보냅니다. 입 위치는 프레임 절대좌표가 아니라 **스프라이트
기준 오프셋**(`MOUTH_IN_SPRITE`)에서 계산하므로, 프레임 크기를 바꿔도 따라갑니다.
`paste_centered` 가 스프라이트를 프레임 안으로 클램프하면 오프셋이 잘리는데,
`applied_offset` 으로 잘린 뒤의 값을 써야 불길이 입에서 떨어지지 않습니다.

불길 길이는 `FlameWindow.lengthMultiplier(forStage:)` 로 조절합니다 (창 너비 × 배수).
**진화 단계마다 배수가 다릅니다** — 기본형 2.0, 1단계 2.7, 2단계 3.75.

창 너비가 이미 단계에 따라 커지므로 배수를 고정해도 길이는 따라 커지지만, 그러면
펫 대비 비율이 단계와 무관하게 일정해서 기본형에서도 자기 키의 5배가 넘는 불길이
나갔습니다(기본형 꼬부기 5.8배). 어린 개체는 덜 뿜는 편이 자연스럽습니다.

| | 기본형 | 1단계 | 2단계 |
|---|---|---|---|
| 불길 길이 | 180pt | 437pt | 675pt |
| 펫 대비 (파이리 계열) | 2.4배 | 3.5배 | 4.2배 |

### 경험치는 펫마다 따로 쌓입니다

경험치는 **그 펫이 화면에 있는 동안 발생한 토큰**만 받습니다. 파이리를 띄워 두고 일한
분량은 파이리에게만 들어가고, 꼬부기로 바꾸면 꼬부기가 자기 몫을 새로 쌓기 시작합니다.
진화도 각자의 경험치로 따로 진행되므로, 파이리가 리자몽이 돼 있어도 꼬부기는 기본형일
수 있습니다.

구현 메모: 토큰 합계(`total(for:)`)는 지금 살아 있는 세션들의 합이라 세션이 끝나면
줄어듭니다. 누구에게 얼마를 줄지 세려면 감소하지 않는 값이 필요해서, 트랜스크립트
파일별 증가분만 더하는 `accrued(for:)` 를 씁니다. 처음 보는 트랜스크립트는 현재 값으로
등록만 하고 증가분에 넣지 않습니다 — 안 그러면 앱을 켜거나 펫을 바꾼 직후에 이미
진행 중이던 세션의 과거 사용량이 통째로 그 펫에게 쏟아집니다.

누적값은 `UserDefaults` 의 `petTokens` 에 10초마다, 그리고 펫을 바꿀 때와 종료할 때
저장합니다.

### 진화하면 덩치가 커진다

기본형은 다른 펫과 같은 크기이고, 진화할 때마다 단계적으로 커집니다.

| | 기본형 | 1단계 | 2단계 |
|---|---|---|---|
| 파이리 계열 | 76pt | 리자드 126pt | 리자몽 160pt |
| 꼬부기 계열 | 58pt | 어니부기 103pt | 거북왕 148pt |

화면에 찍히는 높이는 프레임과 무관하게 "준비된 스프라이트 높이 × 0.45" 입니다.
정수 배율만 쓰므로 단계마다 고를 수 있는 값이 정해져 있는데, 2단계를 키우는 대신
1단계를 줄여 격차를 고르게 했습니다 — 화면을 너무 많이 차지하면 곤란하기 때문입니다.

프레임 크기로 조절합니다 (`FRAME_BY_PET`). 창 크기가 프레임에 비례하므로
(`AppDelegate.windowSize(for:)`), 프레임이 넓은 펫은 창도 커지고 그 안에서 캐릭터가
차지하는 비율은 유지됩니다. 창만 키우지 않는 이유는 도트 때문입니다 — 200px 소스를
레티나에서 늘려 그리면 픽셀 격자가 뭉개지므로, 스프라이트를 정수배로 더 키우고
프레임을 같이 넓혀 화면에 그릴 때의 축소 비율을 맞춥니다.

진화형은 원본 도트가 더 크기 때문에 같은 화면 크기를 내려면 프레임이 더 넓어야
합니다 (기본형 200 / 진화형 480).

### 기본 범위 (체크포인트가 없을 때)

범위는 2단입니다.

1. **최근 3시간** 안에 쓴 세션 — "지금 하던 일"은 이 안에 있습니다. 상한은 5개인데,
   글자 예산이 어차피 다섯 줄에서 끊기기 때문입니다.
2. 3시간 안에 **하나도 없을 때만** 48시간까지 넓혀 3개. 이 경우 "최근 3시간은 조용했어"
   라고 먼저 말합니다 — 안 그러면 이틀 전 작업을 지금 하던 일로 읽게 됩니다.

**어느 방을 고를지**와 **그 방에서 무엇을 재료로 삼을지**는 별개입니다. 고른 방마다
요약 재료는 그 방에서 **최근 24시간 동안 오간 대화**입니다(사용자 발화와 응답을 모두
넣고, 최대 16마디). 예전에는 세션의 첫 메시지와 마지막 요청 몇 개만 넣었는데, 세션이
며칠 이어지면 첫 메시지는 한참 전 목표고 마지막 몇 개만으로는 그사이 무엇이 끝났는지가
빠졌습니다. 창 안 대화를 통째로 주면 요약기가 직접 판단합니다.

시각이 없는 레코드는 버립니다 — 창 안인지 밖인지 알 수 없는 것을 넣으면 "24시간 이내"
라는 약속이 깨집니다. 체크포인트(불뿜기)를 찍어 둔 상태에서는 대화 재료도 그 시점
뒤로 자릅니다. 안 그러면 "여기까지 정리한 뒤로" 라고 해 놓고 그 전 이야기를 합니다.

출처는 Claude Code 자신의 트랜스크립트 디렉터리입니다.

```
~/.claude/projects/<슬러그화된-cwd>/<sessionId>.jsonl
```

**`claude` CLI 와 Claude Code 데스크톱 앱이 모두 여기에 기록**하고, 레코드마다 `entrypoint`
필드(`cli` / `claude-desktop`)로 구분되기 때문에 리더 하나로 양쪽을 다 커버합니다. 둘 중
아무것도 실행 중이 아니어도 읽힙니다.

### 무엇을 말하는가 — `claude` 요약

각 줄은 그 세션이 **어디까지 진행됐는지**를 `claude` CLI 가 한 줄로 적은 것입니다.
무슨 주제인지가 아니라 무엇까지 끝났고 지금 무엇이 걸려 있는지를 씁니다 — 이어서
하려면 어디를 봐야 하는지가 필요하지, "펫 앱 기획 중" 같은 주제 설명은 도움이 되지
않기 때문입니다. 판단 재료는 그 세션의 **마지막 요청 4개와 마지막 응답**입니다.
응답이 있어야 무엇이 됐는지를 알 수 있습니다.

세션 사이는 빈 줄로 띄웁니다. 말풍선 안에서 줄바꿈이 일어나면 어디서 한 세션이
끝나는지 구분이 안 됩니다. 말풍선은 30초 동안 떠 있습니다(`PetView.briefingDuration`)
— 여러 세션을 훑어 읽을 시간이 필요합니다.

요약은 **캐시해 두고 씁니다.** `claude -p` 왕복이 실측 10초라 클릭을 붙잡아 둘 수
없습니다. 클릭은 항상 디스크에 있는 걸 즉시 보여 주고, 갱신은 백그라운드로 돌아
다음 클릭에 반영됩니다. 캐시가 아직 없으면 원문 발췌로 대신합니다. 앱이 뜰 때 한 번
미리 돌려 두므로 첫 클릭도 대개 요약본입니다.

캐시는 **세션 id 묶음**으로 식별하고 10분이 지나면 새로 만듭니다. 처음에는 파일
수정 시각도 식별자에 넣었는데, 살아 있는 세션은 몇 초마다 트랜스크립트가 갱신돼서
캐시가 한 번도 맞지 않았습니다.

요약을 돌리는 `claude` 호출도 그 자체로 Claude Code 세션이라 트랜스크립트를 남깁니다.
그대로 두면 다음 브리핑에 "펫이 자기 요약을 요약한 내용"이 섞이므로, 전용 작업
디렉터리(`~/Library/Application Support/ConnorPet/agent`)에서 돌리고 리더가 그 폴더를
건너뜁니다. `claude` 가 없거나 실패하면 원문 발췌로 조용히 되돌아갑니다.

트랜스크립트는 큽니다(실측 31MB 세션 존재). 클릭에 즉시 반응해야 하므로 파일을 통째로
읽지 않고 **앞부분 128KB(세션의 목표)와 뒷부분 192KB(최근 요청)만** 읽습니다 — 필요한 건 그 세션을 무엇 때문에 시작했는지이고,
확인해 본 모든 최근 트랜스크립트에서 첫 사용자 메시지가 앞 8KB 안에 있었습니다.
슬래시 커맨드 껍데기·스킬 본문·주입된 리마인더처럼 사람이 쓴 요청이 아닌 레코드와,
12자 미만의 한 마디짜리 세션은 걸러냅니다 (`SessionBrief.swift`).

## 테스트하기 (실제 에이전트 없이)

`scripts/simulate_agent.py`는 **Orca 소스**용입니다 (메뉴에서 소스를 Orca로 바꾼 뒤 사용):

```sh
python3 scripts/simulate_agent.py set web-app working
python3 scripts/simulate_agent.py set api-server blocked   # 펫이 즉시 "waiting"으로
python3 scripts/simulate_agent.py clear api-server         # "running"으로 복귀
python3 scripts/simulate_agent.py clear-all                # "idle"로 복귀
```

`connor-pet-test:` 접두어가 붙은 키로만 기록해서, 실제 Orca 패널(UUID 형태)과 절대 충돌하지 않습니다. `clear-all`도 이 접두어가 붙은 항목만 지웁니다.

**Claude Code 소스**는 시뮬레이터가 없습니다 — 다른 터미널에서 `claude`를 실행해서 실제 세션을 하나 띄우고 프롬프트를 보내보면(`~/.claude/sessions/<pid>.json`의 `status`가 `busy`→달리기, 권한 승인창이 뜨면 `waiting`→얼음으로 바뀌는 동안) 펫이 바로 반응하는 걸 볼 수 있습니다. 위 훅까지 설정했다면 stdin으로 가짜 페이로드를 직접 넣어서 헤롱헤롱/실패도 트리거해볼 수 있습니다(단, 세션 파일이 그 세션을 `idle`로 두고 있어야 오버레이가 보입니다):

```sh
echo '{"session_id":"<아무-id>","cwd":"/tmp"}' | python3 scripts/pet_hook_status.py done   # "review"(헤롱헤롱)로
rm ~/.claude/pet-status.json                                                                # 원상복구
```

**한 가지 알아둘 점**: Orca가 실제로 돌고 있고 실제 에이전트 활동이 생기면, Orca 자신이 다음 상태를 저장할 때 파일 전체를 자기 메모리 상태로 덮어써서 주입해둔 테스트 항목이 사라질 수 있습니다(실제로 테스트하다가 이렇게 됐습니다). 그럴 땐 그냥 `set` 명령을 다시 실행하면 됩니다 — 실제 데이터를 건드리는 게 아니라서 안전합니다.

동작 확인 로그를 보고 싶으면:
```sh
CONNORPET_DEBUG=1 swift run
```
어떤 패널이 어떤 규칙으로 최종 애니메이션을 결정했는지 stderr에 한 줄씩 찍힙니다.

## Orca 안에서 직접 쓰고 싶다면

Orca 자체 펫으로 쓰고 싶으면(Settings → Experimental → Pet → Import), 원하는 펫의 `<slug>.codex-pet/` 폴더(`totodile`/`ditto`/`charmander`/`squirtle`/`geodude`/`eevee`/`chikorita`/`torchic`/`togepi`/`tepig`/`togepi`)를 그대로 임포터에 지정하면 됩니다.

## 스프라이트 시트 다시 만들기

```sh
pip install pillow
python3 scripts/build_sheet.py
```

### 프레임 수와 확대 배율

원본 gen5 배틀 스프라이트는 **55프레임짜리 애니메이션 GIF** 입니다. 예전에는 행마다 4장만
뽑아 써서 재생이 슬라이드쇼처럼 끊겼고, 지금은 행마다 8~12장을 뽑습니다(`FRAME_SPEC`).

같이 고친 것 세 가지입니다.

- **프레임별 `autocrop` 제거** — 프레임마다 따로 잘라 중앙에 놓으면 원본 GIF 안에 들어 있던
  호흡·바운스가 전부 지워집니다. 전 프레임 **공통 bbox** 로 잘라야 프레임 간 상대 움직임이
  남습니다. 이어져 보이는 실제 이유가 이것입니다.
- **정수배 확대** — 41x42 도트를 3.571배로 NEAREST 확대하면 한 도트가 3px 이 되기도 4px 이
  되기도 해서 픽셀 격자가 무너집니다. 반올림한 정수 배율만 씁니다(내림으로 하면 꼬마돌이
  2.79배 → 2배로 28% 작아집니다).
- **오프셋 클램프** — `paste_centered` 가 dx/dy 를 프레임 안으로 잘라 냅니다. 예전에는
  점프 최고점에서 머리 위가 실제로 프레임 밖으로 나가 잘리고 있었습니다.

재생 속도는 원본의 자연 속도(55프레임 x 100ms = 5.5초 루프)를 기준으로 잡습니다.
`FRAME_SPEC` 의 주석에 모션마다 자연 속도의 몇 배인지 적어 두었습니다.

이펙트 스프라이트(`scripts/effects/`)는 예외적으로 저장소에 커밋합니다. PokeAPI 에서
받을 수 있는 게 아니고 생성형 이미지라 스크립트를 다시 돌려도 똑같이 나오지 않기
때문입니다. 파일이 없으면 그 연출만 건너뛰고 빌드는 통과합니다.

`scripts/build_sheet.py`의 `PETS` 리스트에 등록된 각 포켓몬(현재 리아코 #158, 메타몽 #132, 파이리 #4, 꼬부기 #7, 꼬마돌 #74, 이브이 #133, 치코리타 #152, 아차모 #255)마다 PokeAPI에서 5세대 애니메이션 배틀 스프라이트를 다시 받아서 `<slug>.codex-pet/{spritesheet.png,pet.json}`과 `ConnorPet/Sources/ConnorPet/Resources/pets/<slug>/`의 앱 번들 사본을 동시에 처음부터 재생성합니다 — 완전히 재현 가능하고, 바이너리 원본 에셋은 저장소에 커밋하지 않습니다. 새 포켓몬을 펫 선택 메뉴에 추가하려면 `PETS`에 항목을 하나 더 넣고 스크립트를 다시 돌린 뒤, `AppDelegate.swift`의 `availablePetSlugs`에 슬러그를 추가하면 됩니다.

`scripts/build_sheet.py`의 `PETS` 리스트에 등록된 각 기본 포켓몬(현재 리아코 #158, 메타몽 #132, 파이리 #4, 꼬부기 #7, 꼬마돌 #74, 이브이 #133, 치코리타 #152, 아차모 #255, 토게피 #175, 뚜꾸리 #498, 잠만보 #143, 팬텀 #94)과 `_EVOLUTIONS`의 진화형(크로콘 #159, 장크로다일 #160, 리자드 #5, 리자몽 #6, 어니부기 #8, 거북왕 #9, 데구리 #75, 딱구리 #76, 베이리프 #153, 메가니움 #154, 영뿔 #256, 번치코 #257, 샤미드 #134)마다 PokeAPI에서 5세대 애니메이션 배틀 스프라이트를 다시 받아서 `ConnorPet/Sources/ConnorPet/Resources/pets/<slug>/`의 앱 번들 사본을(기본 펫은 추가로 `<slug>.codex-pet/`까지) 처음부터 재생성합니다 — 완전히 재현 가능하고, 바이너리 원본 에셋은 캐시에 받아둘 뿐 저장소에 원본을 커밋하지 않습니다. 새 포켓몬을 펫 선택 메뉴에 추가하려면 `PETS`에 항목을 하나 더 넣고 스크립트를 다시 돌린 뒤, `AppDelegate.swift`의 `availablePetSlugs`에 슬러그를 추가하면 됩니다. 진화형을 바꾸려면 `_EVOLUTIONS`와 `AppDelegate.evolutionChains`를 함께 수정하세요.

## 앱 아이콘

dmg 로 빌드할 때 쓰는 앱 아이콘은 `assets/app-icon.png` 하나로 고정입니다
(1024x1024, macOS 스타일로 여백과 둥근 모서리를 미리 넣어 둔 이미지).

예전에는 선택한 펫의 스프라이트에서 고정 좌표로 잘라 썼는데, 프레임 크기가 펫마다
달라지면서(파이리 계열 진화형은 480) 그 좌표가 엉뚱한 칸을 집게 됐습니다. 아이콘을
바꾸려면 이 파일만 교체하면 됩니다.

## 대전 계산

한 대씩 주고받는 교대 공격입니다. 한 발마다 한 번의 난수 굴림으로 회피·반격·적중을
가릅니다 — 두 번 굴리면 같은 시드에서도 소비하는 난수 개수가 달라져 재현이 깨집니다.

| | |
|---|---|
| 시작 HP | 5 |
| 회피 | **10%** — 피해 0 |
| 반격 | **5%** — 피해 0 + **막아 낸 쪽이 다음 자기 차례에 두 발** |
| 적중 피해 | 기본 1~2 + 성장 보너스 |

성장 보너스는 `battlePower(tokens:stage:)` 가 내는 0...1 파워에 비례합니다.
파워 1.0(**2단계 진화 + 경험치 만렙**)이면 보너스가 4 라 적중 피해가 5~6 —
HP 5 인 상대를 **한 방에 눕힙니다**. 진화 단계는 곱연산으로 얹습니다(1단계 +15%,
2단계 +30%), 최대치가 정확히 1.0 이 되도록 나눠 정규화합니다.

**결과는 받는 쪽(accepter)이 계산해서 통째로 보냅니다.** 예전에는 시드만 주고받고
양쪽이 각자 계산했는데, 그 방식은 두 앱의 전투 규칙이 **완전히 같을 때만** 성립합니다.
한쪽만 업데이트해 회피율이 25%→10% 로 바뀌자 같은 시드에서 서로 다른 승자가 나왔고,
두 화면에 동시에 `WIN` 이 뜨거나 동시에 `LOSE` 가 떴습니다. 계산 주체를 한쪽으로 몰면
규칙이 앞으로 또 바뀌어도 이 문제가 재발하지 않습니다.

메시지에는 세대 번호(`battleProtocolVersion`)를 함께 실어, 결과를 보낼 줄 모르는
구버전과 만나면 대전을 시작하지 않고 **"버전이 달라요"** 로 알립니다 — 틀린 승패를
보여 주는 것보다 낫습니다. **양쪽 모두 이 버전 이상이어야 대전이 됩니다.**

| 상황 | 챌린저 승률 | 평균 라운드 |
|---|---|---|
| 둘 다 파워 0 | 49.9% | 6.5 |
| 중간 vs 0 | 90.3% | 4.1 |
| 최강 vs 0 | 98.4% | 1.9 |

## 실행 방식을 바꾸면 경험치가 사라지던 문제

`swift run` → 로컬 `.app` → 배포 dmg 로 갈아타면 경험치가 통째로 없어진 것처럼
보였습니다. 값은 사라지지 않았고, **다른 서랍에 들어가 있었습니다.**

경험치는 `UserDefaults` 에 있고, `UserDefaults` 가 어느 파일을 쓰는지는 **번들
식별자**가 정합니다. 파일 경로나 앱 이름이 아닙니다. 그래서 실행 방식이 바뀌면
저장소가 통째로 갈립니다. 실제로 세 갈래가 생겼습니다.

| 실행 방식 | 도메인 |
|---|---|
| `swift run` | `ConnorPet` (번들이 없어 프로세스 이름을 씁니다) |
| 예전 `make_app.sh` | `io.github.pet-egg.connorpet` |
| 배포 dmg | `io.github.pet-egg.pet` |

두 가지를 고쳤습니다.

- **식별자를 하나로 모았습니다.** `make_app.sh` 도 dmg 와 같은
  `io.github.pet-egg.pet` 을 씁니다. 두 파일이 어긋나면 같은 일이 또 납니다 —
  스크립트 주석에 그 이유를 박아 두었습니다.
- **한 번만 도는 이관을 넣었습니다**(`XPMigration`). 지금 도메인에 경험치가 **아예
  없을 때만**, 예전 도메인에서 펫마다 가장 많이 쌓인 값을 가져옵니다. 이미 쓰고 있던
  사람의 값은 절대 덮지 않습니다. 지급한 퀘스트 기록도 함께 합칩니다 — 안 그러면
  예전에 올린 PR·티켓이 다시 새것으로 잡혀 경험치가 두 번 들어갑니다.

### 설정 창에서 손으로 가져오기

자동 이관은 **지금 도메인이 비어 있을 때만** 돕니다. 이미 조금 쌓인 뒤에 알아차리면
그 조건에 걸리지 않으므로, 설정 창에 버튼을 두었습니다.

```
구 버전에서 경험치 가져오기                              [가져오기]
예전 기록 발견 — 펫 2종 · 65,244,929 늘어나요
```

행은 **예전 기록이 하나라도 있으면 늘 보입니다.** 세 상태로 갈립니다(`XPMigration.status`).

| 상태 | 보이는 모습 |
|---|---|
| 예전 기록 없음 | 행 자체가 안 보입니다 — 보여 줄 게 없습니다 |
| 가져오면 늘어남 | `예전 기록 발견 — 펫 2종 · 65,244,929 늘어나요` + 활성 버튼 |
| 이미 다 가져옴 | `예전 기록 200,002,892 — 이미 다 가져왔어요` + 잠긴 버튼 |

처음에는 "늘어날 게 없으면 행을 숨긴다" 로 만들었는데, 그러면 **기능이 아예 없는 것처럼
보입니다** — 이미 가져온 사람이 "가져오기가 어디 있나" 하고 찾게 됩니다. 그래서 상태를
문구로 밝히고 버튼만 잠급니다.

**늘어날 양만 셉니다.** 버튼 문구의 숫자는 예전 기록의 총합이 아니라 펫마다
(예전 값 − 지금 값)이 양수인 것의 합입니다. `swift run` 으로 띄우면 지금 도메인이 예전
목록에 들어가 자기 자신을 가져오라고 권할 수 있는데, 이 계산이면 그것도 사라집니다.

가져오기는 **합치기**입니다 — 펫마다 큰 쪽을 남기므로 실수로 눌러도 경험치가 줄어들지
않습니다. 퀘스트 지급 기록도 함께 합칩니다(중복 지급 방지). 그래도 경험치를 건드리는
동작이라 확인을 한 번 받습니다.

경험치는 `UserDefaults` 에만 쓰면 안 됩니다 — 앱이 메모리에 들고 있는 값을 다음 저장
때 그대로 덮어씁니다. 그래서 가져오기는 앱의 메모리 상태를 먼저 고치고 저장까지 한
번에 합니다(밖에서 `defaults` 로 넣었다가 실제로 한 번 날렸습니다).

```sh
CONNORPET_SELFTEST=migration swift run
```

펫마다 큰 값을 고르는지, 지급 기록을 합치는지, 두 번째 실행은 아무것도 안 하는지,
그리고 **이미 쌓인 값이 있으면 손대지 않는지**를 확인합니다. 사용자의 실제 도메인은
건드리지 않고 검증용 도메인을 만들어 돌린 뒤 지웁니다.

## 권한 목록에 ConnorPet 대신 숫자가 뜨는 문제

시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근에 `ConnorPet` 이 아니라
`2.1.263` 같은 **버전 숫자**가 보이는 일이 있습니다.

`swift run` 은 앱 번들이 아니라 **맨 실행 파일**을 띄웁니다. 그런 프로세스가 보호된
자원을 요구하면 macOS 는 권한을 그것을 **띄운 앱**에 귀속시킵니다 — 터미널이나 Claude
Code 같은 것들입니다. 목록에 뜬 숫자는 그 앱의 버전 문자열입니다.

거기에 체크해도 펫이 아니라 **그 앱에** 권한을 주는 것이고, 그 앱이 업데이트되면 경로가
바뀌어 다시 풀립니다. 그래서 이 상태에서는 설정 창을 열어 주지 않고 사정을 설명합니다
(`FullDiskAccess.isAppBundle`). "만드는 명령 복사" 를 누르면 아래가 클립보드에 들어갑니다.

```sh
bash <저장소>/scripts/make_app.sh && open ~/Applications/ConnorPet.app
```

이렇게 만든 `.app` 은 `CFBundleName = ConnorPet` 과 코드 서명 식별자
`io.github.pet-egg.connorpet` 을 갖기 때문에 권한 목록에 **ConnorPet** 으로 뜹니다.
터미널을 닫아도 죽지 않는다는 이점은 덤입니다.

```sh
CONNORPET_SELFTEST=bundle CONNORPET_EXPECT_BUNDLE=0 swift run
CONNORPET_SELFTEST=bundle CONNORPET_EXPECT_BUNDLE=1 \
  ~/Applications/ConnorPet.app/Contents/MacOS/ConnorPet
```

두 상태를 모두 확인합니다. 안내 명령이 **실제로 있는 스크립트**를 가리키는지도 봅니다 —
경로 탐색이 어긋나면 붙여 넣어도 실행되지 않습니다(실측에서 SwiftPM 판에 따라
`.build/debug` 와 `.build/arm64-apple-macosx/debug` 로 깊이가 달랐습니다).

## 말풍선·경험치 문구가 몇몇 앱 위에서만 안 보이던 문제

바탕화면 위에서는 멀쩡한데 특정 앱 위에서만 말풍선과 마우스 오버 경험치 문구가 보이지
않는다는 제보가 있었습니다. **펫은 잘 보였습니다.**

먼저 흔한 원인들을 재서 지웠습니다. 다른 앱을 앞으로 보낸 뒤 윈도우 서버가 매긴
레이어를 직접 읽어 보니 셋 다 같았습니다.

```
펫 3 · 말풍선 3 · 경험치문구 3
onActiveSpace=true  visible=true  isFloatingPanel=false  hidesOnDeactivate=false
```

층도 스페이스도 같으니 z-순서 문제가 아닙니다. 남은 차이는 **창 종류** 하나였습니다 —
펫만 `NSWindow` 였고 나머지는 전부 `NSPanel` 이었습니다. 그래서 클릭을 통과시키는
오버레이(말풍선·경험치 문구·불꽃·카운트다운)를 펫과 같은 `NSWindow` 로 맞췄습니다.
이 창들은 클릭이 통과하므로 `.nonactivatingPanel` 로 얻을 것이 없고, 포커스를 가져가지
않도록 `canBecomeKey` 는 여전히 `false` 입니다. 클릭을 받아야 하는 대전 신청 말풍선만
패널로 남겨 두었습니다.

```sh
CONNORPET_SELFTEST=overlay swift run
```

다른 앱을 앞으로 보낸 뒤 세 창의 레이어가 같은지 재고, 클릭 통과 오버레이가 다시
`NSPanel` 로 돌아가지 않았는지 지킵니다.

> **주의**: 재현 조건(어떤 앱인지)을 아직 특정하지 못했습니다. 위 측정으로 층·스페이스
> 원인은 배제했고 남은 구조적 차이를 없앤 것이라, 고쳐졌는지는 실제로 그 앱 위에서
> 확인해야 합니다.

## 설정 창이 안 뜨던 문제

메뉴바나 펫 우클릭에서 **설정…** 을 눌렀는데 아무 일도 없는 것처럼 보이는 일이
있었습니다. 창은 만들어지고 `isVisible` 도 참인데 **다른 앱 뒤에 깔립니다.**

이 앱은 `.accessory` 라 메뉴 막대 항목을 눌러도 앱이 활성화되지 않을 때가 있고,
활성화되지 않은 앱의 `activate(ignoringOtherApps:)` 는 최신 macOS 에서 무시됩니다.
그러면 `makeKeyAndOrderFront` 는 **이 앱의 창들 사이에서만** 앞으로 옵니다.

실측에서 같은 코드가 실행마다 갈렸습니다 — 세 번 중 두 번은 포커스를 받고 한 번은
못 받았습니다. 간헐적이라 눈으로는 잡기 어렵습니다.

- `orderFrontRegardless()` 로 활성화 여부와 무관하게 앞으로 내보냅니다.
- 그다음 **떠 있는 층**(`.floating`)에 올립니다. 앞으로 내보내는 것만으로는 다른 앱을
  한 번 클릭하는 순간 다시 뒤로 숨고, 이 앱은 활성화가 막혀 있어 되살릴 방법이
  없습니다. 포커스를 받으면(`windowDidBecomeKey`) 곧바로 보통 층으로 내려, 설정 창이
  계속 위에 떠 있는 성가신 창이 되지는 않습니다.
- 위치는 앞으로 내보내기 **전에** 잡습니다. 나중에 옮기면 한 프레임 다른 자리에 보입니다.

```sh
CONNORPET_SETTINGS_CHECK=1 swift run
```

Finder 를 앞으로 보내 **실제 조건을 만든 뒤**, 메뉴바 "설정…" 항목의 동작을 그대로
보내고(사용자가 누르는 것이 그것입니다) 결과를 봅니다. 판정 기준은 포커스가 아니라
**보이느냐** 입니다 — 포커스를 못 받아도 떠 있는 층에 있으면 눈에는 보입니다. 조건을
만들지 않으면 우리 앱이 유일한 활성 앱이라 그냥 떠서, 정작 고치려는 문제를 재현하지
못합니다.

## 퀘스트 — GitHub PR · Linear 티켓

토큰 경험치는 켜 두면 저절로 오르는 배경 성장입니다. 퀘스트는 **내가 무언가를 끝냈을
때만** 들어옵니다.

| | |
|---|---|
| GitHub PR 생성 | **+300,000 EXP** |
| Linear 티켓 Done | **+300,000 EXP** |
| 확인 주기 | 5분 |

새로 잡히면 펫이 점프하고 `PR pet#21 완료! +300,000 EXP` 라고 한마디 합니다. 메뉴바
→ **퀘스트** 에서 최근 10건을 되짚어 볼 수 있습니다. 모션을 손으로 고정해 둔 중이라면
축하 점프는 건너뜁니다 — 자세를 잡아 놓고 보는 중인데 축하가 그걸 덮으면 지시를 뺏는
셈입니다.

### 경험치 말풍선

경험치가 오른 것을 알리는 말풍선은 브리핑과 다르게 그립니다 — 브리핑은 읽어야 하는
글이고, 이쪽은 **얼마 올랐는지가 먼저 눈에 들어와야** 합니다.

흰 바탕에 경험치 바와 같은 초록 테두리, 그리고 `+300,000 EXP` 부분에 형광펜을 칠하듯
초록 배경을 깔고 글자도 진한 초록으로 바꿉니다. 다크 모드에서도 바탕은 흰색입니다 —
시스템 색을 따르면 초록 글자가 어두운 바탕에 얹혀 경험치 바와 다른 색으로 보입니다.

초록 값은 `PetView.stageColor(0)`(경험치 바 기본 단계)과 같습니다. 색을 옮길 때는 두
곳을 함께 고쳐야 합니다.

### 5분마다 고맙다고 합니다

토큰 경험치는 상태 감시가 도는 0.25초마다 조금씩 오릅니다. 그때마다 인사하면 말풍선이
끊이지 않고, 그렇다고 조용하면 얼마나 받았는지가 안 보입니다. 그래서 **모아 뒀다가
5분에 한 번** `와~! 고마워! 잘 먹었어 / +1,284,932 EXP` 처럼 그동안 받은 양을 말합니다.
인사말은 여섯 가지를 돌려 씁니다 — 같은 말만 하면 금세 배경이 되어 읽지 않게 됩니다.

앱을 켜자마자는 말하지 않습니다. 무엇에 대한 인사인지 알 수 없어서, 첫 창은 실행
시점부터 셉니다.

판단은 `ThanksThrottle` 이 합니다. 타이머를 두지 않고 값을 넣을 때마다 시각과 함께
따지므로, 검증이 실제로 5분을 기다리지 않아도 됩니다.

```sh
CONNORPET_SELFTEST=thanks swift run
```

간격 규칙(첫 호출은 조용 · 간격 전 조용 · 간격 후 모인 양을 한 번에 · 말한 뒤 초기화 ·
1 미만은 조용)을 확인하고, `CONNORPET_THANKS_SHOT=<파일>` 을 주면 말풍선을 실제로 그려
PNG 로 떨어뜨립니다 — 흰 바탕에 초록 강조가 맞는지는 눈으로 봐야 합니다.

### 여러 개가 한꺼번에 잡히면 하나씩 줄을 섭니다

5분 사이에 두 건을 끝냈거나 앱이 꺼져 있던 동안 쌓였으면 여러 개가 같이 잡힙니다.
한꺼번에 부르면 말풍선이 **같은 자리에 겹쳐 뒤엣것만** 읽히므로, 앞 것이 사라진 뒤에
다음이 뜹니다(한 건당 6초, 사이에 0.5초). 간격을 0 으로 붙이면 사라지는 프레임과 뜨는
프레임이 겹쳐 두 개가 한 번에 보입니다.

브리핑을 보는 중이면 축하가 끼어들어 말을 자르지 않습니다 — 줄에서 기다리다가 브리핑이
끝나면 이어집니다. 말풍선을 클릭해 닫아도 줄은 유지됩니다.

무한정 줄을 세우지는 않습니다. 스무 건이 잡히면 2분 넘게 말풍선만 뜨므로, **최근 4건**
까지만 이름을 밝히고 나머지는 `그 밖에 16건 더 완료! +4,800,000 EXP` 한 줄로 접습니다
(말풍선 5개 · 약 32초).

```sh
CONNORPET_SELFTEST=celebrate swift run
```

세 개를 동시에 넣어도 처음 하나만 뜨는지, 순서가 유지되는지, **간격이 노출 시간만큼
벌어져 있는지**(= 겹치지 않는지) 확인합니다. `CONNORPET_CELEBRATION_SECONDS` 로 노출
시간을 줄여서 돕니다.

실측 기준(하루 PR 5.5건 + 티켓 4~5건)으로 하루 약 300만이고 토큰이 1,500만이라,
퀘스트가 하루 성장의 **약 17%** 를 냅니다(2억까지 13.3일 → 약 11.1일). 여전히 성장을
끌고 가는 쪽은 토큰이고 퀘스트는 그 위에 얹는 보너스입니다. 그래서 PR 을 쪼개 올려도
이득이 작아 일일 상한 같은 장치가 따로 필요하지 않습니다.

### 왜 폴링인가

웹훅을 받으려면 이 맥북이 밖에서 접근 가능해야 하고 서버가 필요합니다. 개인
데스크톱 앱에 그걸 붙일 이유가 없어서 5분에 한 번 물어봅니다.

### 중복과 첫 실행

지급한 PR 번호와 티켓 id 를 저장해 두고 **한 번만** 줍니다. PR 을 닫았다 다시 열거나
티켓을 Done → 진행중 → Done 왕복해도 경험치는 한 번입니다.

**처음 켰을 때는 지급하지 않습니다.** 지난 7일치를 전부 주면 한 번에 수백만이 들어와
그날의 성장이 통째로 왜곡됩니다. 첫 실행은 지금까지의 것을 "이미 준 것" 으로만 적어
기준선을 만들고, 그 뒤에 새로 끝난 것부터 셉니다 — 토큰의 `accrualBaseline` 과 같은
방식입니다. "모든 경험치 초기화" 는 이 기록도 함께 지웁니다.

### GitHub — 설정할 것이 없습니다

`gh` CLI 를 그대로 씁니다. 이미 로그인돼 있으면 앱이 토큰을 따로 보관할 필요가
없습니다 — 앱이 남의 자격증명을 들고 있지 않는 것이 가장 안전합니다.

```sh
gh search prs --author @me --created '>=2026-09-01' --json number,title,createdAt,repository
```

GUI 앱은 셸의 `PATH` 를 물려받지 못해서 `/opt/homebrew/bin/gh` 같은 흔한 설치 위치를
직접 뒤집니다. `gh` 가 없거나 로그인이 안 돼 있으면 GitHub 퀘스트만 조용히 꺼집니다.

### Linear — 개인 API 키가 필요합니다

Linear 에는 `gh` 같은 CLI 가 없어서 GraphQL API 를 직접 부르고, 개인 API 키를
**키체인**(암호를 안전하게 보관하는 macOS 기능)에서 읽습니다.

**설정 창 → 연동 → Linear에서 키 만들기 → `열기`** 를 누르면 Linear 의 개인 API 키
화면(Settings › Security & access › Personal API keys)이 브라우저에서 열립니다. 거기서
키를 만들어 바로 아래 **Linear API 키** 에 붙여 넣고 `저장` 을 누릅니다. 입력란은 값이
보이지 않는 칸이고, 누르는 즉시 지웠다가 다시 채워집니다.

저장은 곧 **확인**입니다. 키를 키체인에 넣기 전에 Linear 에 한 번 물어보고, 통하면
`연결됨 — 이름 · 워크스페이스` 로 바뀝니다. 안 통하면 그 자리에서 이유를 보여 주고
**키를 저장하지 않습니다** — 오타 난 키가 저장돼 있으면 5분마다 조용히 거절당하기만
하고 왜 티켓이 안 잡히는지 알 수가 없습니다. (Linear 는 키가 틀려도 HTTP 200 에
`errors` 를 담아 보내므로 상태 코드만 봐서는 잘못된 키를 통과시킵니다.)

터미널을 선호하면 아래도 같습니다 — 서비스 이름이 같아서 앱이 그대로 읽습니다.

```sh
security add-generic-password -s connor-pet-linear -a linear -w
```

키가 없으면 티켓 퀘스트만 꺼지고 PR 퀘스트는 그대로 돕니다. 그동안 펫이 5분에 한 번
`Linear를 연결해봐! 티켓 끝내면 경험치 줄게` 하고 권합니다 — 다른 말풍선과 겹치지 않게
같은 줄에 서고, 키를 넣으면 저절로 멈춥니다. 경험치 알림이 아니므로 초록 강조는 쓰지
않습니다.

#### 붙여넣기가 안 되던 문제

이 앱은 `.accessory` 라 Dock 아이콘도 메뉴 막대도 없습니다. 그런데 ⌘V 같은 단축키는
**`NSApp.mainMenu` 를 뒤져서** 처리됩니다 — 메뉴가 아예 없으면 갈 곳이 없어 아무 일도
일어나지 않습니다. 키를 복사해 와도 붙일 수가 없었습니다.

그래서 잘라내기·복사·붙여넣기·모두 선택만 담은 최소한의 메뉴를 만들어 둡니다
(`EditMenu`). 화면에는 아무것도 나타나지 않습니다 — 오로지 단축키를 받아 주는
통로입니다. 동작은 `nil` 타깃으로 보내 지금 편집 중인 입력란이 응답자 사슬에서 받게
합니다(특정 필드를 가리키면 필드가 늘 때마다 고쳐야 합니다).

```sh
CONNORPET_SELFTEST=paste swift run
```

메뉴에 ⌘V 가 있는지만 보지 않고 **실제로 붙여 봅니다** — 항목이 있어도 셀렉터나 응답자
사슬이 어긋나면 여전히 안 붙기 때문입니다. `NSApp.sendAction(to: nil)` 은 앱 이벤트
루프가 돌아야 응답자를 찾으므로 `app.run()` 안에서 시험하고, 빌려 쓴 클립보드는 원래
내용으로 되돌려 놓습니다.

#### 키체인 암호를 자꾸 물으면

그 창에서 **「항상 허용」** 을 누르세요. 키체인 항목은 그것을 만든 바이너리의 코드
서명에 묶이는데, 개발용 ad-hoc 서명은 **빌드마다 바뀝니다**. 서명이 어긋난 항목은
읽을 때마다 암호 창을 띄웁니다.

그래서 앱은 **실행당 한 번만** 읽고 그 뒤로는 기억한 값을 씁니다. 5분마다 훑는
퀘스트가 호출할 때마다 키체인을 두드리면 5분마다 암호를 묻는 셈이 됩니다. 같은
이유로 저장할 때도 기존 항목을 고치지 않고 **지웠다 다시 넣습니다** — 고치면 그
항목의 권한이 예전 빌드 것이라 또 암호를 묻습니다. 설정 창이 "저장됨" 을 보여 줄
때도 키체인을 읽지 않고 별도 플래그만 봅니다(창을 여는 것만으로 암호 창이 뜨면
곤란합니다).

이 설계는 같은 저자의 [linear-peek](https://github.com/kwonjunhyuk0/linear-peek) 에서
가져왔습니다.

```sh
CONNORPET_SELFTEST=keychain swift run
```

저장·읽기·삭제와, 위의 두 가지(실행당 한 번 읽기 · 갱신 대신 재생성)가 실제로 도는지
봅니다. **사용자의 실제 키는 건드리지 않습니다** — 검증용 서비스 이름으로 갈아 끼우고
돌린 뒤 원래대로 되돌립니다.

### 확인

```sh
CONNORPET_SELFTEST=quest swift run
```

지급 규칙(첫 실행은 기준선만, 새것만, 중복 없음, 초기화 후 재기준선)을 **사용자의 실제
기록을 건드리지 않는 별도 저장소**에 대고 확인하고, 이어서 GitHub 를 실제로 조회해 id
형식과 중복을 봅니다. `gh` 나 네트워크가 없으면 실패가 아니라 건너뜀으로 알립니다.

## 대전 전적과 승리 보상

이기면 **+500,000 EXP**. 전적은 이 맥에만 쌓입니다 — 설정 › 대전 / 노려보기 에서
`3승 2패 · 승률 60%` 처럼 보입니다.

**전적을 주고받지 않는 이유**: 서로 보고하게 만들면 한쪽이 거짓을 보낼 수 있고, 그걸
막으려면 심판이 필요합니다. 개인 데스크톱 앱에 둘 이유가 없습니다. 각자 자기가 본
결과만 적으면 되는데, 어차피 두 기기가 같은 결과를 받습니다(받는 쪽이 계산해 보내므로).

전적과 보상은 **전투 창이 닫힐 때** 처리합니다. 전투 중에 주면 축하 말풍선이 전투 화면
위에 겹칩니다. 창을 클릭해 일찍 넘겨도 승부는 이미 났으므로 한 번은 적힙니다.

한 판도 안 했으면 승률을 **표시하지 않습니다** — 0% 로 보여 주면 "다 졌다" 로 읽힙니다.

보상은 **지금 화면에 있는 펫**에게 들어갑니다(토큰·퀘스트와 같은 규칙). "모든 경험치
초기화" 는 전적도 함께 지웁니다 — 대전으로 얻은 경험치가 사라지는데 전적만 남으면
앞뒤가 맞지 않습니다.

```sh
CONNORPET_SELFTEST=battle swift run
```

전적 계산(무기록일 때 승률 없음 · 3승 2패 → 60% · 다시 읽어도 유지 · 초기화)을
확인합니다. 사용자의 실제 전적은 건드리지 않고 검증용 저장소에 대고 돕니다.

## 노려보기

메뉴바 → **노려보기** 에서 같은 Wi-Fi 의 상대를 고르면, 그쪽 화면에
`OO의 파이리가 노려봅니다.` 알림이 **상대 펫 얼굴과 함께** 뜹니다. 대전 신청과 같은
창이고 확인 버튼 하나뿐, 응답을 기다리지 않습니다 — 보내고 연결을 닫습니다.

### 얼굴은 주고받지 않고 각자 그립니다

스프라이트는 두 앱 모두 번들에 갖고 있으므로, 메시지에 실려 온 slug 로 **각자 자기
번들에서** 찾아 그립니다. 그림을 네트워크로 옮기면 크기도 커지고 위조도 가능해집니다.
우리 번들에 없는 펫(상대가 더 최신 버전일 때)이면 문구만 뜹니다.

광고하는 slug 는 메뉴에서 고른 기본형이 아니라 **지금 화면에 보이는 펫**입니다. 안
그러면 리자몽으로 진화해 놓고도 상대에게는 "파이리가 노려봅니다" 와 파이리 얼굴이
갑니다. 메뉴 선택도 진화도 `refreshDisplayedPet()` 을 지나므로 거기 한 곳에서 갱신합니다.

### 얼굴을 어떻게 잘라내나

프레임 안 여백이 펫마다 크게 다릅니다(실측 채움 46%~83%). 그래서 알파(투명도) 경계를
먼저 구하고, 그 **위쪽 정사각형**을 잘라냅니다. 키가 큰 펫은 머리와 어깨가 남고, 납작한
펫(메타몽·디그다)은 세로가 짧아 정사각형이 가로를 좁히므로 통째로 담깁니다. 펫마다 얼굴
좌표를 손으로 적지 않아도 되는 것이 이 규칙의 값어치입니다.

한때 "맨 위 띠에서 픽셀이 걸친 가운데"를 머리로 보고 그쪽에 맞췄는데, 27종에 돌려 보니
**더 나빴습니다** — 맨 위 픽셀이 머리가 아닌 펫이 많습니다(아차모의 볏, 뚜꾸리·꼬부기의
치켜든 팔, 리자몽의 날개). 그런 펫은 중심이 엉뚱한 곳으로 끌려가 얼굴이 통째로 잘렸습니다.
상자 중심은 어느 펫에서도 크게 어긋나지 않아, 몇 종을 더 잘 잡는 것보다 전부 멀쩡한 쪽을
택했습니다.

```sh
CONNORPET_SELFTEST=portrait swift run
```

번들의 **모든** 펫(메뉴에 안 뜨는 진화형 27종 포함)에 대해 초상이 나오는지, 정사각형인지,
알파 경계로 실제 좁혀졌는지 봅니다. `CONNORPET_PORTRAIT_OUT=<디렉터리>` 를 주면 PNG 로
떨어뜨립니다 — "얼굴이 나왔는지" 는 자동 검사로 알 수 없어 눈으로 봐야 합니다.

보내는 커넥션은 다 보낼 때까지 `stares` 에 붙잡아 둡니다. 대전 신청은 응답을 기다리느라
`outgoing` 에 담기는데 노려보기는 그럴 곳이 없어서, 지역 변수로만 두면 함수가 끝나는
즉시 해제돼 연결이 `.ready` 에 닿지도 못합니다 — 상대 화면이 조용하던 이유가 이것이고,
자체검증 1.5단계가 이 경로를 지킵니다.

## 크레딧 / 라이선스

캐릭터 스프라이트는 Nintendo/Game Freak/Creatures Inc.의 포켓몬 에셋을 [PokeAPI](https://pokeapi.co/) 경유로 가져온 것으로, 개인/데모 용도로만 사용하고 독립된 에셋으로 재배포하지 않습니다. 그 외 이 저장소의 모든 코드(빌드 스크립트, Swift 앱, 미리보기 페이지)는 자유롭게 재사용해도 됩니다.
