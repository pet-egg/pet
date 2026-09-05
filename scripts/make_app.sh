#!/usr/bin/env bash
# ConnorPet release 빌드를 독립 실행형 .app 번들로 감싸서 설치한다.
#
# `swift run`은 바이너리를 셸의 자식 프로세스로 띄우기 때문에 터미널을 닫으면
# 펫도 같이 죽는다. 이 스크립트로 만든 .app은 Finder/Spotlight에서 실행하는
# 일반 앱이라 터미널과 무관하게 계속 떠 있다.
#
#   ./scripts/make_app.sh              # ~/Applications 에 설치 (기본값)
#   ./scripts/make_app.sh /Applications  # 설치 위치 지정
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/ConnorPet"
INSTALL_DIR="${1:-$HOME/Applications}"
APP="$INSTALL_DIR/ConnorPet.app"

BUNDLE_ID="io.github.pet-egg.connorpet"

# Sparkle 자동 업데이트 설정.
#   - SUFeedURL      : appcast(업데이트 목록)을 올려 둔 곳. GitHub Pages 로 서빙한다.
#   - SUPublicEDKey  : 업데이트 무결성 검증용 EdDSA 공개키. 공개키라 커밋해도 안전하다.
#                      (짝이 되는 개인키는 이 저장소에 없다 — 로컬 키체인 / CI Secret 에만 둔다.)
# 키를 바꾸려면 `generate_keys` 로 새로 만들어 이 값을 교체할 것.
SPARKLE_FEED_URL="https://pet-egg.github.io/pet/appcast.xml"
SPARKLE_PUBLIC_KEY="5zPY3WaXtB6g72hVacYErOpHAnHYAbCcwVGWjK1p8R4="

# 버전은 git 태그가 단일 소스다.
#   CFBundleShortVersionString = 최신 태그(vX.Y.Z → X.Y.Z). UI 에 노출되는 사람용 버전.
#   CFBundleVersion            = 커밋 수. 항상 단조 증가하므로 Sparkle 의 신·구 비교 기준으로 안전.
# 태그가 아직 없으면 0.0.0 으로 떨어진다 (`git tag v0.1.0` 처럼 달면 다음 빌드부터 반영).
# `|| true` 가 없으면 태그가 하나도 없을 때 git describe(exit 128)이 set -e 를
# 건드려 스크립트가 조용히 죽는다. 접두 v 는 파라미터 확장으로 벗긴다.
SHORT_VERSION="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
SHORT_VERSION="${SHORT_VERSION#v}"
[[ -z "$SHORT_VERSION" ]] && SHORT_VERSION="0.0.0"
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
echo "▸ 버전 $SHORT_VERSION (build $BUILD_NUMBER)"

echo "▸ release 빌드"
swift build -c release --package-path "$PACKAGE_DIR"
BIN_DIR="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)"

# 리소스는 Bundle.module로 읽으므로 SwiftPM이 만든 리소스 번들을 반드시 같이
# 넣어야 한다. 바이너리만 복사하면 스프라이트를 못 찾아 실행 즉시 죽는다.
RESOURCE_BUNDLE="$BIN_DIR/ConnorPet_ConnorPet.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "✗ 리소스 번들을 찾을 수 없음: $RESOURCE_BUNDLE" >&2
  exit 1
fi

# SwiftPM 이 빌드 산출물 옆에 놓아 주는 Sparkle.framework. 이걸 .app 안
# Contents/Frameworks 로 넣고 rpath 를 걸어야 배포본에서도 Sparkle 이 로드된다.
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "✗ Sparkle.framework 를 찾을 수 없음: $SPARKLE_FRAMEWORK" >&2
  exit 1
fi

# 교체 대상이 실행 중이면 먼저 종료 (실행 중인 번들을 덮어쓰면 앱이 이상해진다)
if pgrep -f 'ConnorPet\.app/Contents/MacOS/ConnorPet' >/dev/null; then
  echo "▸ 실행 중인 ConnorPet 종료"
  pkill -f 'ConnorPet\.app/Contents/MacOS/ConnorPet' || true
  # 프로세스가 완전히 빠지기를 잠깐 기다린다
  for _ in 1 2 3 4 5; do
    pgrep -f 'ConnorPet\.app/Contents/MacOS/ConnorPet' >/dev/null || break
    sleep 0.3
  done
fi

echo "▸ 번들 생성: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/ConnorPet" "$APP/Contents/MacOS/ConnorPet"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

# Sparkle 임베드: 프레임워크를 Contents/Frameworks 로 복사하고, 실행 파일이
# 거기서 찾도록 @executable_path/../Frameworks rpath 를 건다. SwiftPM 이 넣어 둔
# rpath 는 이 머신의 빌드 경로(절대경로)라 배포본에서는 안 맞으므로 이게 필요하다.
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ConnorPet" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>ConnorPet</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>ConnorPet</string>
	<key>CFBundleDisplayName</key>
	<string>ConnorPet</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<!-- Dock/앱 스위처에 안 뜨는 메뉴바 유틸리티 (코드의 .accessory 정책과 동일 의도) -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<!-- Sparkle 자동 업데이트. 자동 확인/다운로드는 코드에서 끄고(팝업 없음),
	     실행 시 조용히 확인 → 메뉴로만 알림 → 클릭 시 설치. -->
	<key>SUFeedURL</key>
	<string>$SPARKLE_FEED_URL</string>
	<key>SUPublicEDKey</key>
	<string>$SPARKLE_PUBLIC_KEY</string>
	<key>SUEnableAutomaticChecks</key>
	<false/>
</dict>
</plist>
PLIST

# 번들을 복사·이동해도 "손상된 앱" 경고가 뜨지 않도록 ad-hoc 서명.
# 로컬 전용이라 Developer ID 서명·notarization은 필요 없다.
# --deep 로 임베드한 Sparkle.framework(+ 내부 XPC/Autoupdate)까지 함께 봉인한다.
echo "▸ ad-hoc 서명"
codesign --force --deep --sign - "$APP"

echo
echo "✓ 설치 완료: $APP"
echo "  실행: open -a \"$APP\""
echo "  종료: 메뉴바 포켓볼 아이콘 → Quit"
