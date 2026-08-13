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

COPY . .

RUN swift build \
        --product alley-server \
        -c release \
        --static-swift-stdlib \
        -Xlinker -ljemalloc

# 실행에 필요한 것만 추려 담는다.
WORKDIR /staging
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/alley-server" ./ \
    && cp -R /usr/lib/swift/linux/*.so* ./ 2>/dev/null || true \
    && find -L /build/.build/release -regex '.*\.resources$' -exec cp -Ra {} ./ \; \
    && [ -d /build/Web/Public ] && cp -R /build/Web/Public ./Public || mkdir -p ./Public \
    && [ -d /build/Web/Views ] && cp -R /build/Web/Views ./Views || mkdir -p ./Views

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
