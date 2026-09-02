#!/usr/bin/env bash
#
# .app 번들을 서명·공증·스테이플하는 공통 부분.
#
# 스토어 앱과 서명 워커가 같은 절차를 밟는다. 두 스크립트에 그대로 복사해두면
# 한쪽만 고쳐지는 날이 온다. 여기 담긴 것은 Hardened Runtime 과 Apple 타임스탬프처럼
# 빠지면 배포가 통째로 막히거나 인증서 만료와 함께 조용히 죽는 값들이라, 그 위험을
# 감수할 이유가 없다.
#
# 반대로 `Info.plist` 는 각자 만든다. 스토어 앱은 URL 스킴과 Dock 아이콘이 필요하고
# 워커는 UI 자체가 없다. 하나의 템플릿에 조건을 붙이면 양쪽 다 읽기 나빠진다.
#
# 이 파일은 직접 실행하지 않는다. `source` 해서 쓴다.
# 부르는 쪽이 `info` 와 `die` 를 미리 정의해둔다.

# 서명하지 않고 끝낼 번들을 ad-hoc 으로 봉인한다.
#
# 안 하면 번들이 어중간한 상태로 남는다. 애플 실리콘에서는 링커가 실행 파일에 ad-hoc
# 서명을 이미 붙여놓는데, 번들에는 `_CodeSignature` 가 없다. 그 조합에 대고
# `codesign --verify` 를 돌리면 "code has no resources but signature indicates they
# must be present" 로 실패한다. 서명하지 않은 번들도 검증은 통과해야, 설치 쪽에서
# "서명이 깨졌다" 와 "서명하지 않았다" 를 구분할 수 있다.
bundle_seal_adhoc() {
    codesign --force --sign - "$1" >/dev/null 2>&1 \
        || die "번들을 ad-hoc 으로 봉인하지 못했습니다: $1"
}

# 서명 identity 이름을 화면에 찍지 않는다. 조직 이름과 Team ID 가 그 안에 있고,
# CI 로그나 터미널 기록에 남을 자리가 아니다.
bundle_sign() {
    local bundle="$1"
    [ -n "${ALLEY_SIGNING_IDENTITY:-}" ] || die "ALLEY_SIGNING_IDENTITY 가 필요합니다."

    info "서명합니다..."
    # Hardened Runtime 은 Developer ID 배포의 필수 조건이다. 샌드박스는 쓰지 않는다(ADR-0007).
    # --timestamp 는 인증서가 만료돼도 서명이 계속 유효하도록 Apple 타임스탬프를 받는다.
    codesign --force --options runtime --timestamp \
        --sign "$ALLEY_SIGNING_IDENTITY" "$bundle"
    codesign --verify --deep --strict --verbose=2 "$bundle"
}

# 번들을 zip 으로 만든다.
#
# `--keepParent` 가 있어야 `.app` 이 최상위에 그대로 담긴다. 없으면 앱 안의
# `Contents` 만 풀려나온다. `ditto` 를 쓰는 이유는 심볼릭 링크와 확장 속성을
# 그대로 보존하는 것이 이것뿐이기 때문이다. 링크가 실제 파일로 풀리면 서명이 깨진다.
bundle_archive() {
    local bundle="$1" archive="$2"
    rm -f "$archive"
    ditto -c -k --sequesterRsrc --keepParent "$bundle" "$archive"
}

# 공증을 받고 티켓을 번들에 박는다.
#
# 스테이플까지 해야 인터넷이 끊긴 맥에서도 Gatekeeper 가 통과시킨다. 스테이플은
# 번들의 내용을 바꾸므로 zip 을 다시 만든다.
bundle_notarize() {
    local bundle="$1" archive="$2"
    [ -n "${ALLEY_NOTARY_PROFILE:-}" ] || die "ALLEY_NOTARY_PROFILE 이 필요합니다."

    info "공증을 요청합니다. 몇 분 걸립니다..."
    xcrun notarytool submit "$archive" \
        --keychain-profile "$ALLEY_NOTARY_PROFILE" \
        --wait --timeout 45m

    xcrun stapler staple "$bundle"
    bundle_archive "$bundle" "$archive"
}
