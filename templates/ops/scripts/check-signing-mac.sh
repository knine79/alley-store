#!/usr/bin/env bash
#
# 이 맥이 서명 맥으로 제대로 섰는지 본다.
#
# **설치를 자동화하지 않는다.** 러너를 얹는 일은 몇 달에 한 번이라 그 빈도면
# 스크립트가 먼저 낡는다. 대신 설치 뒤에 훑어서, 나중에 조용히 터질 것을 지금
# 드러낸다.
#
# 서명 맥을 세우면서 겪는 것들은 대개 "설치는 됐는데 나중에 알았다" 는 모양이다.
# 워커 이름이 다른 맥 것이었고, 라벨이 예시값이었고, 러너에서만 키체인이 잠겼고,
# 준비해둔 키트가 낡아 있었다. 그 목록이 그대로 이 검사다.
#
#   ./scripts/check-signing-mac.sh          이 맥을 본다
#   ./scripts/check-signing-mac.sh --quiet  문제만 찍는다
#
# 종료 코드: 0 문제 없음 / 1 고쳐야 할 것이 있음
#
# 서명·공증은 실제로 해본다. 있다고 대답하는 것과 되는 것은 다르다.

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# ── 이 레포가 기대하는 값 ────────────────────────────────
EXPECTED_LABELS="self-hosted macos alley-signing"   # adopt.yml 의 runs-on
WORKER_LOG="$HOME/Library/Logs/alley-worker.log"
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)"

fail_count=0
warn_count=0

ok()   { [ "$QUIET" = 1 ] || printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail_count=$((fail_count + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; warn_count=$((warn_count + 1)); }
note() { [ "$QUIET" = 1 ] || printf '      %s\n' "$*"; }
head_() { [ "$QUIET" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$*"; }

# 설정 파일에서 값 하나를 읽는다. 따옴표는 벗긴다(adopt.yml 과 같은 규칙).
config_value() {
    local key="$1" file="$2" line value
    line=$(grep -E "^$key=" "$CONFIG_DIR/$file" 2>/dev/null | head -1) || return 1
    [ -n "$line" ] || return 1
    value="${line#*=}"
    case "$value" in
        '"'*'"') value="${value#\"}"; value="${value%\"}" ;;
        "'"*"'") value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

SIGNING_IDENTITY="$(config_value ALLEY_SIGNING_IDENTITY signing.env || echo '')"
NOTARY_PROFILE="$(config_value ALLEY_NOTARY_PROFILE signing.env || echo 'alley')"
WORKER_BUNDLE_ID="$(config_value ALLEY_WORKER_BUNDLE_ID store.env || echo '')"

printf '\033[1m서명 맥 점검\033[0m  %s\n' "$(scutil --get ComputerName 2>/dev/null || hostname)"

# ── 1. 로그인 세션 ───────────────────────────────────────
#
# 러너와 워커는 LaunchAgent 로 돈다. GUI 로그인 세션이 없으면 뜨지도 않고,
# 떠도 로그인 키체인을 못 연다.
head_ "로그인 세션"

console_user="$(stat -f%Su /dev/console 2>/dev/null || echo '')"
case "$console_user" in
    ''|root|_*|loginwindow)
        bad "GUI 로그인이 없습니다 (콘솔 사용자: ${console_user:-알 수 없음})"
        note "자동 로그인이 꺼졌거나 재부팅 뒤 아무도 로그인하지 않았습니다."
        note "이 상태로는 서명이 'User interaction is not allowed' 로 죽습니다." ;;
    *) ok "GUI 로그인: $console_user" ;;
esac

auto_login="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo '')"
if [ -n "$auto_login" ]; then
    ok "자동 로그인: $auto_login"
else
    warn "자동 로그인이 꺼져 있습니다"
    note "재부팅하면 사람이 가서 로그인해야 러너와 워커가 뜹니다."
fi

if fdesetup status 2>/dev/null | grep -q 'FileVault is On'; then
    warn "FileVault 가 켜져 있습니다"
    note "자동 로그인을 켤 수 없습니다. 재부팅마다 사람이 필요합니다."
fi

# ── 2. 툴체인 ────────────────────────────────────────────
head_ "툴체인"

for tool in codesign xcrun swift; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool"
    else
        bad "$tool 이 없습니다"
    fi
done

if xcrun --find notarytool >/dev/null 2>&1; then
    ok "notarytool"
else
    bad "notarytool 이 없습니다 (Xcode 또는 Command Line Tools 필요)"
fi

# ── 3. 서명 ──────────────────────────────────────────────
#
# **있다고 대답하는 것과 되는 것은 다르다.** 실제로 서명해본다. 키체인 접근이
# 프롬프트를 띄우면 러너에서는 답할 사람이 없어 잡이 타임아웃까지 멈춘다.
head_ "서명"

if [ -z "$SIGNING_IDENTITY" ]; then
    bad "config/signing.env 에서 ALLEY_SIGNING_IDENTITY 를 읽지 못했습니다"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
    ok "키체인에 있습니다: $SIGNING_IDENTITY"

    probe="$(mktemp -d)/probe"
    printf 'int main(void){return 0;}\n' > "$probe.c"
    if clang -o "$probe" "$probe.c" 2>/dev/null; then
        # 프롬프트가 뜨면 여기서 멈춘다. 무인 실행과 같은 조건을 만들려고
        # stdin 을 막고 시간을 제한한다.
        if timeout_out=$( (codesign --force --timestamp --options runtime \
                --sign "$SIGNING_IDENTITY" "$probe" < /dev/null) 2>&1 ); then
            ok "프롬프트 없이 서명됩니다"
        else
            bad "서명에 실패했습니다"
            note "${timeout_out%%$'\n'*}"
            note "'키체인 접근 허용' 창이 떴다면 partition list 가 안 걸린 것입니다:"
            note "  security set-key-partition-list -S apple-tool:,apple: -s \\"
            note "    -k '<로그인 키체인 암호>' ~/Library/Keychains/login.keychain-db"
        fi
    else
        warn "시험용 바이너리를 만들지 못해 서명을 확인하지 못했습니다"
    fi
    rm -rf "$(dirname "$probe")"
else
    bad "키체인에서 찾지 못했습니다: $SIGNING_IDENTITY"
    note "없거나, 키체인이 잠겼거나, config/signing.env 의 이름이 틀렸습니다."
fi

# ── 4. 공증 ──────────────────────────────────────────────
head_ "공증"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
        --output-format json >/dev/null 2>&1; then
    ok "공증 프로필 '$NOTARY_PROFILE' 이 동작합니다"
else
    bad "공증 프로필 '$NOTARY_PROFILE' 을 쓸 수 없습니다"
    note "키체인이 잠겼거나 프로필이 없습니다. 프로필은 data-protection 키체인에"
    note "있어서 security 로도 Keychain Access 로도 보이지 않습니다. 써봐야 압니다."
fi

# ── 5. 러너 ──────────────────────────────────────────────
#
# **러너는 맥이 아니라 레포에 등록된다.** 맥에서만 보면 이 맥이 어느 레포에
# 열려 있는지 알 수 없다. 공개 레포 러너가 함께 있으면 서명 키가 fork PR 의
# 사정거리 안에 있는 것이다.
head_ "러너"

runners="$(launchctl list 2>/dev/null | awk '/actions\.runner\./ {print $3}')"
if [ -z "$runners" ]; then
    warn "이 맥에 러너가 없습니다"
else
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        repo="${label#actions.runner.}"
        repo="${repo%.*}"
        printf '  · %s\n' "$repo"
    done <<< "$runners"

    if command -v gh >/dev/null 2>&1; then
        while IFS= read -r label; do
            [ -n "$label" ] || continue
            repo="${label#actions.runner.}"
            repo="${repo%.*}"
            slug="${repo/-//}"
            vis="$(gh api "/repos/$slug" -q .visibility 2>/dev/null || echo '')"
            case "$vis" in
                public)
                    bad "$slug 은 공개 레포입니다"
                    note "fork PR 이 이 맥에서 돕니다. 그 잡에서 codesign 을 부르는 것을"
                    note "막는 것은 없습니다. 서명 키를 다른 맥으로 옮기세요." ;;
                private|internal) ok "$slug ($vis)" ;;
                *) note "$slug 의 가시성을 확인하지 못했습니다" ;;
            esac
        done <<< "$runners"
    else
        note "gh 가 없어 레포 가시성을 확인하지 못했습니다."
        note "공개 레포 러너가 함께 있으면 서명 키가 fork PR 에 노출됩니다."
    fi
fi

# ── 6. 워커 ──────────────────────────────────────────────
head_ "워커"

worker_plist="$(/bin/ls "$HOME/Library/LaunchAgents"/*alley*worker*.plist 2>/dev/null | head -1)"
if [ -z "$worker_plist" ]; then
    warn "워커가 설치돼 있지 않습니다"
else
    label="$(basename "$worker_plist" .plist)"
    ok "라벨: $label"

    # 라벨이 예시값이면 알린다. 기능에는 영향이 없지만 launchctl 을 칠 때
    # 헷갈리고, 다음 재설치 때 고칠 기회를 놓치기 쉽다.
    if [ -n "$WORKER_BUNDLE_ID" ] && [ "$label" != "$WORKER_BUNDLE_ID" ]; then
        warn "라벨이 번들 ID 관례와 다릅니다 (기대: $WORKER_BUNDLE_ID)"
        note "설치할 때 ALLEY_WORKER_LABEL 을 안 줘서 기본값이 굳은 경우입니다."
        note "바꾸려면 재설치해야 합니다. 워커를 다시 깔 일이 생기면 그때 맞추세요."
    fi

    perms="$(stat -f '%Lp' "$worker_plist" 2>/dev/null || echo '')"
    if [ "$perms" = "600" ]; then
        ok "plist 권한 600"
    else
        bad "plist 권한이 $perms 입니다 (600 이어야 합니다)"
        note "워커 토큰과 Sparkle 개인키가 그 파일에 평문으로 들어 있습니다."
        note "  chmod 600 $worker_plist"
    fi

    plist_value() {
        /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$1" "$worker_plist" 2>/dev/null
    }

    worker_name="$(plist_value ALLEY_WORKER_NAME)"
    host_short="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
    if [ -z "$worker_name" ]; then
        note "ALLEY_WORKER_NAME 이 비어 있습니다. 호스트 이름을 씁니다."
    elif [ "$worker_name" = "$host_short" ]; then
        ok "워커 이름: $worker_name"
    else
        warn "워커 이름이 '$worker_name' 인데 이 맥은 '$host_short' 입니다"
        note "설정 파일을 다른 맥 것에서 복사하면서 이름만 안 고친 경우입니다."
        note "관리 화면에 남의 맥 이름으로 뜹니다."
    fi

    poll="$(plist_value ALLEY_POLL_TIMEOUT)"
    if [ -z "$poll" ]; then
        warn "ALLEY_POLL_TIMEOUT 이 없습니다 (기본 30초)"
        note "앞단 게이트웨이가 그보다 짧게 끊으면 큐가 빌 때마다 504 가 쌓입니다."
        note "기능은 멀쩡하지만 로그가 묻힙니다."
    else
        ok "ALLEY_POLL_TIMEOUT: $poll"
    fi

    if launchctl list 2>/dev/null | grep -qF "$label"; then
        ok "돌고 있습니다"
    else
        bad "등록돼 있는데 돌지 않습니다"
        note "  launchctl bootstrap gui/\$(id -u) $worker_plist"
    fi

    if [ -f "$WORKER_LOG" ]; then
        recent_504="$(tail -50 "$WORKER_LOG" 2>/dev/null | grep -c '504' || true)"
        if [ "${recent_504:-0}" -gt 10 ]; then
            warn "최근 로그 50줄에 504 가 $recent_504 번 있습니다"
            note "long-poll 이 게이트웨이보다 깁니다. ALLEY_POLL_TIMEOUT 을 줄이세요."
        fi
    fi
fi

# ── 7. 서버 롤아웃 ───────────────────────────────────────
head_ "서버 롤아웃"

if command -v docker >/dev/null 2>&1; then
    ok "docker"
    if docker buildx version >/dev/null 2>&1; then
        ok "buildx"
        note "이미지를 빌드하지 않으므로 Colima 는 필요 없습니다."
    else
        bad "buildx 플러그인이 없습니다"
        note "  brew install docker-buildx"
        note "  ln -sfn \"\$(brew --prefix)/opt/docker-buildx/bin/docker-buildx\" \\"
        note "    ~/.docker/cli-plugins/docker-buildx"
    fi
else
    warn "docker 가 없습니다"
    note "adopt.yml 의 서버 롤아웃이 실패합니다. 이미지를 손으로 옮겨야 합니다."
    note "  brew install docker docker-buildx"
fi

# ── 8. 디스크 ────────────────────────────────────────────
head_ "디스크"

avail_gb="$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$avail_gb" ]; then
    if [ "$avail_gb" -lt 20 ]; then
        bad "남은 공간 ${avail_gb}Gi"
        note "러너 _work 는 잡 사이에 안 지워집니다. Swift 빌드가 공간을 씁니다."
    elif [ "$avail_gb" -lt 50 ]; then
        warn "남은 공간 ${avail_gb}Gi"
    else
        ok "남은 공간 ${avail_gb}Gi"
    fi
fi

# ── 마무리 ───────────────────────────────────────────────
printf '\n'
if [ "$fail_count" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
    printf '\033[32m문제 없습니다.\033[0m\n'
    exit 0
fi
printf '고쳐야 할 것 \033[31m%d\033[0m개, 볼 것 \033[33m%d\033[0m개\n' "$fail_count" "$warn_count"
[ "$fail_count" -gt 0 ] && exit 1
exit 0
