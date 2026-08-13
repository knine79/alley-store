#!/usr/bin/env bash
#
# 조직 고유값이 소스에 섞여 들어갔는지 검사한다.
#
# 이 프로젝트는 오픈소스 공개를 전제로 한다. 특정 조직의 이름, 사내 호스트,
# 실제 계정 주소 같은 값은 코드가 아니라 환경변수와 서버 설정으로만 들어와야 한다.
# 커밋 전과 CI 에서 이 스크립트가 그 원칙을 강제한다.
#
# 검사 대상 밖:
#   - .env (커밋되지 않음)
#   - .env.example, docs/ (설정 방법을 설명하려면 예시 값이 필요하다)
#
# 조직별 금칙어는 코드에 남기면 그 자체가 유출이므로 여기 적지 않는다.
# 대신 환경변수로 넘긴다:
#
#   DENYLIST_TERMS="acme,acmecorp,acme-internal" ./scripts/check-denylist.sh
#
# CI 에서는 저장소 시크릿으로 주입한다.

set -euo pipefail

cd "$(dirname "$0")/.."

# 검사에서 제외할 경로.
#
# docs/ 는 제외하지 않는다. 설계 문서에 조직 고유값이 남는 것도 같은 유출이고,
# 예시 값은 example.com 계열을 쓰면 검사를 통과한다.
EXCLUDES=(
    ":(exclude).env"
    ":(exclude)scripts/check-denylist.sh"
    ":(exclude)Package.resolved"
)

# 추적 중인 파일만 검사한다. 빌드 산출물과 의존성 체크아웃은 대상이 아니다.
# macOS 기본 bash 3.2 에는 mapfile 이 없으므로 while 루프로 읽는다.
FILES=()
while IFS= read -r file; do
    [ -n "$file" ] && FILES+=("$file")
done < <(git ls-files -- . "${EXCLUDES[@]}")

if [ ${#FILES[@]} -eq 0 ]; then
    echo "검사할 파일이 없습니다."
    exit 0
fi

FAILED=0

report() {
    local label="$1"
    local matches="$2"
    if [ -n "$matches" ]; then
        echo ""
        echo "✗ $label"
        echo "$matches" | sed 's/^/    /'
        FAILED=1
    fi
}

# --- 1. 조직 고유 금칙어 (환경변수로 주입) ---
if [ -n "${DENYLIST_TERMS:-}" ]; then
    IFS=',' read -ra TERMS <<< "$DENYLIST_TERMS"
    for term in "${TERMS[@]}"; do
        term="$(echo "$term" | xargs)"
        [ -z "$term" ] && continue
        matches="$(grep -rniF -- "$term" "${FILES[@]}" 2>/dev/null || true)"
        report "금칙어 '$term' 가 발견됐습니다. 환경변수나 서버 설정으로 옮기세요." "$matches"
    done
else
    echo "참고: DENYLIST_TERMS 가 설정되지 않아 조직 금칙어 검사를 건너뜁니다."
fi

# --- 2. 구조적 패턴 (조직과 무관하게 항상 검사) ---

# 실제 사내 호스트로 보이는 도메인.
# 호스트명 형태(레이블 + 사내 TLD)일 때만 잡는다. 글롭 패턴이나 파일 확장자는 대상이 아니다.
# `.local` 은 mDNS 표준 용도가 있어 제외한다.
matches="$(grep -rnoE '\b[a-z0-9][a-z0-9-]*\.(internal|corp|intranet|lan)\b' "${FILES[@]}" 2>/dev/null \
    | grep -viE 'localhost' || true)"
report "사내 호스트로 보이는 도메인이 있습니다." "$matches"

# example 계열이 아닌 실제 이메일 주소.
matches="$(grep -rnoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${FILES[@]}" 2>/dev/null \
    | grep -viE '@(example\.(com|org|net)|localhost|.*\.invalid)' || true)"
report "실제 이메일 주소로 보이는 값이 있습니다. example.com 을 쓰세요." "$matches"

# 사설 IP 대역 하드코딩.
matches="$(grep -rnoE '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' "${FILES[@]}" 2>/dev/null || true)"
report "사설 IP 주소가 하드코딩돼 있습니다." "$matches"

# 커밋되면 안 되는 자격증명 파일.
matches="$(git ls-files -- '*.p12' '*.mobileprovision' '*.provisionprofile' '*.cer' 'AuthKey_*.p8' 2>/dev/null || true)"
report "서명 자격증명 파일이 추적되고 있습니다. 즉시 제거하고 키를 폐기하세요." "$matches"

echo ""
if [ $FAILED -eq 0 ]; then
    echo "✓ 조직 고유값 검사를 통과했습니다."
else
    echo "검사에 실패했습니다. 위 항목을 환경변수나 서버 설정으로 옮기세요."
    exit 1
fi
