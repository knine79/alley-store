#!/usr/bin/env bash
#
# 서명 워커를 .app 번들로 조립한다.
#
# 워커는 UI 가 없는데도 번들로 만든다. 이유는 공증 티켓이다. `xcrun stapler` 는
# 티켓을 박을 자리가 필요해서 맨 실행 파일에는 스테이플할 수 없다. 스테이플하지
# 않으면 워커 맥이 처음 실행할 때마다 Apple 서버 조회가 필요하고, 그 조회가 실패하는
# 순간 워커가 뜨지 않는다. 번들이면 티켓이 안에 박혀 오프라인에서도 통과한다.
#
# 조립·서명 절차는 스토어 앱과 같아서 scripts/lib/bundle.sh 를 함께 쓴다(ADR-0022).
#
# 사용법:
#   ./scripts/build-worker-app.sh                 번들만 만든다
#   ./scripts/build-worker-app.sh --sign          서명·공증까지 한다
#
# 조직마다 다른 값은 환경변수로 넘긴다:
#   ALLEY_WORKER_BUNDLE_ID   번들 ID   (기본값: com.example.alley.worker)
#   ALLEY_WORKER_VERSION     버전 문자열 (기본값: 0.1.0)
#   ALLEY_WORKER_BUILD       빌드 번호  (기본값: 1)
#
# --sign 을 쓸 때 추가로 필요한 값:
#   ALLEY_SIGNING_IDENTITY   Developer ID Application identity
#   ALLEY_NOTARY_PROFILE     notarytool 키체인 프로필 (없으면 공증을 건너뛴다)

set -euo pipefail

BUNDLE_ID="${ALLEY_WORKER_BUNDLE_ID:-com.example.alley.worker}"
VERSION="${ALLEY_WORKER_VERSION:-0.1.0}"
BUILD="${ALLEY_WORKER_BUILD:-1}"

# 번들 이름과 실행 파일 이름을 사람이 보는 이름과 분리한다. 이 번들은 Finder 에도
# Dock 에도 나타나지 않고 launchd 가 실행 파일을 직접 부르므로, 경로에 공백이 없는
# 쪽이 launchd plist 와 로그 검색 모두에서 편하다.
APP_NAME="alley-worker"
DISPLAY_NAME="Alley Signing Worker"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/.build/worker-app"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"

info() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '오류: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/bundle.sh
. "$REPO_ROOT/scripts/lib/bundle.sh"

[ "$(uname -s)" = "Darwin" ] || die "서명 워커는 macOS 에서만 만들 수 있습니다."

info "빌드합니다..."
(cd "$REPO_ROOT" && swift build -c release --product alley-worker)
BINARY="$(cd "$REPO_ROOT" && swift build -c release --show-bin-path)/alley-worker"
[ -x "$BINARY" ] || die "빌드 결과를 찾지 못했습니다: $BINARY"

info "번들을 조립합니다..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

# 실행 파일 이름은 CFBundleExecutable 과 같아야 한다.
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_DIR/Contents/MacOS/$APP_NAME"

# LSUIElement 가 아니라 LSBackgroundOnly 를 쓴다.
#
# Apple 의 Launch Services Keys 문서가 둘을 이렇게 나눈다. LSUIElement 는 "agent
# app" 으로, Dock 에 안 뜨지만 "can come to the foreground to present a user
# interface if desired" 다. 메뉴 막대 앱이 이 자리다. LSBackgroundOnly 는 "runs
# only in the background ... faceless background apps" 로, 앞으로 나올 수 없다.
#
# 워커는 화면에 아무것도 그리지 않고 AppKit 을 링크하지도 않는다. 둘 중 실제 성질을
# 그대로 적은 쪽은 LSBackgroundOnly 다. LSUIElement 를 쓰면 "지금은 UI 가 없지만
# 언제든 띄울 수 있다" 고 선언하는 셈이라 사실과 다르다.
#
# 다만 평소에는 이 키가 쓰이지 않는다. launchd 가 Contents/MacOS 의 실행 파일을
# 직접 exec 하므로 Launch Services 를 거치지 않는다. 이 키가 일하는 때는 누군가
# 번들을 Finder 에서 더블클릭하거나 `open` 으로 열 때다. 그때 Dock 아이콘이 뜨지
# 않게 하는 것이 목적이다.
cat > "$APP_DIR/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
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
    <!-- UI 가 없는 백그라운드 프로세스다. 위 주석 참고. -->
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
PLIST_EOF

info "번들을 만들었습니다: $APP_DIR"

if [ "${1:-}" != "--sign" ]; then
    bundle_seal_adhoc "$APP_DIR"
    echo
    echo "서명하지 않은 번들입니다. 다른 맥에 설치하려면 --sign 으로 다시 만드세요."
    exit 0
fi

# 워커에는 entitlements 를 붙이지 않는다.
#
# Hardened Runtime 이 막는 것은 JIT, 서명되지 않은 실행 메모리, 라이브러리 검증
# 우회, DYLD 환경변수, 디버거 붙이기다. 자식 프로세스를 띄우는 것은 그 목록에 없다.
# 워커가 하는 일은 codesign·ditto·xcrun 을 exec 하는 것뿐이라 필요한 예외가 없다.
# 예방 차원으로 넣어두면 그 예외가 실제로 필요해졌을 때 아무도 알아채지 못한다.
bundle_sign "$APP_DIR"

ARCHIVE="$OUTPUT_DIR/$APP_NAME.zip"
KIT="$OUTPUT_DIR/$APP_NAME-kit.zip"

bundle_archive "$APP_DIR" "$ARCHIVE"

# 설치 키트를 함께 만든다.
#
# 워커 맥으로 옮길 파일을 하나로 줄이려는 것이다. 번들만 보내면 설치 스크립트를
# 레포에서 따로 꺼내 함께 보내야 하고, 그러면 둘의 버전이 어긋날 수 있다. 스크립트가
# 번들 옆에 들어 있으면 그 짝이 항상 맞는다.
#
# **자격증명은 넣지 않는다.** 인증서와 공증 키는 따로 옮긴다. 한 파일에 모으면
# 그것 하나가 새는 순간 조직의 서명 권한이 통째로 넘어간다.
#
# 스테이플은 번들의 내용을 바꾸므로 공증 뒤에 한 번 더 만들어야 한다.
make_kit() {
    local staging="$OUTPUT_DIR/kit"
    rm -rf "$staging" "$KIT"
    mkdir -p "$staging"
    ditto "$APP_DIR" "$staging/$APP_NAME.app"
    cp "$REPO_ROOT/scripts/install-worker.sh" "$staging/install-worker.sh"
    chmod +x "$staging/install-worker.sh"
    # 설정 본보기는 넣지 않는다.
    #
    # 채운 설정 파일에는 워커 토큰과 인증서 암호가 들어간다. 본보기가 키트 안에
    # 있으면 그 자리에서 복사해 채우게 되고, 그러면 비밀이 키트 디렉터리 안에
    # 남는다. 그 디렉터리는 통째로 옮기거나 다시 압축하기 쉬운 자리다.
    #
    # 대신 스크립트의 `--init-config` 가 채울 파일을 만들어준다. 어디에 둘지는
    # 설치하는 사람이 정한다.
    ditto -c -k --sequesterRsrc --keepParent "$staging" "$KIT"
    rm -rf "$staging"
}

print_next_steps() {
    echo
    echo "번들만:    $ARCHIVE"
    echo "설치 키트: $KIT"
    echo
    echo "워커 맥에서 키트를 풀고 설정 파일을 채워 한 번에 설치합니다:"
    echo "  ditto -x -k $APP_NAME-kit.zip ."
    echo "  cd kit"
    echo "  ./install-worker.sh --init-config ~/worker.conf   # 채울 파일을 만듭니다"
    echo "  vi ~/worker.conf                                  # 값을 채웁니다"
    echo "  ./install-worker.sh --config ~/worker.conf        # 설치합니다"
    echo
    echo "설정 파일은 키트 밖에 둡니다. 토큰과 인증서 암호가 들어가는 파일이라"
    echo "키트 안에 두면 그 디렉터리를 옮길 때 함께 딸려갑니다."
}

make_kit

if [ -z "${ALLEY_NOTARY_PROFILE:-}" ]; then
    echo
    echo "공증은 건너뜁니다. ALLEY_NOTARY_PROFILE 을 주면 함께 처리합니다."
    echo "공증하지 않은 번들은 다른 맥에서 Gatekeeper 에 막힙니다."
    print_next_steps
    exit 0
fi

bundle_notarize "$APP_DIR" "$ARCHIVE"
make_kit

info "끝났습니다."
print_next_steps
