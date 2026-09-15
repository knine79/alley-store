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
# 조직마다 다른 값은 환경변수로 넘긴다. 이름은 운영 레포 템플릿의
# `config/store.env` 와 맞춘다. 워커의 ALLEY_WORKER_* 와 짝을 이룬다.
#   ALLEY_STORE_APP_BUNDLE_ID    번들 ID       (기본값: com.example.alley.store)
#   ALLEY_STORE_APP_NAME         앱 이름       (기본값: Alley Store)
#   ALLEY_STORE_APP_URL_SCHEME   로그인 콜백 스킴 (기본값: alley)
#   ALLEY_STORE_APP_VERSION      버전 문자열    (기본값: 0.1.0)
#   ALLEY_STORE_APP_BUILD        빌드 번호      (기본값: 1)
#   ALLEY_STORE_APP_SERVER_URL   스토어 주소    (기본값: 없음, 앱이 사람에게 묻는다)
#
# 옛 이름 `ALLEY_APP_*` 도 그대로 받는다. 새 이름이 있으면 그쪽이 이긴다.
#
# 주소를 주면 그것이 Info.plist 에 박히고, 받은 사람은 주소를 입력하지 않는다
# (ADR-0044). 조직에 나눠줄 빌드에는 주면 되고, 아무 서버에나 붙는 빌드가 필요하면
# 주지 않으면 된다.
#
# --sign 을 쓸 때 추가로 필요한 값:
#   ALLEY_SIGNING_IDENTITY  Developer ID Application identity
#   ALLEY_NOTARY_PROFILE    notarytool 키체인 프로필 (없으면 공증을 건너뛴다)

set -euo pipefail

BUNDLE_ID="${ALLEY_STORE_APP_BUNDLE_ID:-${ALLEY_APP_BUNDLE_ID:-com.example.alley.store}}"
APP_NAME="${ALLEY_STORE_APP_NAME:-${ALLEY_APP_NAME:-Alley Store}}"
URL_SCHEME="${ALLEY_STORE_APP_URL_SCHEME:-${ALLEY_APP_URL_SCHEME:-alley}}"
VERSION="${ALLEY_STORE_APP_VERSION:-${ALLEY_APP_VERSION:-0.1.0}}"
BUILD="${ALLEY_STORE_APP_BUILD:-${ALLEY_APP_BUILD:-1}}"
SERVER_URL="${ALLEY_STORE_APP_SERVER_URL:-${ALLEY_APP_SERVER_URL:-}}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/.build/store-app"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"

info() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '오류: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/bundle.sh
. "$REPO_ROOT/scripts/lib/bundle.sh"

[ "$(uname -s)" = "Darwin" ] || die "스토어 앱은 macOS 에서만 만들 수 있습니다."

# 실행 파일 이름에 비ASCII 문자가 들어가면 `codesign --verify --deep --strict` 가
# 그 번들을 거절한다. `.app` 폴더 이름은 한글이어도 괜찮은데 실행 파일만 그렇다.
#
#   Our Store.app / Our Store    → 통과
#   우리스토어.app / AlleyStore   → 통과
#   AlleyStore.app / 우리스토어   → 실패 (a sealed resource is missing or invalid)
#
# 실패는 서명이 끝난 뒤에야 나오고, 문구만 보고 이름이 원인이라는 것을 짐작할 수
# 없다. 설치 가이드가 `ALLEY_STORE_APP_NAME="우리 앱 스토어"` 를 예시로 들고 있어서
# 이 길을 그대로 밟는 사람이 나온다.
#
# 그래서 화면에 보이는 이름과 실행 파일 이름을 나눈다. 서버가 빌드하는 경로도 같은
# 규칙을 쓴다(`StoreAppBundleRewriter.executableName(for:)`). 둘이 갈라지면 어느
# 경로로 지었느냐에 따라 번들 구조가 달라진다.
case "$APP_NAME" in
    *[!\ -~]*)
        EXECUTABLE_NAME="$(printf '%s' "$APP_NAME" | LC_ALL=C tr -cd '[:alnum:]')"
        [ -n "$EXECUTABLE_NAME" ] || EXECUTABLE_NAME="AlleyStore"
        ;;
    *) EXECUTABLE_NAME="$APP_NAME" ;;
esac

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

# 무엇으로 짓는지 먼저 찍는다. 값이 안 넘어와도 빌드는 성공하고 기본값으로 나가서,
# 번들 ID 가 틀린 것을 한참 뒤에 설치 화면에서 알게 된다.
info "$APP_NAME $VERSION ($BUILD)"
echo "  번들 ID  $BUNDLE_ID"
echo "  URL 스킴 $URL_SCHEME"
[ "$EXECUTABLE_NAME" = "$APP_NAME" ] || echo "  실행 파일 $EXECUTABLE_NAME (이름에 비ASCII 문자가 있어 바꿨습니다)"
echo "  스토어   ${SERVER_URL:-(빌드에 박지 않음. 받은 사람이 입력합니다)}"

info "빌드합니다..."
(cd "$REPO_ROOT" && swift build -c release --product alley-store-app)
BINARY="$(cd "$REPO_ROOT" && swift build -c release --show-bin-path)/alley-store-app"
[ -x "$BINARY" ] || die "빌드 결과를 찾지 못했습니다: $BINARY"

info "번들을 조립합니다..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# 실행 파일 이름은 CFBundleExecutable 과 같아야 한다.
cp "$BINARY" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod 755 "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

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
    <string>$EXECUTABLE_NAME</string>
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

if [ "${1:-}" != "--sign" ]; then
    bundle_seal_adhoc "$APP_DIR"

    # 서명하지 않은 번들도 zip 으로 내놓는다. 관리 화면의 "베이스 번들" 이 이것을
    # 받아 조직의 값으로 다시 싼다 (ADR-0046). 이름을 앱 이름이 아니라 고정값으로
    # 두는 것은, 이 산출물을 받아가는 쪽(릴리스 asset, 관리 화면)이 앱 이름을 모르기
    # 때문이다.
    UNSIGNED_ARCHIVE="$OUTPUT_DIR/alley-store-app-unsigned.zip"
    bundle_archive "$APP_DIR" "$UNSIGNED_ARCHIVE"

    echo
    echo "서명하지 않은 번들입니다. 다른 맥에서 실행하려면 --sign 으로 다시 만드세요."
    echo "베이스 번들: $UNSIGNED_ARCHIVE"
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
