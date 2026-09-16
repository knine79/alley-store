# ==============================================================================
# 빌드 단계
# ==============================================================================
FROM swift:6.2-noble AS build

# 정적 링크에 필요한 SDK. 런타임 이미지를 가볍게 유지하려고 쓴다.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 의존성 해석 결과를 레이어로 캐싱한다.
# 소스만 바뀌면 이 단계를 건너뛴다.
COPY Package.swift Package.resolved ./
RUN swift package resolve --skip-update \
        $([ -f ./Package.resolved ] && echo "--force-resolved-versions")

# **컴파일에 필요한 것만 먼저 넣는다.**
#
# 예전에는 여기가 `COPY . .` 였다. 그러면 CSS 한 글자만 바꿔도 이 레이어가 깨지고
# 뒤의 `swift build` 가 통째로 다시 돈다. 실측에서 그 빌드가 11분 중 7~8분이었고,
# 화면만 고친 배포도 매번 그 값을 치렀다.
#
# 서버가 화면을 읽는 방식이 그 분리를 가능하게 한다. `Public` 과 `Resources` 는
# SPM 리소스가 아니라 **실행 디렉터리에서 읽는 파일** 이라(Leaf 템플릿, 정적 파일,
# 기본 그림, 스토어 앱 번들) 컴파일에 들어가지 않는다. Package.swift 에 `resources:`
# 선언이 하나도 없는 것이 그 증거다.
#
# `Tests` 를 함께 넣는 것은 SPM 이 매니페스트의 모든 타깃 디렉터리가 있는지 보기
# 때문이다. 없으면 패키지를 읽는 단계에서 거절한다.
COPY Sources/ ./Sources/
COPY Tests/ ./Tests/

RUN swift build \
        --product alley-server \
        -c release \
        --static-swift-stdlib \
        -Xlinker -ljemalloc

# 화면에 쓰이는 것들. 여기가 바뀌어도 위 컴파일은 그대로 재사용된다.
COPY Public/ ./Public/
COPY Resources/ ./Resources/

# 실행에 필요한 것만 추려 담는다.
WORKDIR /staging
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/alley-server" ./ \
    && cp -R /usr/lib/swift/linux/*.so* ./ 2>/dev/null || true \
    && find -L /build/.build/release -regex '.*\.resources$' -exec cp -Ra {} ./ \; \
    && cp -R /build/Public ./Public \
    && mkdir -p ./Resources \
    && cp -R /build/Resources/Views ./Resources/Views \
    && cp -R /build/Resources/DefaultBranding ./Resources/DefaultBranding \
    && cp -R /build/Resources/StoreAppBundle ./Resources/StoreAppBundle

# ==============================================================================
# 실행 단계
# ==============================================================================
FROM ubuntu:noble

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
        libjemalloc2 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# 루트로 돌리지 않는다.
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app alley

WORKDIR /app
COPY --from=build --chown=alley:alley /staging /app

USER alley:alley

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:8080/health || exit 1

ENTRYPOINT ["./alley-server"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
