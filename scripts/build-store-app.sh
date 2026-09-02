#!/usr/bin/env bash
#
# 스토어 앱을 .app 번들로 조립한다.
#
# SwiftPM 은 실행 파일 하나만 만든다. macOS 앱으로 쓰려면 Info.plist 와 정해진
# 디렉터리 구조가 필요해서, 그 껍데기를 여기서 씌운다. Xcode 프로젝트를 두지 않는
# 이유는 ADR-0014 에 있다.
#
# 서명·공증 절차는 워커 번들과 같아서 scripts/lib/bundle.sh 에 모아두었다(ADR-0022).
#
# 사용법:
#   ./scripts/build-store-app.sh                 번들만 만든다
#   ./scripts/build-store-app.sh --sign          서명·공증까지 한다
#
# 조직마다 다른 값은 환경변수로 넘긴다:
#   ALLEY_APP_BUNDLE_ID     번들 ID       (기본값: com.example.alley.store)
#   ALLEY_APP_NAME          앱 이름       (기본값: Alley Store)
#   ALLEY_APP_URL_SCHEME    로그인 콜백 스킴 (기본값: alley)
#   ALLEY_APP_VERSION       버전 문자열    (기본값: 0.1.0)
#   ALLEY_APP_BUILD         빌드 번호      (기본값: 1)
#
# --sign 을 쓸 때 추가로 필요한 값:
#   ALLEY_SIGNING_IDENTITY  Developer ID Application identity
#   ALLEY_NOTARY_PROFILE    notarytool 키체인 프로필 (없으면 공증을 건너뛴다)

set -euo pipefail

BUNDLE_ID="${ALLEY_APP_BUNDLE_ID:-com.example.alley.store}"
APP_NAME="${ALLEY_APP_NAME:-Alley Store}"
URL_SCHEME="${ALLEY_APP_URL_SCHEME:-alley}"
VERSION="${ALLEY_APP_VERSION:-0.1.0}"
BUILD="${ALLEY_APP_BUILD:-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/.build/store-app"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"

info() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '오류: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/bundle.sh
. "$REPO_ROOT/scripts/lib/bundle.sh"

[ "$(uname -s)" = "Darwin" ] || die "스토어 앱은 macOS 에서만 만들 수 있습니다."

info "빌드합니다..."
(cd "$REPO_ROOT" && swift build -c release --product alley-store-app)
BINARY="$(cd "$REPO_ROOT" && swift build -c release --show-bin-path)/alley-store-app"
[ -x "$BINARY" ] || die "빌드 결과를 찾지 못했습니다: $BINARY"

info "번들을 조립합니다..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# 실행 파일 이름은 CFBundleExecutable 과 같아야 한다.
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- 메뉴 막대에 뜨는 보통의 앱이다. -->
    <key>LSUIElement</key>
    <false/>
    <!-- 로그인 콜백으로 돌아올 스킴. 서버의 STORE_APP_URL_SCHEME 과 같아야 한다.
         ASWebAuthenticationSession 은 등록 없이도 콜백을 받지만, 등록해두면
         다른 앱이 같은 스킴을 가로채는 것을 사용자가 알아볼 수 있다. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>$URL_SCHEME</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST_EOF

info "번들을 만들었습니다: $APP_DIR"

if [ "${1:-}" != "--sign" ]; then
    bundle_seal_adhoc "$APP_DIR"
    echo
    echo "서명하지 않은 번들입니다. 다른 맥에서 실행하려면 --sign 으로 다시 만드세요."
    exit 0
fi

bundle_sign "$APP_DIR"

ARCHIVE="$OUTPUT_DIR/$APP_NAME.zip"
bundle_archive "$APP_DIR" "$ARCHIVE"

if [ -z "${ALLEY_NOTARY_PROFILE:-}" ]; then
    echo
    echo "공증은 건너뜁니다. ALLEY_NOTARY_PROFILE 을 주면 함께 처리합니다."
    echo "결과: $ARCHIVE"
    exit 0
fi

bundle_notarize "$APP_DIR" "$ARCHIVE"

info "끝났습니다: $ARCHIVE"
echo "이 zip 을 웹 콘솔에 '서명·공증 완료' 로 올리면 스토어 앱 자신도 스토어에서 배포됩니다."
