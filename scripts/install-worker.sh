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
#   ./install-worker.sh                     이 레포에서 빌드해 설치한다
#   ./install-worker.sh --bundle <경로>     이미 만들어진 번들을 설치한다
#   ./install-worker.sh --uninstall         설치한 것을 되돌린다
#
# 새 맥에 한 번에 설치하기. 값을 설정 파일 하나에 적습니다:
#
#   ./install-worker.sh --init-config ~/worker.conf   # 채울 파일을 만듭니다 (권한 600)
#   vi ~/worker.conf                                  # 값을 채웁니다
#   ./install-worker.sh --config ~/worker.conf        # 설치합니다
#
# 설정 파일은 키트 밖에 두세요. 워커 토큰과 인증서 암호가 들어가는 파일이라
# 키트 디렉터리 안에 두면 그것을 옮기거나 다시 압축할 때 함께 딸려갑니다.
#
# 인증서를 키체인에 넣고, 공증 프로필을 만들고, 워커를 설치하고, 환경 점검까지
# 한 번에 합니다. 설정 파일을 다 채웠으면 아무것도 묻지 않습니다.
#
# 설정 파일 없이 명령줄로 줄 수도 있습니다:
#
#   ./install-worker.sh \
#       --bundle alley-worker.app \
#       --p12 signing.p12 \
#       --asc-key AuthKey_XXXX.p8 --asc-key-id ABC1234567 \
#       --asc-issuer 00000000-0000-0000-0000-000000000000
#
# 옵션:
#   --config <경로>       채워둔 설정 파일로 설치합니다
#   --init-config <경로>  채울 설정 파일을 만듭니다 (권한 600, 덮어쓰지 않음)
#   --bundle <경로>       `.app` 디렉터리 또는 `build-worker-app.sh --sign` 이 만든 zip
#   --p12 <경로>          Developer ID 인증서+개인키. 암호는 따로 묻습니다
#   --asc-key <경로>      공증용 App Store Connect API 키 (`.p8`)
#   --asc-key-id <값>     그 키의 Key ID (10자)
#   --asc-issuer <값>     Issuer ID (UUID)
#   --notary-profile <값> 공증 프로필 이름 (기본값: alley)
#   --uninstall           설치한 것을 되돌립니다
#
# `--p12` 와 `--asc-key` 는 생략해도 됩니다. 이미 그 맥에 인증서와 공증 프로필이
# 있으면 설치만 합니다.
#
# 값을 정하는 순서는 **명령줄 > 설정 파일 > 환경변수 > 물어보기** 입니다.
# 설정 파일 안의 상대 경로는 그 파일이 있는 디렉터리 기준으로 찾습니다.
#
# 환경변수로도 줄 수 있습니다. 이름은 설정 파일의 항목과 같습니다:
#   ALLEY_SERVER_URL, ALLEY_WORKER_TOKEN, ALLEY_SIGNING_IDENTITY,
#   ALLEY_NOTARY_PROFILE, ALLEY_WORKER_NAME, ALLEY_P12_PASSWORD,
#   ALLEY_KEYCHAIN_PASSWORD
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
P12_PATH=""
ASC_KEY_PATH=""
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
CONFIG_PATH=""

# 설정 파일에서 읽을 수 있는 키. 여기 없는 키는 오타로 본다.
#
# 조용히 무시하지 않는다. `ALLEY_SERVER_UR=...` 처럼 한 글자 틀린 것을 넘기면
# 스크립트가 그 값을 묻기 시작하는데, 설정 파일을 쓴 사람은 왜 묻는지 모른다.
CONFIG_KEYS="
ALLEY_SERVER_URL
ALLEY_WORKER_TOKEN
ALLEY_WORKER_NAME
ALLEY_SIGNING_IDENTITY
ALLEY_NOTARY_PROFILE
ALLEY_SPARKLE_PRIVATE_KEY
ALLEY_P12_PATH
ALLEY_P12_PASSWORD
ALLEY_KEYCHAIN_PASSWORD
ALLEY_ASC_KEY_PATH
ALLEY_ASC_KEY_ID
ALLEY_ASC_ISSUER_ID
ALLEY_BUNDLE_PATH
"

# 채울 설정 파일을 만든다.
#
# 만드는 것과 쓰는 것을 다른 옵션으로 둔다. `--config` 가 없는 파일을 알아서
# 만들어주면 편할 것 같지만, 그러면 **경로를 잘못 친 것을 잡을 수 없다.**
# `--config ~/wroker.conf` 가 오류 대신 빈 설정 파일 하나를 새로 만들고, 사람은
# 왜 값을 다시 묻는지 모른다. 만드는 것은 한 번뿐이라 그때만 다른 명령을 치면 된다.
#
# 만들 때 권한까지 여기서 준다. 본보기를 stdout 으로 찍고 사람이 리다이렉트하게
# 두면 `chmod 600` 이 별도 단계로 남고, 그것을 잊으면 워커 토큰과 인증서 암호가
# 든 파일이 남이 읽을 수 있는 채로 남는다.
init_config() {
    local path="$1"
    [ -n "$path" ] || die "--init-config 뒤에 만들 파일 경로가 필요합니다.
예: ./install-worker.sh --init-config ~/worker.conf"

    case "$path" in '~/'*) path="$HOME/${path#\~/}" ;; esac

    # 이미 채워둔 설정을 덮어쓰지 않는다.
    [ ! -e "$path" ] || die "이미 있는 파일입니다: $path
덮어쓰지 않았습니다. 그 파일을 그대로 쓰려면:
    $0 --config $path"

    ( umask 077; config_template > "$path" ) || die "설정 파일을 만들지 못했습니다: $path"
    chmod 600 "$path"

    info "설정 파일을 만들었습니다: $path"
    echo
    echo "  권한은 600 입니다. 값을 채운 뒤 설치합니다:"
    echo "    $0 --config $path"
    echo
    echo "  꼭 채워야 하는 것은 서버 주소와 워커 토큰입니다."
    echo "  토큰은 웹 콘솔의 관리 > 서명 워커에서 발급합니다."
}

config_template() {
    /bin/cat <<'CONFIG_EOF'
# 서명 워커 설치 설정.
#
# 값을 채운 뒤:
#   ./install-worker.sh --config <이 파일>
#
# **워커 토큰과 인증서 암호가 들어갑니다.** 이 파일은 권한 600 으로 만들어졌습니다.
# 다른 곳으로 복사하면 권한도 함께 챙기세요. 설치가 끝나면 지워도 됩니다.
#
# 값에 따옴표는 필요 없습니다. `#` 로 시작하는 줄은 무시합니다.
# 경로는 `~/`, 절대 경로, 상대 경로 모두 됩니다.

# ── 서버 ─────────────────────────────────────────────
ALLEY_SERVER_URL=https://store.example.com
# 웹 콘솔의 관리 > 서명 워커에서 발급합니다. 발급 직후 한 번만 보입니다.
ALLEY_WORKER_TOKEN=
# 관리 화면에 보일 이름. 비우면 이 맥의 컴퓨터 이름을 씁니다.
ALLEY_WORKER_NAME=

# ── 설치할 번들 ──────────────────────────────────────
# 키트 안의 .app 경로. --bundle 로 줘도 됩니다.
ALLEY_BUNDLE_PATH=alley-worker.app

# ── 서명 ─────────────────────────────────────────────
# Developer ID 인증서와 개인키. 이 맥에 이미 있으면 비워두세요.
ALLEY_P12_PATH=
ALLEY_P12_PASSWORD=
# 이 맥의 로그인 키체인 암호. 위의 인증서 암호와 **다른 값**입니다.
# codesign 이 키를 쓸 때 승인 창을 띄우지 않게 하는 데 씁니다. 비워두면 인증서
# 암호로 시도하고, 둘이 다르면 첫 서명에서 승인 창이 떠 워커가 거기서 멈춥니다.
ALLEY_KEYCHAIN_PASSWORD=
# 비우면 키체인에서 Developer ID Application 을 찾아 씁니다.
# 여러 개면 물어봅니다.
ALLEY_SIGNING_IDENTITY=

# ── 공증 ─────────────────────────────────────────────
# App Store Connect API 키. 이 맥에 프로필이 이미 있으면 비워두세요.
ALLEY_ASC_KEY_PATH=
ALLEY_ASC_KEY_ID=
ALLEY_ASC_ISSUER_ID=
# 공증 자격증명을 저장할 이름.
ALLEY_NOTARY_PROFILE=alley

# ── Sparkle (쓰는 조직만) ────────────────────────────
# Ed25519 시드(base64). `openssl rand -base64 32`
ALLEY_SPARKLE_PRIVATE_KEY=
CONFIG_EOF
}

# 설정 파일을 읽어 환경변수로 만든다.
#
# `source` 하지 않는다. 설정 파일은 값을 적는 곳이지 코드를 적는 곳이 아니다.
# 실수로 백틱이나 `$(...)` 가 들어가면 그대로 실행된다.
load_config() {
    local path="$1" line key value mode
    [ -f "$path" ] || die "설정 파일을 찾지 못했습니다: $path"

    # 토큰과 암호가 들어 있는 파일이다. 남이 읽을 수 있으면 알린다.
    mode="$(stat -f '%Lp' "$path" 2>/dev/null || echo '')"
    case "$mode" in
        *[1-7][1-7]|*[1-7]0|*0[1-7])
            warn "설정 파일을 다른 사용자가 읽을 수 있습니다 (권한 $mode). chmod 600 $path"
            ;;
    esac

    local number=0
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        # 주석과 빈 줄.
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) die "$path:$number 형식이 KEY=value 가 아닙니다: $line" ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"
        # 앞뒤 공백과 감싼 따옴표를 떼어낸다.
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac

        printf '%s\n' "$CONFIG_KEYS" | grep -qx "$key" \
            || die "$path:$number 모르는 설정 항목입니다: $key
쓸 수 있는 항목은 --init-config 로 만든 파일의 주석에 적혀 있습니다."

        [ -n "$value" ] || continue
        printf -v "$key" '%s' "$value"
    done < "$path"

    info "설정을 읽었습니다: $path"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall)
            uninstall
            exit 0
            ;;
        --config)
            CONFIG_PATH="${2:-}"
            [ -n "$CONFIG_PATH" ] || die "--config 뒤에 설정 파일 경로가 필요합니다."
            shift 2
            ;;
        --init-config)
            init_config "${2:-}"
            exit 0
            ;;
        --bundle)
            SOURCE_BUNDLE="${2:-}"
            [ -n "$SOURCE_BUNDLE" ] || die "--bundle 뒤에 번들이나 zip 경로가 필요합니다."
            [ -e "$SOURCE_BUNDLE" ] || die "찾지 못했습니다: $SOURCE_BUNDLE"
            shift 2
            ;;
        --p12)
            P12_PATH="${2:-}"
            [ -f "$P12_PATH" ] || die "인증서 파일을 찾지 못했습니다: ${2:-}"
            shift 2
            ;;
        --asc-key)
            ASC_KEY_PATH="${2:-}"
            [ -f "$ASC_KEY_PATH" ] || die "공증 키 파일을 찾지 못했습니다: ${2:-}"
            shift 2
            ;;
        --asc-key-id)
            ASC_KEY_ID="${2:-}"
            shift 2
            ;;
        --asc-issuer)
            ASC_ISSUER_ID="${2:-}"
            shift 2
            ;;
        --notary-profile)
            ALLEY_NOTARY_PROFILE="${2:-}"
            shift 2
            ;;
        --help|-h)
            # 맨 위 주석 블록 전체. 줄 수를 박아두면 설명을 늘릴 때마다 잘린다.
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "알 수 없는 인자: $1"
            ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "서명 워커는 macOS 에서만 돕니다."

# 설정 파일은 인자 다음에 읽는다. 명령줄로 준 것이 이긴다.
#
# 순서는 **명령줄 > 설정 파일 > 환경변수 > 물어보기** 다. 설정 파일이 환경변수를
# 덮는 것이 중요하다. 셸에 남아 있던 `ALLEY_SERVER_URL` 때문에 설정 파일이 조용히
# 무시되면, 파일을 고쳐도 아무 일이 안 일어나는 상태가 된다.
if [ -n "$CONFIG_PATH" ]; then
    # `~/` 는 셸이 아니라 우리가 푼다. 따옴표로 감싸 넘기면 셸이 풀지 않는다.
    case "$CONFIG_PATH" in '~/'*) CONFIG_PATH="$HOME/${CONFIG_PATH#\~/}" ;; esac

    # 없는 파일은 오류로 다룬다. 여기서 만들어주면 오타 난 경로를 잡을 수 없다.
    [ -e "$CONFIG_PATH" ] || die "설정 파일이 없습니다: $CONFIG_PATH
경로를 확인하세요. 새로 만들려면:
    $0 --init-config $CONFIG_PATH"

    load_config "$CONFIG_PATH"

    [ -n "$P12_PATH" ] || P12_PATH="${ALLEY_P12_PATH:-}"
    [ -n "$ASC_KEY_PATH" ] || ASC_KEY_PATH="${ALLEY_ASC_KEY_PATH:-}"
    [ -n "$ASC_KEY_ID" ] || ASC_KEY_ID="${ALLEY_ASC_KEY_ID:-}"
    [ -n "$ASC_ISSUER_ID" ] || ASC_ISSUER_ID="${ALLEY_ASC_ISSUER_ID:-}"
    [ -n "$SOURCE_BUNDLE" ] || SOURCE_BUNDLE="${ALLEY_BUNDLE_PATH:-}"

    # 경로 값을 다듬는다.
    #
    # `~/` 는 셸이 풀어주는 것이라 설정 파일 안에서는 글자 그대로 남는다. 사람은
    # 당연히 홈 디렉터리로 읽으므로 여기서 풀어준다. 안 풀면 "파일을 찾지 못했습니다"
    # 만 나오고 왜 그런지는 안 보인다.
    #
    # 그다음 상대 경로는 현재 위치에서 먼저 찾고, 없으면 설정 파일이 있는 곳에서
    # 찾는다. 키트를 풀고 그 안에서 돌리면서 설정 파일은 밖에 두는 것이 기본
    # 사용법이라 둘 다 필요하다.
    CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
    for variable in P12_PATH ASC_KEY_PATH SOURCE_BUNDLE; do
        value="${!variable}"
        case "$value" in
            '') continue ;;
            '~/'*) printf -v "$variable" '%s' "$HOME/${value#\~/}"; continue ;;
            /*) continue ;;
        esac
        [ -e "$value" ] || [ ! -e "$CONFIG_DIR/$value" ] || printf -v "$variable" '%s' "$CONFIG_DIR/$value"
    done

    [ -z "$P12_PATH" ] || [ -f "$P12_PATH" ] || die "인증서 파일을 찾지 못했습니다: $P12_PATH"
    [ -z "$ASC_KEY_PATH" ] || [ -f "$ASC_KEY_PATH" ] || die "공증 키 파일을 찾지 못했습니다: $ASC_KEY_PATH"
    [ -z "$SOURCE_BUNDLE" ] || [ -e "$SOURCE_BUNDLE" ] || die "번들을 찾지 못했습니다: $SOURCE_BUNDLE"
fi

# 공증 프로필 이름은 기본값을 둔다. 조직마다 다를 이유가 없고, 물어봐야 할 것을
# 하나 줄인다. 다르게 쓰고 싶으면 --notary-profile 로 준다.
ALLEY_NOTARY_PROFILE="${ALLEY_NOTARY_PROFILE:-alley}"

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

# Xcode Command Line Tools 가 없으면 서명도 공증도 안 된다. 설치는 대화형이라
# 여기서 대신 해줄 수 없다. 대신 무엇을 하면 되는지 정확히 알려주고 멈춘다.
require_command_line_tools() {
    if xcrun --find codesign >/dev/null 2>&1 && xcrun --find notarytool >/dev/null 2>&1; then
        return
    fi
    die "Xcode Command Line Tools 가 없습니다. 먼저 이것을 실행하고 설치가 끝나면 다시 오세요:

    xcode-select --install"
}

# Developer ID 인증서와 개인키를 로그인 키체인에 넣는다.
#
# `-T /usr/bin/codesign` 은 codesign 이 이 키를 쓸 때 허락을 묻지 않게 한다. 이게
# 없으면 워커가 잡을 받을 때마다 화면에 대화상자가 뜨고, 아무도 없는 빌드 머신에서는
# 그대로 멈춘다.
import_certificate() {
    [ -n "$P12_PATH" ] || return 0

    local password
    if [ -n "${ALLEY_P12_PASSWORD:-}" ]; then
        password="$ALLEY_P12_PASSWORD"
    else
        read -r -s -p "인증서(.p12) 암호: " password
        echo
    fi

    info "인증서를 로그인 키체인에 넣습니다..."
    # 이미 있으면 security 가 실패한다. 그건 오류가 아니라 "할 일이 없다" 는 뜻이다.
    local output
    if output="$(security import "$P12_PATH" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P "$password" -T /usr/bin/codesign -T /usr/bin/security 2>&1)"
    then
        info "인증서를 넣었습니다."
    elif printf '%s' "$output" | grep -q 'already exists'; then
        info "인증서가 이미 키체인에 있습니다."
    else
        die "인증서를 넣지 못했습니다: $output"
    fi

    # codesign 이 키를 쓸 때마다 묻지 않도록 파티션 목록을 연다.
    #
    # **여기 `-k` 는 로그인 키체인 암호다.** 바로 위 `import` 의 `-P` 가 받는 P12
    # 암호와 다른 값이다. 둘을 같게 쓰는 사람도 있어서 오래 들키지 않았는데, 다르면
    # 이 명령은 언제나 실패한다.
    #
    # 실패해도 설치를 멈추지는 않는다. 다만 그 맥은 첫 서명에서 키체인 접근 승인
    # 창을 띄우고, **무인으로 도는 워커에는 그 창에 답할 사람이 없다.** 잡 하나가
    # 타임아웃까지 멈춘 채로 남고, 화면을 보는 사람이 없으면 원인도 안 보인다.
    # 그래서 경고 문구에 그 대가와 손으로 여는 명령을 함께 적는다.
    local keychain_password="${ALLEY_KEYCHAIN_PASSWORD:-$password}"
    if ! security set-key-partition-list -S apple-tool:,apple: -s \
        -k "$keychain_password" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1
    then
        warn "키 접근 허용 설정에 실패했습니다.
  ALLEY_KEYCHAIN_PASSWORD 에는 인증서(.p12) 암호가 아니라 이 맥의 **로그인 키체인
  암호**를 넣습니다. 비워두면 인증서 암호로 시도하고, 둘이 다르면 여기서 실패합니다.

  이대로 두면 첫 서명에서 키체인 접근 승인 창이 뜨고, 무인으로 도는 워커는 그 자리에서
  멈춥니다. 지금 손으로 열려면:

    security set-key-partition-list -S apple-tool:,apple: -s \\
      -k '<로그인 키체인 암호>' ~/Library/Keychains/login.keychain-db"
    fi
}

# 공증 자격증명을 키체인에 프로필 이름으로 저장한다.
#
# `.p8` 을 그대로 받는다. `.env` 처럼 한 줄에 `\n` 을 글자로 담고 있는 값에서
# 만들었다면 PEM 이 깨져 있는데, notarytool 은 그때 `invalidPEMDocument` 만 말하고
# 무엇이 잘못됐는지는 말하지 않는다. 그래서 여기서 먼저 확인하고 고칠 수 있으면
# 고친다. 실제로 이 함정에 한 번 빠졌다.
store_notary_credentials() {
    [ -n "$ASC_KEY_PATH" ] || return 0

    [ -n "$ASC_KEY_ID" ] || ask ASC_KEY_ID "App Store Connect Key ID (10자)"
    [ -n "$ASC_ISSUER_ID" ] || ask ASC_ISSUER_ID "App Store Connect Issuer ID (UUID)"

    local key="$ASC_KEY_PATH"
    if ! openssl pkey -in "$key" -noout >/dev/null 2>&1; then
        # 한 줄짜리에 `\n` 이 글자로 들어 있는 경우다. 진짜 개행으로 바꿔본다.
        local repaired
        repaired="$(mktemp)"
        chmod 600 "$repaired"
        printf '%b\n' "$(command cat "$ASC_KEY_PATH")" > "$repaired"
        if openssl pkey -in "$repaired" -noout >/dev/null 2>&1; then
            warn "공증 키의 줄바꿈이 깨져 있어 고쳤습니다. 원본 파일은 그대로입니다."
            key="$repaired"
            TEMP_KEY="$repaired"
        else
            rm -f "$repaired"
            die "공증 키를 읽지 못했습니다: $ASC_KEY_PATH
App Store Connect 에서 받은 .p8 파일이 맞는지 확인하세요."
        fi
    fi

    # 실패 메시지가 헷갈리게 생겼다. 마지막 줄이 `Success. Credentials validated.`
    # 라서 성공처럼 보이는데, 그건 **Apple 에 물어본 검증**이 됐다는 뜻일 뿐이다.
    # 키체인에 쓰지 못한 오류는 그 위에 따로 찍힌다:
    #
    #   Error: An error occurred while accessing the keychain.
    #   User interaction is not allowed.
    #   ...
    #   Success. Credentials validated.
    #
    # 화면이 잠겨 있거나 SSH 로 붙은 셸에서 이렇게 된다. 종료 코드는 1 이라 아래
    # `|| die` 로 걸리지만, 사람이 출력만 보고 "성공했는데 왜?" 하지 않도록 무엇을
    # 하면 되는지 함께 적는다.
    info "공증 자격증명을 '$ALLEY_NOTARY_PROFILE' 로 저장합니다..."
    xcrun notarytool store-credentials "$ALLEY_NOTARY_PROFILE" \
        --key "$key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
        || die "공증 자격증명을 키체인에 저장하지 못했습니다.

위 출력의 마지막 줄이 'Success. Credentials validated.' 여도 저장은 실패한 것입니다.
그 줄은 Apple 에 물어본 검증이 됐다는 뜻이고, 키체인 오류는 그 위에 따로 찍힙니다.

'User interaction is not allowed' 가 보이면 키체인이 잠겨 있는 것입니다.
이 맥에 화면으로 로그인한 상태에서 터미널을 직접 열어 다시 실행하세요.
원격(SSH)이나 화면 잠금 상태에서는 키체인에 쓸 수 없습니다."
}

# 키체인에 Developer ID Application 이 하나뿐이면 그것을 쓴다. 사람이 긴 이름을
# 옮겨 적다가 틀리는 일이 흔한데, 틀리면 잡을 받은 뒤에야 드러난다.
detect_signing_identity() {
    [ -z "${ALLEY_SIGNING_IDENTITY:-}" ] || return 0

    local found count
    found="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p')"
    count="$(printf '%s' "$found" | grep -c '' || true)"

    if [ "$count" = "1" ] && [ -n "$found" ]; then
        ALLEY_SIGNING_IDENTITY="$found"
        info "서명 identity 를 찾았습니다: $ALLEY_SIGNING_IDENTITY"
    fi
}

info "서명 워커 설치"
echo

require_command_line_tools

# 자격증명을 먼저 갖춰둔다. 그래야 아래 identity 자동 탐지와 환경 점검이 의미가 있다.
#
# 치울 것이 둘(고친 공증 키, 푼 번들)인데 `trap ... EXIT` 는 나중 것이 앞 것을
# 덮어쓴다. 그래서 하나로 합쳐 여기서 한 번만 건다.
TEMP_KEY=""
STAGING_DIR=""
cleanup() {
    [ -n "$TEMP_KEY" ] && rm -f "$TEMP_KEY"
    [ -n "$STAGING_DIR" ] && rm -rf "$STAGING_DIR"
    return 0
}
trap cleanup EXIT

import_certificate
store_notary_credentials

ask ALLEY_SERVER_URL "서버 주소 (예: https://store.example.com)"
ask ALLEY_WORKER_TOKEN "워커 토큰 (웹 콘솔의 관리 > 서명 워커에서 발급)" secret

detect_signing_identity
if [ -z "${ALLEY_SIGNING_IDENTITY:-}" ]; then
    echo
    info "이 맥의 서명 identity:"
    security find-identity -v -p codesigning || true
    echo
fi
ask ALLEY_SIGNING_IDENTITY "서명 identity (예: Developer ID Application: Example Inc. (TEAMID))"

ALLEY_WORKER_NAME="${ALLEY_WORKER_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"

# 설치할 번들을 마련한다. STAGED 는 복사 원본이 될 `.app` 디렉터리다.
# `STAGING_DIR` 과 정리 트랩은 위에서 이미 잡아뒀다.
STAGED=""

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
