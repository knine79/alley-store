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
| `Sources/AlleyProcess` | 외부 명령 실행 (워커와 앱이 `codesign` 등을 부른다) |
| `Sources/AlleyServer` | Vapor 기반 API 서버와 웹 콘솔 |
| `Sources/AlleyWorkerCore` | 서명·공증 파이프라인 |
| `Sources/AlleyStoreCore` | SwiftUI 스토어 앱 (macOS 전용) |
| `Sources/AlleyCLICore` | CI 에서 버전을 올리는 `alley` 명령 |

세 계층이 같은 Swift 타입을 공유하므로 API 스펙이 어긋나면 컴파일 단계에서 잡힙니다.

## 시작하기

### 준비물

Alley 를 굴리려면 컴퓨터가 두 종류 필요합니다. 하는 일이 서로 다릅니다.

| | 무엇을 하나 | 필요한 것 |
| --- | --- | --- |
| **서버** | 웹 콘솔을 띄우고 파일과 기록을 보관합니다. 리눅스여도 됩니다 | Docker 와 Docker Compose |
| **서명 워커 맥** | Apple 이 요구하는 서명과 공증을 합니다. 반드시 macOS 여야 합니다 | Xcode Command Line Tools, Developer ID Application 인증서 |

서명 워커가 따로 있는 이유는 **서명에 쓰는 개인키를 서버에 두지 않기 위해서**입니다.
그 키를 가진 사람은 회사 이름으로 아무 앱이나 배포할 수 있습니다. 서버는 인터넷에
열려 있으니 키를 거기 두지 않습니다 ([ADR-0002](docs/adr/0002-pull-based-signing-worker.md)).

### 서버 실행

```bash
cp .env.example .env
# .env 를 열어 Google 로그인 정보와 비밀값을 채웁니다

# 데이터베이스에 표를 만듭니다. 처음 한 번만 합니다.
docker compose run --rm server migrate --yes

docker compose up -d
```

**가운데 `migrate` 를 건너뛰지 마세요.** 서버는 켜질 때 데이터베이스를 스스로
건드리지 않습니다. 표가 없는 채로 뜨기 때문에, 서버는 켜진 것처럼 보이는데 화면을
열면 오류가 납니다.

`http://localhost:8080` 에서 서버가 뜹니다.

### 서명 워커 설치

두 단계입니다. **번들을 한 번 만들고, 그것을 워커 맥에 가져다 놓습니다.**

워커는 서명·공증을 마친 `.app` 번들로 배포합니다
([ADR-0022](docs/adr/0022-worker-as-signed-app-bundle.md)).

```bash
# 1. 레포와 인증서가 있는 맥에서 번들을 만듭니다
./scripts/build-worker-app.sh --sign

# 2. 나온 zip 과 설치 스크립트를 워커 맥으로 옮겨 설치합니다
./install-worker.sh --bundle alley-worker.zip
```

**워커 맥에는 소스도 Swift 툴체인도 필요 없습니다.** zip 하나와 스크립트 하나면
됩니다. 인증서를 보관하는 맥에 개발 도구를 잔뜩 깔아둘 이유가 없고, 워커를 두 대
이상 붙일 때도 번들 하나를 나눠주면 됩니다. 레포가 있는 맥이라면 `--bundle` 없이
불러 그 자리에서 빌드해도 됩니다.

설치 스크립트가 번들의 서명을 확인하고, 서명·공증에 필요한 것이 갖춰졌는지
점검한 뒤 `launchd` 에 등록합니다. 그래서 따로 점검 명령을 돌릴 필요가 없습니다.

설치 위치는 `~/Library/Application Support/alley-worker/alley-worker.app`,
로그는 `~/Library/Logs/alley-worker.log` 입니다.

**워커 맥은 로그인된 채로 두어야 합니다.** 서명 키가 로그인 키체인에 들어 있고,
로그아웃하면 그 키체인이 잠겨서 서명을 할 수 없기 때문입니다. 그래서 시스템 데몬이
아니라 LaunchAgent 로 설치합니다.

공증 자격증명 저장을 포함한 전체 절차는
[설치 가이드](docs/setup.md#4-서명-워커-설치)에 있습니다.

### CI 에서 올리기

앱 상세 화면에서 배포 토큰을 발급한 뒤:

```bash
export ALLEY_SERVER_URL="https://store.example.com"
export ALLEY_TOKEN="alleyd_..."

swift build -c release --product alley
alley upload build/MyApp.zip --version 1.2.0
```

토큰은 그 앱 하나에만 통합니다. 새어나가도 다른 앱은 열리지 않습니다
([ADR-0015](docs/adr/0015-app-scoped-deploy-tokens.md)). 빌드 번호를 안 주면 서버의
마지막 번호에 1을 더합니다.

이미 서명·공증을 마친 빌드라면 `--signed --release` 로 올린 즉시 출시할 수 있습니다.
미서명으로 올리면 서명 워커가 이어받으므로 그 자리에서 출시할 수 없습니다.

### 스토어 앱 빌드

```bash
./scripts/build-store-app.sh          # 번들만 만든다
./scripts/build-store-app.sh --sign   # 서명·공증까지 한다
```

`.build/store-app/` 아래에 `.app` 이 만들어집니다. 조직 고유값(번들 ID, 앱 이름,
로그인 콜백 스킴)은 환경변수로 넘깁니다. Xcode 프로젝트를 두지 않는 이유는
[ADR-0014](docs/adr/0014-store-app-without-xcode-project.md)에 있습니다.

첫 배포는 웹 콘솔에서 직접 내려받습니다. 그 뒤로는 스토어 앱이 자기 자신도
스토어에서 업데이트합니다.

## 알림

앱에 새 피드백이 오면 Slack 으로 알립니다. 앱 상세 화면의 **알림** 구역에서 채널의
Incoming Webhook 주소를 넣으면 됩니다. 워커가 조용해졌다는 알림처럼 앱과 무관한
것은 관리자가 전역 대상으로 등록합니다.

메일(SMTP)은 넣지 않았습니다. 채널은 타입으로 추상화해두었으므로 필요해지면
`NotificationChannel` 을 따르는 타입 하나를 더하면 됩니다.

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

### 테스트

테스트는 **전용 데이터베이스**(`alley_test`)를 씁니다. 마이그레이션과 제약(유니크,
외래키)은 흉내로 검증되지 않아서 진짜 PostgreSQL 을 상대합니다. 테스트가 끝날 때마다
스키마를 통째로 되돌리므로 개발용 데이터베이스를 쓰면 개발 중이던 데이터가 날아갑니다.

`docker compose up` 을 처음 하는 환경이면 자동으로 만들어집니다. 이미 볼륨이 있다면
한 번만 손으로 만드세요.

```bash
docker compose exec postgres createdb -U alley alley_test
```

다른 데이터베이스를 쓰려면 `TEST_DATABASE_URL` 로 넘깁니다.

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
| [설치 가이드](docs/setup.md) | 조직에 올리는 절차. 처음이면 여기부터 |
| [운영 가이드](docs/operations.md) | 올린 뒤에 하는 일. 업그레이드·백업·문제 해결 |
| [Sparkle 서명키](docs/sparkle.md) | appcast 로 스스로 업데이트하는 앱을 배포할 때만 |
| [설계](docs/design.md) | 무엇을 왜 이렇게 만드는가. 아키텍처와 핵심 설계 |
| [구현 계획](docs/implementation-plan.md) | 무엇을 언제 만드는가. 단계별 진행 현황 |
| [ADR](docs/adr/README.md) | 개별 결정의 배경과 버려진 대안 |
| [용어집](docs/glossary.md) | 코드와 문서에 나오는 서버 쪽 용어 |

## 라이선스

MIT. [LICENSE](LICENSE) 를 보세요.

저작권 표시는 "Alley contributors" 로 둡니다. 특정 조직 이름을 넣지 않는 것은
ADR-0003 의 원칙과 같습니다. 포크해서 쓰는 조직이 자기 이름으로 바꿀 이유가 없어야
합니다.
