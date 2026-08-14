# Alley

조직 내부에서 macOS 앱을 배포하는 셀프호스팅 앱 스토어.

Mac App Store를 거치지 않고 Developer ID로 서명·공증한 앱을 조직 구성원에게 배포합니다.
개발자는 빌드만 올리면 되고, 서명과 공증은 스토어가 대신합니다.

> 개발 초기 단계입니다. 아직 동작하는 배포 루프가 없습니다.

## 무엇을 해결하나

조직 내부에서 쓰는 Mac 앱을 나눠주는 방법은 보통 이렇습니다. 누군가 로컬에서 빌드하고, 서명하고,
공증을 기다리고, 결과물을 스토리지나 메신저로 올립니다. 받는 사람은 그게 최신인지,
누가 만들었는지, 안전한지 알기 어렵습니다.

Alley는 이 과정을 하나의 흐름으로 묶습니다.

- 개발자는 미서명 빌드를 올리기만 하면 됩니다. 인증서를 직접 다룰 필요가 없습니다
- 서명과 공증은 인증서를 보관한 전용 머신에서 자동으로 처리합니다
- 사용자는 스토어 앱에서 로그인하고 최신 버전을 받습니다
- 누가 무엇을 언제 받았는지 기록이 남습니다

## 구조

```
┌──────────────┐     ┌──────────────────────────────┐
│  개발자       │     │  서버 (Docker)                 │
│  웹 콘솔에서   │────▶│  API + 웹 콘솔                 │
│  빌드 업로드   │     │  PostgreSQL + S3 호환 스토리지  │
└──────────────┘     └──────┬───────────────▲───────┘
                            │ ① 잡 폴링       │ ③ 결과물 업로드
                            │   (아웃바운드만) │
                     ┌──────▼───────────────┴───────┐
                     │  서명 워커 (macOS)              │
                     │  codesign + notarytool        │
                     │  서명 키는 이 머신에만          │
                     └───────────────────────────────┘
┌──────────────┐
│  사용자       │     스토어 앱: 서버 주소만 입력하면
│  스토어 앱에서 │──▶  브랜딩과 인증 설정을 받아옵니다
│  다운로드     │
└──────────────┘
```

서명 워커는 서버로 **나가는 방향으로만** 통신합니다. 인증서를 보관한 머신에
외부에서 들어오는 포트를 열 필요가 없습니다.

### 구성요소

| 디렉터리 | 설명 |
| --- | --- |
| `Sources/AlleyShared` | 서버·워커·스토어 앱이 공유하는 DTO와 API 경로 |
| `Sources/AlleyServer` | Vapor 기반 API 서버와 웹 콘솔 |
| `Sources/AlleyWorker` | macOS 서명 워커 |
| `StoreApp` | SwiftUI 스토어 앱 (예정) |

세 계층이 같은 Swift 타입을 공유하므로 API 스펙이 어긋나면 컴파일 단계에서 잡힙니다.

## 시작하기

### 요구사항

- Docker와 Docker Compose
- 서명 워커를 돌릴 macOS 머신 (Xcode Command Line Tools, Developer ID Application 인증서)

### 서버 실행

```bash
cp .env.example .env
# .env 를 열어 Google OAuth 클라이언트 정보와 비밀값을 채웁니다
docker compose up
```

`http://localhost:8080` 에서 서버가 뜹니다.

### 서명 워커 설정

인증서를 보관할 macOS 머신에서:

```bash
# 공증 자격증명을 키체인에 저장합니다 (한 번만)
xcrun notarytool store-credentials "alley-notary" \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "앱 암호"

# 키체인의 서명 identity 이름을 확인합니다
security find-identity -v -p codesigning

export ALLEY_SERVER_URL="https://store.example.com"
export ALLEY_WORKER_TOKEN="웹 콘솔에서 발급한 토큰"
export ALLEY_SIGNING_IDENTITY="Developer ID Application: Example Inc. (TEAMID)"
export ALLEY_NOTARY_PROFILE="alley-notary"

swift run alley-worker preflight
```

`preflight` 는 서명과 공증에 필요한 것들이 실제로 준비됐는지 확인합니다.
잡을 받은 뒤 환경 문제로 실패하는 상황을 미리 걸러냅니다.

## 설정

모든 설정은 환경변수로 들어옵니다. 코드에는 어떤 조직의 이름도, 어떤 호스팅 환경의
흔적도 남기지 않습니다. 전체 목록은 [.env.example](.env.example) 을 참고하세요.

스토어 이름, 로고, 색상, 허용 로그인 도메인 같은 값은 서버가 `/api/v1/meta` 로
내려줍니다. 스토어 앱은 서버 주소만 알면 나머지를 받아옵니다.

이 원칙은 CI 에서 강제합니다:

```bash
DENYLIST_TERMS="yourorg,yourorg-internal" ./scripts/check-denylist.sh
```

## 개발

```bash
swift build          # 전체 빌드
swift test           # 테스트
swift run alley-worker version
```

### 로컬 개발 루프

서버는 호스트에서 돌리고 데이터베이스와 스토리지만 컨테이너로 띄우면 빌드가 빠릅니다.

```bash
docker compose up -d postgres minio minio-setup

swift run alley-server migrate --yes   # 처음 한 번, 스키마가 바뀔 때마다
swift run alley-server serve
```

`http://localhost:8080/auth/google` 을 브라우저로 열면 로그인이 시작됩니다.
설정한 도메인 밖의 계정은 서버가 거부합니다.

`docker compose up` 으로 서버까지 컨테이너로 띄우면 compose 가 `DATABASE_URL` 과
`S3_ENDPOINT` 를 컨테이너 이름으로 덮어쓰므로 `.env` 는 그대로 두면 됩니다.

## 문서

| 문서 | 다루는 것 |
| --- | --- |
| [설계](docs/design.md) | 무엇을 왜 이렇게 만드는가. 아키텍처와 핵심 설계 |
| [구현 계획](docs/implementation-plan.md) | 무엇을 언제 만드는가. 단계별 진행 현황 |
| [ADR](docs/adr/README.md) | 개별 결정의 배경과 버려진 대안 |

## 라이선스

미정.
