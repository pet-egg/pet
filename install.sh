#!/bin/bash
#
# pet 원라이너 설치 스크립트.
#
#   curl -fsSL https://raw.githubusercontent.com/pet-egg/pet/main/install.sh | bash
#
# 하는 일: 최신 릴리스의 pet.dmg 를 받아 마운트 → pet.app 을 /Applications 로 복사 →
# quarantine 플래그 제거(서명·공증 안 한 배포본이라 이걸 벗겨야 열림) → 실행.
# 이미 설치돼 있으면 실행 중인 pet 을 종료한 뒤 통째로 교체한다(업데이트 겸용).

set -euo pipefail

REPO="pet-egg/pet"
DMG_URL="https://github.com/${REPO}/releases/latest/download/pet.dmg"
APP_NAME="pet.app"
DEST="/Applications/${APP_NAME}"

say() { printf '\033[1;36m▸\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "이 스크립트는 macOS 전용입니다."

tmp="$(mktemp -d)"
dmg="${tmp}/pet.dmg"
mnt="${tmp}/mnt"
cleanup() {
  [ -d "$mnt" ] && hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

say "최신 pet.dmg 다운로드 중…"
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
