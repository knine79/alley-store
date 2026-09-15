#!/usr/bin/env bash
#
# `alley` CLI 를 빌드해 서명·공증한다 (ADR-0043).
#
# CI 러너 안에서만 쓰면 Gatekeeper 를 타지 않아 서명이 필요 없다. 그러나 사람이
# 자기 맥에 두고 쓰는 일이 실제로 생기고, 그때 "확인되지 않은 개발자" 경고를 만난다.
# 서명 절차가 이미 도는 자리에 하나 더 얹는 비용이 작다.
#
# 사용법:
#   ./scripts/build-cli.sh                서명 없이 빌드만 한다
#   ./scripts/build-cli.sh --sign         서명·공증까지 한다
#
# --sign 을 쓸 때 필요한 값:
#   ALLEY_SIGNING_IDENTITY   Developer ID Application identity
#   ALLEY_NOTARY_PROFILE     notarytool 키체인 프로필 (없으면 공증을 건너뛴다)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/.build/cli"
BINARY_NAME="alley"

SIGN=0
[ "${1:-}" = "--sign" ] && SIGN=1

info() { echo "  $*"; }
die() { echo "오류: $*" >&2; exit 1; }

# 번들이 아니라 맨 실행 파일이다.
#
# `.app` 번들은 `_CodeSignature` 디렉터리에 서명을 두지만, 단독 Mach-O 는 서명이
# 파일 안에 들어간다. 그래서 `--deep` 도 리소스 봉인도 의미가 없다. 공증은 zip 에
# 담아 보내고, **스테이플은 할 수 없다** - 티켓을 박을 자리가 없다.
#
# 스테이플이 없어도 되는 이유: 단독 실행 파일은 Gatekeeper 가 첫 실행에서 Apple 에
# 조회해 판정하고, 그 결과를 캐시한다. 사내망이 막혀 있으면 그 조회가 실패할 수
# 있는데, 그때는 `xattr -d com.apple.quarantine` 로 풀 수 있다. 번들과 달리
# 선택지가 있다.

echo "== alley CLI =="

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

info "빌드합니다 (universal)..."
# 두 아키텍처를 함께 담는다. 인텔 맥과 애플 실리콘 맥이 섞여 있는 조직에서
# 어느 것을 받아야 하는지 묻지 않게 하려는 것이다.
#
# 제품 이름은 `alley` 다 (Package.swift). 타깃 이름(`AlleyCLI`)을 주면
# "Could not find target named …_PackageProduct" 로 죽는다.
ARCHFLAGS=(--arch arm64 --arch x86_64)
(cd "$REPO_ROOT" && swift build -c release --product alley "${ARCHFLAGS[@]}")
BUILT="$(cd "$REPO_ROOT" && swift build -c release "${ARCHFLAGS[@]}" --show-bin-path)/alley"
[ -f "$BUILT" ] || die "빌드 결과를 찾지 못했습니다: $BUILT"

BINARY="$OUTPUT_DIR/$BINARY_NAME"
cp "$BUILT" "$BINARY"
chmod +x "$BINARY"
xattr -c "$BINARY" 2>/dev/null || true

# zip 은 `ditto` 가 아니라 `zip` 으로 만든다.
#
# `ditto -c -k` 는 파일 하나를 담아도 AppleDouble(`._alley`)을 함께 넣는다. 받는
# 쪽에서 풀면 정체 모를 파일이 하나 더 생긴다. 번들에는 `ditto` 가 필요하지만
# (심볼릭 링크와 확장 속성을 보존해야 서명이 안 깨진다) 단독 실행 파일에는 그
# 이유가 없다. `-j` 는 경로를 버리고 `-X` 는 추가 속성을 뺀다.
pack() {
    rm -f "$ARCHIVE"
    (cd "$OUTPUT_DIR" && zip -q -j -X "$(basename "$ARCHIVE")" "$BINARY_NAME")
}

ARCHIVE="$OUTPUT_DIR/$BINARY_NAME-macos.zip"

if [ "$SIGN" -eq 0 ]; then
    pack
    echo
    echo "결과: $ARCHIVE"
    echo "서명하지 않았습니다. 다른 맥에서 쓰려면 --sign 으로 다시 만드세요."
    echo "CI 러너 안에서만 쓸 것이면 이대로 충분합니다."
    exit 0
fi

[ -n "${ALLEY_SIGNING_IDENTITY:-}" ] || die "ALLEY_SIGNING_IDENTITY 가 필요합니다."

info "서명합니다..."
# Hardened Runtime 은 Developer ID 배포의 필수 조건이다. 없으면 공증이 거절한다.
# --timestamp 는 인증서가 만료돼도 서명이 계속 유효하도록 Apple 타임스탬프를 받는다.
codesign --force --options runtime --timestamp \
    --sign "$ALLEY_SIGNING_IDENTITY" "$BINARY"
codesign --verify --strict --verbose=2 "$BINARY"

pack

if [ -z "${ALLEY_NOTARY_PROFILE:-}" ]; then
    echo
    echo "결과: $ARCHIVE"
    echo "공증은 건너뜁니다. ALLEY_NOTARY_PROFILE 을 주면 함께 처리합니다."
    exit 0
fi

info "공증을 요청합니다. 몇 분 걸립니다..."
xcrun notarytool submit "$ARCHIVE" \
    --keychain-profile "$ALLEY_NOTARY_PROFILE" \
    --wait --timeout 45m

# 스테이플하지 않는다. 단독 실행 파일에는 티켓을 박을 자리가 없다.
# 위 주석에 왜 괜찮은지 적어뒀다.

echo
echo "결과: $ARCHIVE"
echo "서명·공증을 마쳤습니다."
echo
echo "CI 에서 쓰려면:"
echo "  unzip -o $BINARY_NAME-macos.zip && chmod +x $BINARY_NAME"
echo "  ALLEY_SERVER_URL=… ALLEY_TOKEN=… ./$BINARY_NAME upload build/MyApp.zip --version 1.2.0"
