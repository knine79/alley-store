#!/usr/bin/env bash
#
# 스토어 앱 베이스 번들을 만들어 스토어에 올리고 빌드를 시킨다 (ADR-0046).
#
# **운영 CI 와 로컬이 같은 길을 쓴다.** 예전에는 이 절차가 운영 레포의 워크플로에
# `curl` 세 줄로 박혀 있었다. 서버 API 를 아는 유일한 자리가 거기라서, 제품이 경로나
# 필드를 바꾸면 운영 레포가 따라와야 했고 그 사실을 아무도 알려주지 않았다.
#
# 여기 두면 스크립트와 API 가 같은 커밋에서 나온다. 운영 레포는 `alley.lock` 으로
# 제품 태그를 고정하므로(ADR-0043) 둘이 어긋날 자리가 없다.
#
# 로컬에서 쓰는 것도 같은 값을 한다. 여기가 로컬에서 안 돌아가면 운영에서만 도는
# 경로가 되고, 그런 경로는 깨져 있어도 릴리스 날까지 아무도 모른다.
#
# 사용법:
#   ./scripts/publish-store-app.sh                  버전을 코드에서 읽는다
#   ./scripts/publish-store-app.sh --version 0.6.4  버전을 직접 준다
#   ./scripts/publish-store-app.sh --force          이미 빌드된 버전이어도 다시 한다
#   ./scripts/publish-store-app.sh --no-build       올리기만 하고 빌드는 안 시킨다
#
# 필요한 값:
#   ALLEY_SERVER_URL       스토어 주소 (예: http://localhost:8080)
#   ALLEY_OPERATOR_TOKEN   운영 토큰. 관리 > 설정에서 발급한다 (`alleyo_` 로 시작)
#
# 토큰이 없으면 번들까지만 만들고 그 경로를 알려준다. 관리 > 스토어 앱에서 손으로
# 올릴 수 있다. 토큰을 발급받아야만 아무것도 못 하는 상태로 두지 않는다.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$REPO_ROOT/.build/store-app/alley-store-app-unsigned.zip"

VERSION=""
FORCE=0
TRIGGER_BUILD=1

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --no-build) TRIGGER_BUILD=0; shift ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "모르는 인자입니다: $1" >&2; exit 2 ;;
    esac
done

# 버전은 코드가 원천이다. 사람이 적으면 코드와 어긋날 수 있고, 어긋나면 "0.6.4 를
# 올렸는데 0.6.3 이 돌고 있다" 가 된다. 조용한 종류의 어긋남이다.
if [ -z "$VERSION" ]; then
    VERSION=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' \
        "$REPO_ROOT/Sources/AlleyShared/AlleyVersion.swift" | head -1)
fi
[ -n "$VERSION" ] || { echo "제품 버전을 읽지 못했습니다." >&2; exit 1; }

SERVER_URL="${ALLEY_SERVER_URL:-}"
TOKEN="${ALLEY_OPERATOR_TOKEN:-}"
# 끝의 `/` 를 떼지 않으면 `//api/v1/...` 이 된다. 서버는 받아주지만 로그가 지저분해진다.
SERVER_URL="${SERVER_URL%/}"

echo "제품 $VERSION"

# ── 이미 올라가 있나 ─────────────────────────────────────
#
# 빌드 번호는 서버가 스스로 올린다. 워커 릴리스와 달리 같은 버전을 거절해주지
# 않으므로, 두 번 돌리면 쓸모없는 버전이 하나 더 생긴다. 먼저 물어본다.
if [ -n "$SERVER_URL" ] && [ -n "$TOKEN" ] && [ "$FORCE" -eq 0 ]; then
    BUILT=$(curl -fsS \
            -H "Authorization: Bearer $TOKEN" \
            "$SERVER_URL/api/v1/ops/store-app" \
        | python3 -c 'import json,sys; print("\n".join(b["shortVersion"] for b in json.load(sys.stdin)["builds"]))' \
        ) || { echo "스토어에 물어보지 못했습니다. 주소와 토큰을 확인하세요." >&2; exit 1; }

    # 따옴표를 붙인다. 셸의 단어 분리에 기대면 분리하지 않는 셸에서 조용히 "없다"
    # 로 떨어지고, 그러면 같은 버전을 두 번 빌드한다.
    if printf '%s\n' "$BUILT" | grep -qx "$VERSION"; then
        echo "이미 빌드돼 있습니다. 다시 하려면 --force 를 주세요."
        exit 0
    fi
fi

# ── 번들 만들기 ──────────────────────────────────────────
#
# 브랜딩 없는 재료라 붙을 주소를 박지 않는다. 조직마다 다르고, 서버가 조립할 때
# 자기 `PUBLIC_BASE_URL` 로 채운다 (ADR-0046). 이 표시가 없으면 빌드 스크립트가
# "주소가 없다" 며 거절한다 (ADR-0044).
echo "베이스 번들을 만듭니다."
ALLEY_STORE_APP_BASE_BUNDLE=1 \
ALLEY_STORE_APP_VERSION="$VERSION" \
    "$REPO_ROOT/scripts/build-store-app.sh"

[ -f "$BUNDLE" ] || { echo "번들이 만들어지지 않았습니다: $BUNDLE" >&2; exit 1; }

# ── 올리기 ───────────────────────────────────────────────
if [ -z "$SERVER_URL" ] || [ -z "$TOKEN" ]; then
    echo
    echo "번들을 만들었습니다:"
    echo "  $BUNDLE"
    echo
    echo "올리려면 ALLEY_SERVER_URL 과 ALLEY_OPERATOR_TOKEN 이 필요합니다."
    echo "토큰은 관리 > 설정에서 발급합니다. 발급할 때 한 번만 보여줍니다."
    echo "또는 관리 > 스토어 앱에서 위 파일을 손으로 올리면 됩니다."
    exit 0
fi

echo "올립니다: $SERVER_URL"
curl -fsS -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -F "version=$VERSION" \
    -F "bundle=@$BUNDLE" \
    "$SERVER_URL/api/v1/ops/store-app/base-bundle" > /dev/null

if [ "$TRIGGER_BUILD" -eq 0 ]; then
    echo "올렸습니다. 빌드는 시키지 않았습니다 (--no-build)."
    exit 0
fi

curl -fsS -X POST \
    -H "Authorization: Bearer $TOKEN" \
    "$SERVER_URL/api/v1/ops/store-app/build" > /dev/null

echo
echo "서명 대기열에 넣었습니다."
echo "서명·공증이 끝나면 관리 > 스토어 앱에서 출시하세요."
