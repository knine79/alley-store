#!/usr/bin/env bash
#
# 서명 워커를 이 맥에 설치한다.
#
# 워커는 사람이 로그인한 세션에서 돌아야 한다. 서명에 쓰는 개인키가 로그인 키체인에
# 있고, 그 키체인은 로그아웃 상태에서 잠겨 있기 때문이다. 그래서 시스템 데몬이 아니라
# LaunchAgent 로 설치한다.
#
# 설치하는 것은 맨 실행 파일이 아니라 `.app` 번들이다. 이유는 ADR-0022 에 있다.
#
# 사용법:
#   ./scripts/install-worker.sh                     이 레포에서 빌드해 설치한다
#   ./scripts/install-worker.sh --bundle <경로>     이미 만들어진 번들을 설치한다
#   ./scripts/install-worker.sh --uninstall         설치한 것을 되돌린다
#
# `--bundle` 에는 `.app` 디렉터리나 `build-worker-app.sh --sign` 이 만든 `.zip` 을
# 준다. 이 경로는 워커 맥에 소스도 Swift 툴체인도 없을 때 쓴다. 서명·공증된 번들을
# 한 번 만들어 여러 대에 나눠주는 것이 원래 의도한 방식이다.
#
# 설정을 미리 환경변수로 넘기면 묻지 않는다:
#   ALLEY_SERVER_URL, ALLEY_WORKER_TOKEN, ALLEY_SIGNING_IDENTITY,
#   ALLEY_NOTARY_PROFILE, ALLEY_WORKER_NAME
#
# Sparkle 자동 업데이트를 쓰는 조직은 서명 키도 넣습니다 (ADR-0017):
#   ALLEY_SPARKLE_PRIVATE_KEY  Ed25519 시드(base64). `openssl rand -base64 32`
#                              앱의 SUPublicEDKey 에는 이 키의 공개키를 넣습니다.

set -euo pipefail

# 다른 조직에서 그대로 쓰는 값이므로 example 로 둔다. 필요하면 여기만 바꾼다.
LABEL="${ALLEY_WORKER_LABEL:-com.example.alley-worker}"

INSTALL_DIR="$HOME/Library/Application Support/alley-worker"
APP_DIR="$INSTALL_DIR/alley-worker.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/alley-worker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/alley-worker.log"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '경고: %s\n' "$*" >&2; }
die() { printf '오류: %s\n' "$*" >&2; exit 1; }

uninstall() {
    if [ -f "$PLIST" ]; then
        launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        info "LaunchAgent 를 제거했습니다: $PLIST"
    else
        info "설치된 LaunchAgent 가 없습니다."
    fi
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        info "설치 디렉터리를 지웠습니다: $INSTALL_DIR"
    fi
    info "로그는 남겨둡니다: $LOG_FILE"
}

SOURCE_BUNDLE=""
case "${1:-}" in
    --uninstall)
        uninstall
        exit 0
        ;;
    --bundle)
        SOURCE_BUNDLE="${2:-}"
        [ -n "$SOURCE_BUNDLE" ] || die "--bundle 뒤에 번들이나 zip 경로가 필요합니다."
        [ -e "$SOURCE_BUNDLE" ] || die "찾지 못했습니다: $SOURCE_BUNDLE"
        ;;
    "")
        ;;
    *)
        die "알 수 없는 인자: $1"
        ;;
esac

[ "$(uname -s)" = "Darwin" ] || die "서명 워커는 macOS 에서만 돕니다."

# 값이 비어 있으면 묻는다. 토큰은 화면에 찍지 않는다.
ask() {
    local variable="$1" prompt="$2" secret="${3:-}"
    local current="${!variable:-}"
    if [ -n "$current" ]; then
        return
    fi
    if [ -n "$secret" ]; then
        read -r -s -p "$prompt: " value
        echo
    else
        read -r -p "$prompt: " value
    fi
    [ -n "$value" ] || die "$prompt 은(는) 비울 수 없습니다."
    printf -v "$variable" '%s' "$value"
}

info "서명 워커 설치"
echo

ask ALLEY_SERVER_URL "서버 주소 (예: https://store.example.com)"
ask ALLEY_WORKER_TOKEN "워커 토큰 (웹 콘솔의 관리 > 서명 워커에서 발급)" secret

if [ -z "${ALLEY_SIGNING_IDENTITY:-}" ]; then
    echo
    info "이 맥의 서명 identity:"
    security find-identity -v -p codesigning || true
    echo
fi
ask ALLEY_SIGNING_IDENTITY "서명 identity (예: Developer ID Application: Example Inc. (TEAMID))"
ask ALLEY_NOTARY_PROFILE "공증 프로필 이름 (xcrun notarytool store-credentials 로 저장한 것)"

ALLEY_WORKER_NAME="${ALLEY_WORKER_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"

# 설치할 번들을 마련한다. STAGED 는 복사 원본이 될 `.app` 디렉터리다.
STAGED=""
STAGING_DIR=""
cleanup() { [ -n "$STAGING_DIR" ] && rm -rf "$STAGING_DIR"; return 0; }
trap cleanup EXIT

if [ -n "$SOURCE_BUNDLE" ]; then
    case "$SOURCE_BUNDLE" in
        *.zip)
            # 다운로드한 zip 에는 격리 속성이 붙어 있다. 떼지 않는다. 공증받은
            # 이유가 바로 이 상태에서 Gatekeeper 를 통과하는 것이다.
            STAGING_DIR="$(mktemp -d)"
            info "zip 을 풉니다..."
            ditto -x -k "$SOURCE_BUNDLE" "$STAGING_DIR"
            STAGED="$(find "$STAGING_DIR" -maxdepth 2 -name '*.app' -type d | head -1)"
            [ -n "$STAGED" ] || die "zip 안에서 .app 을 찾지 못했습니다: $SOURCE_BUNDLE"
            ;;
        *)
            [ -d "$SOURCE_BUNDLE" ] || die "번들은 디렉터리여야 합니다: $SOURCE_BUNDLE"
            STAGED="$SOURCE_BUNDLE"
            ;;
    esac
else
    # 레포에서 빌드한다. 개발 중에 쓰는 경로다. 나온 번들은 ad-hoc 서명이라
    # 이 맥을 벗어나지 못한다. 다른 맥에 설치할 것은 --sign 으로 만들어 --bundle 로 준다.
    BUILDER="$REPO_ROOT/scripts/build-worker-app.sh"
    [ -x "$BUILDER" ] || die "빌드 스크립트가 없습니다: $BUILDER
소스 없이 설치하려면 --bundle 로 만들어진 번들을 주세요."
    "$BUILDER"
    STAGED="$REPO_ROOT/.build/worker-app/alley-worker.app"
fi

[ -x "$STAGED/Contents/MacOS/alley-worker" ] || die "번들 안에 실행 파일이 없습니다: $STAGED"

# 봉인이 멀쩡한지 먼저 본다. 옮겨 다니는 동안 깨졌을 수 있고, 깨진 채로 등록하면
# launchd 가 조용히 실패한다.
codesign --verify --deep --strict "$STAGED" \
    || die "번들의 서명이 유효하지 않습니다: $STAGED"

# 검증을 통과해도 ad-hoc 서명이면 배포용이 아니다. 이 레포에서 그냥 빌드하면 그
# 상태가 되고, 개발 중에는 그것으로 충분하므로 막지 않고 알리기만 한다.
#
# 누가 서명했는지는 확인하지 않는다. Team ID 는 조직마다 달라서 여기 박을 수 없다
# (ADR-0022 의 나쁜 점 참고).
#
# 파이프로 grep 에 넘기지 않는다. `grep -q` 는 첫 줄을 찾자마자 끝나고, 그때
# codesign 이 SIGPIPE 로 죽으면서 pipefail 이 파이프라인 전체를 실패로 만든다.
# 찾았는데 못 찾은 것처럼 보이는 결과가 나온다.
SIGNATURE_INFO="$(codesign -dv "$STAGED" 2>&1 || true)"
case "$SIGNATURE_INFO" in
    *"Signature=adhoc"*)
        warn "ad-hoc 서명된 번들입니다. 이 맥에서만 쓰세요."
        ;;
    *)
        info "서명을 확인했습니다."
        ;;
esac

mkdir -p "$INSTALL_DIR" "$LOG_DIR"

# 예전 설치는 맨 실행 파일이었다. 남겨두면 launchd 가 새 번들을 가리키는 동안에도
# 옛 바이너리가 디스크에 남아, 다음 사람이 어느 쪽이 도는지 헷갈린다.
if [ -f "$INSTALL_DIR/alley-worker" ]; then
    rm -f "$INSTALL_DIR/alley-worker"
    info "이전 설치(맨 실행 파일)를 지웠습니다."
fi

# 돌고 있는 워커의 실행 파일을 덮어쓰지 않는다. 먼저 내리고 통째로 갈아끼운다.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -rf "$APP_DIR"
ditto "$STAGED" "$APP_DIR"

# 잡을 받은 뒤에 환경 문제를 발견하면 원인 파악이 번거롭다. 설치 시점에 걸러낸다.
info "환경을 점검합니다..."
if ! env \
    ALLEY_SERVER_URL="$ALLEY_SERVER_URL" \
    ALLEY_WORKER_TOKEN="$ALLEY_WORKER_TOKEN" \
    ALLEY_SIGNING_IDENTITY="$ALLEY_SIGNING_IDENTITY" \
    ALLEY_NOTARY_PROFILE="$ALLEY_NOTARY_PROFILE" \
    ALLEY_WORKER_NAME="$ALLEY_WORKER_NAME" \
    ALLEY_SPARKLE_PRIVATE_KEY="${ALLEY_SPARKLE_PRIVATE_KEY:-}" \
    "$EXECUTABLE" preflight
then
    die "환경 점검에 실패했습니다. 위 항목을 고치고 다시 실행하세요."
fi

# 토큰이 들어가는 파일이다. 만들기 전에 권한을 좁혀둔다.
umask 077
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <!-- 번들 안의 실행 파일을 직접 부른다. launchd 는 Launch Services 를 거치지
         않으므로 open(1) 과 달리 Info.plist 의 LSBackgroundOnly 를 보지 않는다.
         그 키는 사람이 번들을 더블클릭했을 때를 위한 것이다.
         이 heredoc 은 변수를 확장해야 해서 따옴표로 막을 수 없다. 여기 들어가는
         글에 백틱이나 $ 를 쓰면 셸이 명령으로 실행해버린다. -->
    <key>ProgramArguments</key>
    <array>
        <string>$EXECUTABLE</string>
        <string>run</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ALLEY_SERVER_URL</key>
        <string>$ALLEY_SERVER_URL</string>
        <key>ALLEY_WORKER_TOKEN</key>
        <string>$ALLEY_WORKER_TOKEN</string>
        <key>ALLEY_SIGNING_IDENTITY</key>
        <string>$ALLEY_SIGNING_IDENTITY</string>
        <key>ALLEY_NOTARY_PROFILE</key>
        <string>$ALLEY_NOTARY_PROFILE</string>
        <key>ALLEY_WORKER_NAME</key>
        <string>$ALLEY_WORKER_NAME</string>
        <key>ALLEY_SPARKLE_PRIVATE_KEY</key>
        <string>${ALLEY_SPARKLE_PRIVATE_KEY:-}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <!-- 워커가 죽으면 다시 띄운다. 잡을 기다리는 것이 이 프로세스의 일이라
         살아 있지 않으면 큐가 그대로 쌓인다. -->
    <key>KeepAlive</key>
    <true/>
    <!-- 설정이 틀려서 즉시 죽는 경우에 초당 한 번씩 다시 뜨며 로그를 채우지 않게 한다. -->
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_EOF
chmod 600 "$PLIST"
umask 022

launchctl bootstrap "gui/$UID" "$PLIST"

echo
info "설치했습니다."
echo "  워커 이름: $ALLEY_WORKER_NAME"
echo "  번들:      $APP_DIR"
echo "  로그:      $LOG_FILE"
echo "  중지:      launchctl bootout gui/$UID/$LABEL"
echo "  제거:      $0 --uninstall"
echo
echo "웹 콘솔의 관리 > 서명 워커에서 이 워커가 보이는지 확인하세요."
