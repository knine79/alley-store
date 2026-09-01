#!/usr/bin/env bash
#
# 서명 워커를 이 맥에 설치한다.
#
# 워커는 사람이 로그인한 세션에서 돌아야 한다. 서명에 쓰는 개인키가 로그인 키체인에
# 있고, 그 키체인은 로그아웃 상태에서 잠겨 있기 때문이다. 그래서 시스템 데몬이 아니라
# LaunchAgent 로 설치한다.
#
# 사용법:
#   ./scripts/install-worker.sh                 대화식으로 설정을 묻는다
#   ./scripts/install-worker.sh --uninstall     설치한 것을 되돌린다
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

if [ "${1:-}" = "--uninstall" ]; then
    uninstall
    exit 0
fi

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

# 빌드는 레포에서 한다. 릴리즈 빌드로 설치해야 공증 대기 중 메모리와 CPU 를 덜 쓴다.
info "워커를 빌드합니다..."
(cd "$REPO_ROOT" && swift build -c release --product alley-worker)
BINARY="$(cd "$REPO_ROOT" && swift build -c release --show-bin-path)/alley-worker"
[ -x "$BINARY" ] || die "빌드 결과를 찾지 못했습니다: $BINARY"

mkdir -p "$INSTALL_DIR" "$LOG_DIR"
cp "$BINARY" "$INSTALL_DIR/alley-worker"
chmod 755 "$INSTALL_DIR/alley-worker"

# 잡을 받은 뒤에 환경 문제를 발견하면 원인 파악이 번거롭다. 설치 시점에 걸러낸다.
info "환경을 점검합니다..."
if ! env \
    ALLEY_SERVER_URL="$ALLEY_SERVER_URL" \
    ALLEY_WORKER_TOKEN="$ALLEY_WORKER_TOKEN" \
    ALLEY_SIGNING_IDENTITY="$ALLEY_SIGNING_IDENTITY" \
    ALLEY_NOTARY_PROFILE="$ALLEY_NOTARY_PROFILE" \
    ALLEY_WORKER_NAME="$ALLEY_WORKER_NAME" \
    ALLEY_SPARKLE_PRIVATE_KEY="${ALLEY_SPARKLE_PRIVATE_KEY:-}" \
    "$INSTALL_DIR/alley-worker" preflight
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
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/alley-worker</string>
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

# 이미 돌고 있으면 내리고 다시 올린다. 설정이 바뀌었을 수 있다.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo
info "설치했습니다."
echo "  워커 이름: $ALLEY_WORKER_NAME"
echo "  로그:      $LOG_FILE"
echo "  중지:      launchctl bootout gui/$UID/$LABEL"
echo "  제거:      $0 --uninstall"
echo
echo "웹 콘솔의 관리 > 서명 워커에서 이 워커가 보이는지 확인하세요."
