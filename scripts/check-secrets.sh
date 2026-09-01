#!/usr/bin/env bash
#
# 커밋에 자격증명이 섞여 들어갔는지 본다.
#
# 조직 고유값 검사(check-denylist.sh)와 목적이 다르다. 그쪽은 "이 레포에 남의
# 조직 이름이 있는가"를 보고, 이쪽은 "비밀이 새어 들어갔는가"를 본다.
#
# 완벽한 검사가 아니다. 우리가 만드는 토큰의 접두사와 흔한 키 형식만 본다.
# 그래도 대부분의 사고는 "설정 파일을 예제로 만들다 실제 값을 넣고 커밋"이라
# 이 정도로 잡힌다.
#
# 사용법:
#   ./scripts/check-secrets.sh            추적 중인 파일 전부
#   ./scripts/check-secrets.sh --staged   스테이징된 것만 (커밋 훅용)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# macOS 기본 bash 는 3.2 라 mapfile 이 없다. 줄 단위로 읽어 배열에 담는다.
FILES=()
while IFS= read -r line; do
    [ -n "$line" ] && FILES+=("$line")
done < <(
    if [ "${1:-}" = "--staged" ]; then
        git diff --cached --name-only --diff-filter=ACM
    else
        git ls-files
    fi
)

if [ ${#FILES[@]} -eq 0 ]; then
    echo "검사할 파일이 없습니다."
    exit 0
fi

# 검사에서 빼는 것들.
#
# 이 스크립트 자신과 예제 파일은 패턴을 설명하려고 그 문자열을 갖고 있다.
# 문서도 마찬가지다. 여기를 넓게 열면 검사가 무의미해지므로 최소로 둔다.
is_excluded() {
    case "$1" in
        scripts/check-secrets.sh) return 0 ;;
        .env.example) return 0 ;;
        docs/adr/*) return 0 ;;
        *) return 1 ;;
    esac
}

# 패턴과 그것이 무엇인지.
#
# 우리 토큰은 접두사 뒤에 16진수가 이어진다. 접두사만 보면 문서의 설명까지 잡힌다.
PATTERNS=(
    "alleyw_[0-9a-f]{32}|서명 워커 토큰"
    "alleyd_[0-9a-f]{32}|배포 토큰"
    "alleyf_[0-9a-f]{32}|피드 토큰"
    "-----BEGIN [A-Z ]*PRIVATE KEY-----|개인키"
    "AKIA[0-9A-Z]{16}|AWS 액세스 키"
    "xox[baprs]-[0-9A-Za-z-]{10,}|Slack 토큰"
    "hooks\.slack\.com/services/T[0-9A-Z]+/B[0-9A-Z]+/[0-9A-Za-z]{16,}|Slack 웹훅 주소"
    "ghp_[0-9A-Za-z]{36}|GitHub 개인 액세스 토큰"
    "eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.|JWT"
)

FOUND=0
for entry in "${PATTERNS[@]}"; do
    pattern="${entry%%|*}"
    label="${entry##*|}"

    for file in "${FILES[@]}"; do
        [ -f "$file" ] || continue
        is_excluded "$file" && continue

        if matches="$(grep -nEI "$pattern" "$file" 2>/dev/null)"; then
            # 값 자체를 출력하지 않는다. 로그가 자격증명 저장소가 되면 안 된다.
            while IFS= read -r line; do
                echo "✗ 자격증명으로 보입니다 ($label): $file:${line%%:*}"
                FOUND=1
            done <<< "$matches"
        fi
    done
done

if [ "$FOUND" -eq 1 ]; then
    echo
    echo "커밋에서 빼고, 이미 올렸다면 그 값을 폐기하세요."
    echo "웹 콘솔에서 토큰을 다시 발급할 수 있습니다."
    exit 1
fi

echo "✓ 자격증명으로 보이는 값을 찾지 못했습니다."
