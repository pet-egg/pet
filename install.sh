#!/bin/bash
#
# pet 원라이너 설치 스크립트.
#
#   # 최신(latest) 설치
#   curl -fsSL https://raw.githubusercontent.com/pet-egg/pet/main/install.sh | bash
#   # 안정화(stable) 설치 — 직전 마이너 라인의 최고 패치 버전
#   curl -fsSL https://raw.githubusercontent.com/pet-egg/pet/main/install.sh | PET_CHANNEL=stable bash
#   curl -fsSL https://raw.githubusercontent.com/pet-egg/pet/main/install.sh | bash -s -- --stable
#
# 하는 일: 릴리스의 pet.dmg 를 받아 마운트 → pet.app 을 /Applications 로 복사 →
# quarantine 플래그 제거(서명·공증 안 한 배포본이라 이걸 벗겨야 열림) → 실행.
# 이미 설치돼 있으면 실행 중인 pet 을 종료한 뒤 통째로 교체한다(업데이트 겸용).
#
# 채널:
#   latest(기본) — releases/latest = 가장 최근 태그.
#   stable       — "직전 마이너 라인의 최고 패치". 최신 마이너는 패치가 안 쌓여 검증이
#                  덜 됐다고 보고, 바로 이전 마이너의 마지막 패치를 받는다
#                  (예: 최신 v1.6.0 → stable v1.5.4). PET_CHANNEL=stable 또는 --stable.

set -euo pipefail

REPO="pet-egg/pet"
APP_NAME="pet.app"
DEST="/Applications/${APP_NAME}"

# 채널 결정: 환경변수 PET_CHANNEL 우선, 그 위에 인자(--stable/--latest)로 덮어씀.
CHANNEL="${PET_CHANNEL:-latest}"
for arg in "$@"; do
  case "$arg" in
    --stable) CHANNEL="stable" ;;
    --latest) CHANNEL="latest" ;;
  esac
done

say() { printf '\033[1;36m▸\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "이 스크립트는 macOS 전용입니다."

# 안정화(stable) 태그 계산: GitHub 릴리스 목록에서 vX.Y.Z 안정 태그만 골라
# 내림차순 정렬한 뒤, 최신과 "major.minor" 가 다른 첫 버전(=직전 마이너 라인의 최고
# 패치)을 고른다. macOS 기본 BSD sort 는 -V 가 없어 필드 숫자 정렬(-t. -kN,Nnr)을 쓴다.
# 직전 마이너가 없으면(마이너 하나뿐) 최신으로 폴백.
resolve_stable_tag() {
  local api tags sorted newest newest_mm line mm
  api="https://api.github.com/repos/${REPO}/releases?per_page=100"
  tags="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api" \
    | grep '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" || return 1
  sorted="$(printf '%s\n' "$tags" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr)"
  [ -n "$sorted" ] || return 1
  newest="$(printf '%s\n' "$sorted" | head -1)"
  newest_mm="${newest%.*}"   # major.minor
  while IFS= read -r line; do
    mm="${line%.*}"
    if [ "$mm" != "$newest_mm" ]; then
      printf 'v%s\n' "$line"
      return 0
    fi
  done <<EOF
$sorted
EOF
  printf 'v%s\n' "$newest"   # 직전 마이너 없음 → 최신으로 폴백
  return 0
}

if [ "$CHANNEL" = "stable" ]; then
  say "안정화(stable) 버전 확인 중…"
  STABLE_TAG="$(resolve_stable_tag)" || die "릴리스 목록을 읽지 못했습니다 (네트워크/GitHub API 확인)."
  [ -n "${STABLE_TAG:-}" ] || die "안정화 버전을 찾지 못했습니다."
  DMG_URL="https://github.com/${REPO}/releases/download/${STABLE_TAG}/pet.dmg"
  say "안정화 버전: ${STABLE_TAG}"
else
  DMG_URL="https://github.com/${REPO}/releases/latest/download/pet.dmg"
fi

tmp="$(mktemp -d)"
dmg="${tmp}/pet.dmg"
mnt="${tmp}/mnt"
cleanup() {
  [ -d "$mnt" ] && hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

say "pet.dmg 다운로드 중… (${CHANNEL})"
curl -fsSL -o "$dmg" "$DMG_URL" || die "다운로드 실패: $DMG_URL"

say "디스크 이미지 마운트 중…"
mkdir -p "$mnt"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet || die "마운트 실패"

src="${mnt}/${APP_NAME}"
[ -d "$src" ] || die "dmg 안에서 ${APP_NAME} 을 찾지 못했습니다."

# 실행 중이면 종료(파일이 잠겨 교체가 실패하는 것 방지).
if pgrep -x "pet" >/dev/null 2>&1; then
  say "실행 중인 pet 종료 중…"
  osascript -e 'quit app "pet"' >/dev/null 2>&1 || pkill -x "pet" >/dev/null 2>&1 || true
  sleep 1
fi

say "${DEST} 로 설치 중…"
rm -rf "$DEST"
cp -R "$src" "$DEST" || die "복사 실패 — /Applications 쓰기 권한을 확인하세요."

say "quarantine 플래그 제거 중…"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

say "실행합니다…"
open "$DEST"

printf '\033[1;32m✔ 설치 완료\033[0m — 메뉴바 아이콘에서 pet 을 확인하세요.\n'
