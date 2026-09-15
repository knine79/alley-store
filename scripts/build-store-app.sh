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
#   ALLEY_STORE_APP_SERVER_URL  스토어 주소 (기본값: 없음, 앱이 사람에게 묻는다)
#
# 주소를 주면 그것이 Info.plist 에 박히고, 받은 사람은 주소를 입력하지 않는다
# (ADR-0044). 조직에 나눠줄 빌드에는 주면 되고, 아무 서버에나 붙는 빌드가 필요하면
# 주지 않으면 된다.
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
# 다른 값들과 이름 규칙을 맞춘다. 짧은 이름도 받아 두는 것은 이 값이 생기기 전부터
# 쓰이던 표기가 스크립트 곳곳에 남아 있어서다.
SERVER_URL="${ALLEY_STORE_APP_SERVER_URL:-${ALLEY_APP_SERVER_URL:-}}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/.build/store-app"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"

info() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '오류: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/bundle.sh
. "$REPO_ROOT/scripts/lib/bundle.sh"

[ "$(uname -s)" = "Darwin" ] || die "스토어 앱은 macOS 에서만 만들 수 있습니다."

# 주소는 스킴까지 받는다. `store.example.com` 만 적으면 앱이 그것을 경로로 읽는다.
#
# 여기서 막지 않으면 서명·공증까지 다 끝난 뒤 사람 손에서 드러난다. 그때는 다시
# 만드는 데 공증 대기만큼이 더 든다.
SERVER_ENTRY=""
if [ -n "$SERVER_URL" ]; then
    case "$SERVER_URL" in
        https://*) ;;
        http://*)
            echo "경고: 평문 http 주소입니다. 사내망이 아니면 다시 보세요: $SERVER_URL" >&2
            ;;
        *) die "스토어 주소는 https:// 로 시작해야 합니다: $SERVER_URL" ;;
    esac
    case "$SERVER_URL" in
        */) die "스토어 주소 끝의 슬래시를 빼세요: $SERVER_URL" ;;
    esac
    SERVER_ENTRY="    <!-- 이 빌드가 붙는 스토어. 없으면 앱이 사람에게 묻는다(ADR-0044). -->
    <key>AlleyServerURL</key>
    <string>$SERVER_URL</string>"
fi

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
$SERVER_ENTRY
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
if [ -n "$SERVER_URL" ]; then
    echo "붙을 스토어: $SERVER_URL"
else
    echo "스토어 주소는 받은 사람이 입력합니다. ALLEY_STORE_APP_SERVER_URL 을 주면 박힙니다."
fi

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
