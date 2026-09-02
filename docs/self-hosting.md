# 셀프호스팅 가이드

Alley 를 조직에 올리는 절차입니다. 처음부터 끝까지 따라가면 개발자가 빌드를 올리고
구성원이 스토어 앱으로 받는 상태가 됩니다.

무엇을 왜 이렇게 만들었는지는 [설계 문서](design.md)와 [ADR](adr/README.md)에
있습니다. 여기서는 **어떻게 올리는가**만 다룹니다.

## 준비물

| 항목 | 왜 필요한가 | 없으면 |
| --- | --- | --- |
| 서버 한 대 (Docker) | 서버·데이터베이스·스토리지가 여기 뜹니다 | 시작할 수 없습니다 |
| 도메인과 TLS 인증서 | 로그인 콜백과 스토어 앱이 붙을 주소 | 로컬에서만 씁니다 |
| Google Workspace 계정 | 로그인에 씁니다 (ADR-0008) | 로그인할 수 없습니다 |
| macOS 머신 한 대 | 서명 워커가 여기서 돕니다 (ADR-0002) | 미서명 업로드가 서명되지 않습니다 |
| Apple Developer Program | Developer ID Application 인증서 | 서명·공증을 할 수 없습니다 |

서명 워커를 돌릴 맥은 **전용 머신일 필요는 없지만 늘 켜져 있어야** 합니다. 잡을
기다리는 것이 그 프로세스의 일이라, 꺼져 있으면 큐가 쌓입니다.

## 1. Google OAuth 클라이언트 발급

Google Cloud Console 에서:

1. 프로젝트를 만듭니다
2. **API 및 서비스 > OAuth 동의 화면** 에서 **Internal** 을 고릅니다.
   조직 밖 계정이 애초에 동의 화면을 볼 수 없게 됩니다
3. **사용자 인증 정보 > OAuth 클라이언트 ID > 웹 애플리케이션**
4. 승인된 리디렉션 URI 에 다음을 넣습니다:
   - `https://store.example.com/auth/google/callback` (운영)
   - `http://localhost:8080/auth/google/callback` (로컬 개발)

동의 화면을 Internal 로 두어도 **서버가 이메일 도메인을 한 번 더 검사합니다.**
Google 설정 하나에 로그인 문을 전부 맡기지 않습니다.

## 2. 서버 띄우기

서버 이미지는 CI 가 커밋마다 `ghcr.io/<소유자>/<레포>` 에 올립니다
([ADR-0021](adr/0021-publish-server-container-image.md)). **운영 서버에는 제품 소스를
두지 않습니다.** 필요한 것은 파일 두 개입니다.

```bash
mkdir alley && cd alley

# 레포에서 이 둘만 가져옵니다
curl -fsSL -O https://raw.githubusercontent.com/<소유자>/<레포>/main/docker-compose.yml
curl -fsSL -o .env https://raw.githubusercontent.com/<소유자>/<레포>/main/.env.example
```

레포를 클론해서 개발할 때는 `cp .env.example .env` 만 하면 됩니다. 클론에는
`docker-compose.override.yml` 이 함께 있어서 이미지를 받는 대신 소스에서 짓습니다.
아래 절차는 나머지가 같습니다.

`.env` 에서 반드시 채워야 하는 것:

| 변수 | 값 |
| --- | --- |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | 1번에서 발급한 것 |
| `OAUTH_REDIRECT_URI` | 승인된 리디렉션 URI 와 **글자 하나까지** 같아야 합니다 |
| `JWT_SECRET` | `openssl rand -base64 48` |
| `PUBLIC_BASE_URL` | 밖에서 보이는 주소 |
| `S3_SECRET_ACCESS_KEY` | `openssl rand -base64 32` |
| `INITIAL_ADMIN_EMAILS` | 첫 관리자. 이 계정으로 로그인해야 설정을 바꿀 수 있습니다 |
| `ALLOWED_EMAIL_DOMAINS` | 로그인을 허용할 도메인 |
| `ALLEY_IMAGE`, `ALLEY_IMAGE_TAG` | 받아올 서버 이미지 (아래) |

### 어떤 태그를 고르나

`ALLEY_IMAGE=ghcr.io/<소유자>/<레포>` 로 두고 태그만 고릅니다.

| 태그 | 무엇 | 언제 |
| --- | --- | --- |
| `1.2.3` | `v1.2.3` 태그에서 나온 빌드 | **운영은 이것으로.** 움직이지 않습니다 |
| `sha-<40자리>` | 그 커밋의 빌드 | 아직 버전 태그를 붙이지 않은 것을 올려야 할 때 |
| `1.2` | 1.2.x 중 마지막 | 패치는 따라가도 된다고 판단했을 때. 움직입니다 |
| `main`, `latest` | 마지막에 나온 것 | **운영에 쓰지 마세요** |

`latest` 로 배포하면 다시 받을 때마다 다른 것이 뜹니다. 무엇이 돌고 있는지 아무도 말할
수 없고, 문제가 났을 때 어디로 되돌릴지도 알 수 없습니다.

패키지를 비공개로 두었다면 받기 전에 로그인이 필요합니다. `read:packages` 권한이 있는
토큰이면 됩니다.

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <사용자> --password-stdin
```

### 띄우기

```bash
# 데이터베이스 스키마를 만듭니다. 처음 한 번.
docker compose run --rm server migrate --yes

docker compose up -d
```

**서버는 부팅할 때 스키마를 건드리지 않습니다.** 마이그레이션은 `migrate` 명령으로만
돕니다. 이 단계를 건너뛰면 서버는 뜨지만 아무 표도 없어서 첫 요청부터 깨집니다.
버전을 올릴 때도 같은 명령을 씁니다 ([6. 서버 업그레이드](#6-서버-업그레이드)).

`http://localhost:8080` (또는 설정한 주소)에서 로그인 화면이 뜹니다.

### 스토리지가 허용할 출처

버전 업로드는 서버를 거치지 않고 브라우저에서 스토리지로 바로 갑니다
([ADR-0009](adr/0009-presigned-artifact-transfer.md)). 그래서 스토리지가 웹 콘솔의
출처를 허용해야 합니다.

docker-compose 의 MinIO 는 `PUBLIC_BASE_URL` 을 그대로 허용 출처로 씁니다. 웹 콘솔이
서버와 같은 주소에 있으면 따로 할 일이 없습니다. 다른 출처를 더 허용해야 하면 `.env`
에 쉼표로 구분해 적습니다.

```bash
MINIO_CORS_ALLOW_ORIGIN=https://store.example.com,https://console.example.com
```

`scheme://host:port` 형태여야 합니다. 경로나 끝의 슬래시가 붙으면 브라우저가 보내는
`Origin` 헤더와 달라져서 막힙니다. AWS S3 를 쓰면 이 값은 아무 일도 하지 않습니다.
버킷의 CORS 설정에 같은 출처를 넣으세요.

**이것은 접근 통제가 아닙니다.** CORS 는 브라우저가 지키는 규칙이라, 허용하지 않은
출처의 요청도 `curl` 로는 그대로 올라갑니다. 업로드를 실제로 막는 것은 presigned URL
이고 그 주소는 로그인한 사람에게만 발급됩니다. 출처를 좁히는 것은 그 주소가 어떤
경로로든 다른 사이트에 흘러갔을 때 그 사이트의 스크립트가 브라우저에서 바로 쓰는
것을 막는 정도입니다.

### 설정은 어디서 바꾸나

`.env` 의 값 중 **스토어 이름·로고·강조색·허용 도메인·번들 ID 프리픽스**는 최초
1회만 씨앗으로 쓰입니다. 그 뒤로는 관리자 화면에서 바꾸고, `.env` 를 고쳐도 아무 일도
일어나지 않습니다 ([ADR-0011](adr/0011-store-settings-in-database.md)).

비밀값과 부팅에 필요한 값(데이터베이스 주소 등)은 계속 `.env` 에 있습니다.

### 버려진 업로드는 알아서 지워집니다

버전을 만들었다가 업로드를 마치지 않으면 그 버전은 `draft` 로 남고, 스토리지에 올라간
파일이 있으면 그것도 함께 남습니다. 서버가 한 시간에 한 번 훑어서 `DRAFT_RETENTION_HOURS`
(기본 72시간)를 넘긴 것을 지웁니다. 오브젝트도 같이 지웁니다
([ADR-0019](adr/0019-abandoned-draft-cleanup.md)).

이 값을 `S3_PRESIGNED_URL_TTL` 보다 짧게 두지 마세요. 아직 올리고 있는 파일의 자리를
지우게 됩니다.

## 3. 서명 워커 설치

워커는 서명·공증된 `.app` 번들로 배포합니다
([ADR-0022](adr/0022-worker-as-signed-app-bundle.md)). 번들을 한 번 만들어 워커 맥에
가져다 놓는 두 단계입니다.

### 번들 만들기

레포와 Swift 툴체인, Developer ID 인증서가 있는 맥에서 합니다.

```bash
# 공증 자격증명을 키체인에 저장합니다 (한 번만)
xcrun notarytool store-credentials "alley-notary" \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "앱 암호"

export ALLEY_WORKER_BUNDLE_ID="com.example.alley.worker"
export ALLEY_SIGNING_IDENTITY="Developer ID Application: Example Inc. (TEAMID)"
export ALLEY_NOTARY_PROFILE="alley-notary"

./scripts/build-worker-app.sh --sign
```

`.build/worker-app/alley-worker.zip` 이 나옵니다. 서명·공증·스테이플까지 끝난
번들입니다. 공증은 Apple 서버가 처리하는 동안 몇 분에서 몇십 분 걸립니다.

`--sign` 을 빼면 서명하지 않은 번들만 나옵니다. 그 번들은 만든 맥에서만 쓸 수
있습니다.

### 워커 맥에 설치하기

**워커 맥에는 소스도 Swift 툴체인도 필요 없습니다.** 필요한 것은 위에서 만든 zip 과
설치 스크립트 하나뿐입니다. 인증서를 보관하는 맥에 컴파일러와 패키지 매니저를 깔아둘
이유가 없고, 워커를 두 대 이상 붙일 때도 번들 하나를 나눠주면 됩니다.

```bash
curl -fsSL -O https://raw.githubusercontent.com/<소유자>/<레포>/main/scripts/install-worker.sh
chmod +x install-worker.sh

# 웹 콘솔의 관리 > 서명 워커에서 토큰을 발급받은 뒤
./install-worker.sh --bundle ~/Downloads/alley-worker.zip
```

스크립트가 번들의 서명을 확인하고, 환경을 점검한 뒤 `launchd` 에 등록합니다. 설치
위치는 `~/Library/Application Support/alley-worker/alley-worker.app` 이고, 로그는
`~/Library/Logs/alley-worker.log` 에 쌓입니다.

레포가 있는 맥에 그대로 설치할 때는 `--bundle` 없이 `./scripts/install-worker.sh` 로
부릅니다. 그 자리에서 빌드해 설치합니다.

**시스템 데몬이 아니라 LaunchAgent 입니다.** 서명에 쓰는 개인키가 로그인 키체인에
있고, 그 키체인은 로그아웃 상태에서 잠겨 있기 때문입니다. 그 맥은 로그인된 채로
두어야 합니다.

**워커 릴리스를 누가 언제 만드는지는 아직 정하지 않았습니다.** 지금은 인증서를 가진
사람이 자기 맥에서 `--sign` 을 돌리는 것 말고 절차가 없습니다. CI 에서 만들려면
Developer ID 개인키를 CI 에 두어야 하는데, 그것은 서명을 별도 맥으로 뺀 이유
([ADR-0002](adr/0002-pull-based-signing-worker.md))를 정면으로 거스릅니다.
ADR-0022 의 후속 과제입니다.

## 4. 스토어 앱 배포

```bash
export ALLEY_APP_BUNDLE_ID="com.example.alley.store"
export ALLEY_APP_NAME="우리 앱 스토어"
export ALLEY_APP_URL_SCHEME="ourstore"
export ALLEY_SIGNING_IDENTITY="Developer ID Application: Example Inc. (TEAMID)"
export ALLEY_NOTARY_PROFILE="alley-notary"

./scripts/build-store-app.sh --sign
```

`ALLEY_APP_URL_SCHEME` 은 서버의 `STORE_APP_URL_SCHEME` 과 같아야 합니다. 로그인
콜백이 그 스킴으로 돌아옵니다. **이 값은 앱 `Info.plist` 에 박히므로 서버 혼자
바꾸면 이미 깔린 앱의 로그인이 깨집니다.**

만들어진 zip 을 웹 콘솔에 "서명·공증 완료" 로 올리면, 그다음부터는 스토어 앱이
자기 자신도 스토어에서 업데이트합니다. **첫 배포만 사람이 나눠줍니다.**

## 5. 첫 앱 올려보기

1. 웹 콘솔에서 앱을 등록합니다 (번들 ID 는 나중에 못 바꿉니다)
2. 새 버전 화면에서 zip 을 올립니다. Electron 처럼 JIT 를 쓰는 런타임을 품은 앱이면
   entitlements plist 도 함께 고릅니다 (아래 참고)
3. 미서명으로 올렸다면 워커가 가져가 서명·공증합니다. 상태가 `배포 준비됨` 이 되면
4. **출시** 를 누릅니다. 그때부터 스토어 앱 목록에 보입니다

CI 에서 올리려면 앱 상세 화면에서 배포 토큰을 발급하고:

```bash
export ALLEY_SERVER_URL="https://store.example.com"
export ALLEY_TOKEN="alleyd_..."
alley upload build/MyApp.zip --version 1.2.0

# Electron 처럼 권한이 필요한 앱
alley upload build/MyApp.zip --version 1.2.0 --entitlements build/app.entitlements
```

### entitlements 를 언제 함께 올리나

워커는 공증 요건이라 언제나 Hardened Runtime 으로 서명합니다. 그 아래에서 앱이 무엇을
할 수 있는지는 entitlements 가 정합니다.

**대부분의 맥 앱은 필요 없습니다.** 정말로 아무 권한도 쓰지 않습니다.

**Electron 이나 JIT 를 쓰는 런타임을 품은 앱은 필요합니다.**
`com.apple.security.cs.allow-jit` 없이 Hardened Runtime 아래에서 V8 을 띄우면 앱이
실행되자마자 죽습니다. 그래도 공증은 통과하기 때문에, 이걸 빼먹으면 **아무도 실행할 수
없는 앱이 배포까지 그대로 갑니다.** Electron 앱은 워커가 서명 전에 막아주지만, 다른 JIT
런타임은 잡지 못합니다.

파일은 대개 앱 빌드 설정에 이미 있습니다. Xcode 는 `CODE_SIGN_ENTITLEMENTS` 가 가리키는
`.entitlements` 파일이고, Electron 은 빌드 스크립트가 `codesign` 에 넘기는 plist 입니다.

이미 서명·공증을 마친 완성본을 `--signed` 로 올릴 때는 필요 없습니다. 서명 단계를 아예
지나가기 때문입니다. 서명된 앱을 워커가 다시 서명하는 경우에도, 안 주면 붙어 있던 권한을
그대로 읽어 다시 붙입니다.

어떤 권한으로 서명됐는지는 앱 상세 화면의 버전 줄에서 볼 수 있습니다.

## 6. 서버 업그레이드

새 버전이 나오면 `.env` 의 `ALLEY_IMAGE_TAG` 를 바꾸고 받습니다. 소스를 다시 받거나
서버에서 짓지 않습니다 ([ADR-0021](adr/0021-publish-server-container-image.md)).

```bash
# 1. 지금 무엇이 돌고 있는지 적어둡니다. 되돌릴 자리입니다.
docker compose images server

# 2. .env 에서 ALLEY_IMAGE_TAG 를 새 버전으로 바꿉니다

# 3. 새 이미지를 받습니다. 아직 갈아끼우지 않습니다.
docker compose pull server

# 4. 마이그레이션을 돌립니다. 새 이미지로 돌아갑니다.
docker compose run --rm server migrate --yes

# 5. 갈아끼웁니다.
docker compose up -d server

# 6. 확인합니다.
curl -fsS https://store.example.com/health
```

**순서가 중요합니다.** 3번과 4번을 건너뛰고 5번만 하면 새 코드가 없는 열을 찾습니다.
반대로 마이그레이션을 옛 이미지로 돌리면 새 마이그레이션이 아예 들어 있지 않습니다.

**무중단이 아닙니다.** 컨테이너를 갈아끼우는 동안 짧게 끊깁니다. 마이그레이션이 큰
표를 잠그면 그만큼 더 걸립니다.

### 되돌리기

`ALLEY_IMAGE_TAG` 를 옛 태그로 되돌리고 3번과 5번만 합니다. **마이그레이션은 되돌리지
않습니다.**

지금까지의 마이그레이션은 열이나 표를 더하는 방향이라, 새 스키마 위에서 옛 이미지가
도는 경우가 대부분입니다. 옛 코드는 새로 생긴 열을 모를 뿐 깨지지는 않습니다. 그래서
이미지만 되돌리는 것으로 대체로 충분합니다. **대체로입니다.** 열 이름을 바꾸거나
지우는 마이그레이션이 섞이면 그렇지 않고, 그런 마이그레이션은 언제든 생길 수 있습니다.

스키마까지 되돌려야 한다면:

```bash
docker compose run --rm server migrate --revert --yes
```

이 명령은 **마지막 배치**를 되돌립니다. 배치는 한 번의 `migrate` 실행에서 함께 적용된
마이그레이션 전부입니다. 한 번에 세 개가 적용됐다면 세 개가 같이 사라집니다. 그리고
되돌린다는 것은 그 마이그레이션이 만든 열과 표를 **지운다**는 뜻입니다. 그 안의
데이터도 같이 사라집니다. 롤백의 기본 수단으로 삼을 것이 못 됩니다.

**확인 필요.** 이 절차로 실제 데이터를 놓고 업그레이드와 롤백을 해본 적이 아직
없습니다. 처음 한 번은 데이터베이스를 백업한 뒤에 하세요. 백업 대상은 아래
[백업](#백업) 절에 있습니다.

### 워커와 스토어 앱은 따로입니다

이미지로 배포되는 것은 서버뿐입니다. 워커와 스토어 앱은 macOS 바이너리라 컨테이너에
담기지 않습니다.

- **워커**: 번들을 새로 만들어(`./scripts/build-worker-app.sh --sign`) 워커 맥에서
  `./install-worker.sh --bundle <새 zip>` 을 다시 돌립니다 (3번 참조). 갈아끼우기 전에
  돌던 워커를 내리고 통째로 바꾸므로, 서명 중인 잡이 없을 때 하세요. **자동 업데이트는
  아직 없습니다.** 워커 맥마다 사람이 갑니다
- **스토어 앱**: 새 빌드를 스토어에 올리면 앱이 스스로 갈아끼웁니다. 첫 배포만 사람이
  나눠줍니다 (4번 참조)

서버 API 는 뒤로 호환되게 유지하지만, 워커와 스토어 앱을 서버보다 한참 오래 두지
마세요.

## 7. 우리 조직의 설정은 어디에 두나

여기까지 따라오셨다면 **이 레포에는 없는 것들**이 손에 남았을 것입니다. 우리 도메인,
우리 로그인 정보, 우리 인증서, 우리 워커 맥. Alley 는 어떤 조직에도 묶여 있지 않게
만들어서, 조직에 묶이는 것은 전부 밖에 있습니다.

문제는 그것들이 지금 **흩어져 있다**는 점입니다.

| 무엇 | 지금 어디에 |
| --- | --- |
| 서버 설정과 비밀값 | 서버의 `.env` 파일 하나 |
| 워커 맥 설정 | 그 맥의 `launchd` 설정 안 |
| 스토어 앱 빌드 값 | **아무 데도 없습니다.** 매번 손으로 칩니다 |
| 워커 맥이 어느 기계이고 누가 관리하는지 | 사람 머릿속 |
| 인증서가 언제 만료되는지 | 사람 머릿속 |

### 왜 이게 문제인가

**틀려도 아무도 모릅니다.**

실제로 겪은 일입니다. `.env` 의 `ASC_ISSUER_ID` 와 `ASC_KEY_ID` 두 값이 서로 바뀌어
들어가 있었는데, 몇 달 동안 아무도 몰랐습니다. 그 값을 쓰는 화면을 실제로 열어본 적이
없었기 때문입니다. 파일 하나가 서버에만 있으면 누가 검토할 일도, 언제 바뀌었는지
확인할 일도 없습니다.

담당자가 바뀌면 더 나빠집니다. 인수인계할 것이 파일 하나와 기억뿐입니다.

### 권하는 방법: 비공개 레포 하나

**운영 설정만 담는 별도의 비공개 저장소를 하나 만드세요.** 제품 코드는 여기 있고,
조직에 묶이는 것은 거기 둡니다.

이렇게 하면 세 가지가 생깁니다.

1. **이력이 남습니다.** "9월 2일에 서버를 1.2.3 으로 올렸다", "인증서를 갈았다" 가
   기록으로 남습니다
2. **왜 그랬는지 적을 수 있습니다.** 이게 값을 안전한 곳에 두는 것만으로는 얻을 수
   없는 부분입니다
3. **검토를 받을 수 있습니다.** 혼자 하더라도, 바꾼 내용을 한 번 다시 보게 됩니다

담을 만한 것들입니다.

```
credentials.md    자격증명이 몇 개 있고 어디 보관되며 언제 만료되는가
server/           어떤 이미지 태그로 띄우고 있는가
worker/           워커 맥 목록. 각 맥에 무엇이 갖춰져 있어야 하는가
store-app/        스토어 앱을 어떤 값으로 빌드하는가
runbook.md        올리는 법, 워커가 죽었을 때, 인증서가 만료될 때
CHANGELOG.md      언제 무엇을 올렸는가
```

### 비밀값은 넣지 마세요

**실제 비밀번호와 개인키는 그 저장소에 넣지 않는 쪽을 권합니다.** 대신 "무엇이 어디에
있는지" 만 적습니다.

```
Developer ID 인증서 | 워커 맥의 로그인 키체인 | 2031-07-01 만료
JWT_SECRET         | 서버의 .env            | 잃으면 모든 로그인이 끊깁니다
```

암호화해서 넣는 방법도 있지만, 그러면 **암호를 푸는 열쇠를 또 어디에 둘지** 가 새
문제가 됩니다. 값의 이력을 포기하는 대신 그 문제를 만들지 않는 쪽이 대부분의 조직에
맞습니다.

넣지 않기로 했으면 **기계가 확인하게 하세요.** 사람은 잊습니다. 이 레포의
`scripts/check-secrets.sh` 가 그 일을 합니다. 복사해서 쓰시면 됩니다. 커밋하기 전에
자격증명처럼 생긴 값이 섞여 들어갔는지 훑어봅니다.

### 특히 잊기 쉬운 것

**서명 인증서와 공증 자격증명은 서버에 없습니다. 워커 맥의 키체인에 있습니다.**

서버를 아무리 잘 백업해도 그것들은 안 들어갑니다. 워커 맥이 고장 나면 서명을 할 수
없게 되고, Developer ID 인증서는 **팀에 다섯 개까지만** 만들 수 있으며 스스로 폐기할
수도 없습니다. 이 사실을 아는 사람이 한 명뿐이면 위험합니다. 적어두세요.

## 운영하면서 볼 것

| 화면 | 무엇을 보나 |
| --- | --- |
| 관리 > 서명 워커 | 워커가 살아 있는지. 10분 넘게 조용하면 알림이 갑니다 |
| 관리 > 개발자 포털 | 인증서 만료. 30일 전부터 표시됩니다 |
| 관리 > 통계 | 무엇이 실제로 쓰이는지 |
| 앱 상세 > 알림 | 새 피드백을 받을 Slack 채널 |

### 알림 설정

전역 알림(워커가 조용해짐)은 관리자가, 앱별 알림(새 피드백)은 앱 오너가 Slack
Incoming Webhook 주소를 넣습니다. 메일은 지원하지 않습니다.

## 백업

| 대상 | 왜 |
| --- | --- |
| PostgreSQL | 앱·버전·사용자·피드백 전부. 이것이 없으면 스토리지의 파일이 무엇인지 알 수 없습니다 |
| 오브젝트 스토리지 | 실제 바이너리 |
| `.env` | 비밀값. **JWT_SECRET 을 잃으면 모든 세션이 끊깁니다** |

서명 인증서와 공증 자격증명은 서버가 아니라 워커 머신에 있습니다. 그 머신의 키체인도
따로 백업해야 합니다. Sparkle 서명키도 그 머신에 있고, 이건 백업 방법이 조금 다릅니다
(아래).

## Sparkle 서명키

appcast 로 스스로 업데이트하는 앱이 있을 때만 해당됩니다. 스토어 앱만 쓰는 조직은
이 절을 건너뛰어도 됩니다.

워커가 결과물에 Ed25519 서명을 만들고, 앱은 자기 `Info.plist` 의 `SUPublicEDKey` 로
그 서명을 확인합니다 ([ADR-0017](adr/0017-sparkle-feed-tokens.md)).

### 어디에 있나

개인키는 워커 머신의 launchd 설정에 평문으로 들어갑니다. 워커 번들 자체는
`~/Library/Application Support/alley-worker/alley-worker.app` 에 설치되고, 아래 설정이
그 안의 실행 파일을 가리킵니다.

```
~/Library/LaunchAgents/com.example.alley-worker.plist
    → EnvironmentVariables > ALLEY_SPARKLE_PRIVATE_KEY
```

`install-worker.sh` 가 이 파일을 `600` 으로 만듭니다. 그래도 그 맥에 로그인할 수 있는
사람은 키를 읽을 수 있습니다. 코드 서명 인증서와 같은 자리에 두기로 한 결정이고,
그래서 지켜야 할 머신이 하나로 유지됩니다.

**Sparkle 의 `generate_keys` 를 쓰지 않습니다.** 그 도구는 개인키를 로그인 키체인에
넣지만 워커는 환경변수에서 읽습니다. 이미 키체인에 있는 키를 옮겨오려면
`generate_keys -x <파일>` 로 내보낸 값을 `ALLEY_SPARKLE_PRIVATE_KEY` 에 넣으세요.

### 백업

키는 32바이트뿐이라 백업 자체는 쉽습니다. 어려운 것은 잃은 뒤입니다.

- 조직의 비밀 보관소(1Password, Vault 같은 것)에 넣습니다. **워커 머신 백업에만
  기대지 마세요.** 그 머신을 새로 깔면 키가 사라집니다
- 최소 두 사람이 꺼낼 수 있어야 합니다. 담당자 한 명만 아는 상태를 만들지 마세요
- 공개키도 같이 적어둡니다. 개인키에서 언제든 다시 계산할 수 있지만, 개인키를 잃으면
  "지금 배포된 앱들이 어떤 키를 믿고 있는지" 확인할 방법이 없어집니다

공개키를 꺼내는 명령입니다. 워커에 별도 명령을 두지 않아서 `openssl` 로 합니다.

```bash
KEY="$ALLEY_SPARKLE_PRIVATE_KEY"
{ printf '302e020100300506032b657004220420' | xxd -r -p; \
  printf '%s' "$KEY" | base64 -d | head -c 32; } \
  | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64
```

### 잃어버리면 무슨 일이 벌어지나

잃은 키를 되살릴 방법은 없습니다. 그건 복구할 수 없습니다.

새 키를 만들면 워커는 새 키로 서명하는데, 이미 배포된 앱들은 옛 공개키로 그 서명을
검증하니 맞지 않습니다. Sparkle 은 `SUPublicEDKey` 를 **문자열 하나로만** 읽습니다.
두 키를 동시에 믿게 하거나, 옛 키를 남겨둔 채 새 키를 더하는 항목은 없습니다.

다만 Alley 에서는 여기서 끝나지 않습니다. Sparkle 은 Ed25519 서명과 Apple 코드 서명
**둘 중 하나만** 맞아도 업데이트를 받아들입니다. Sparkle 소스(`SUUpdateValidator.m`)의
주석이 그대로 말합니다.

> Either DSA must be valid, or Apple Code Signing must be valid. We allow failure of
> one of them, because this allows key rotation without breaking chain of trust.

Alley 의 결과물은 워커가 Developer ID 로 서명·공증한 것이고, 이미 깔린 앱도 같은
identity 로 서명돼 있습니다. **코드 서명 쪽이 이어져 있는 한 새 키로 넘어갈 수
있습니다.** 아래 절차를 밟으면 됩니다. 그 조건이 깨지는 경우는 절차 끝에 적었습니다.

### 교체 절차

**한 번에 하나만 바꿉니다.** Ed25519 키와 Developer ID 인증서를 같은 업데이트에서
동시에 바꾸면 이어줄 것이 없어져 그 자리에서 끊깁니다. Sparkle 문서의 표현 그대로
"changes either your Apple code signing certificate or your EdDSA keys (but not both)"
입니다.

1. **새 키를 만든다**

   ```bash
   openssl rand -base64 32
   ```

2. **워커를 새 키로 바꾼다**

   ```bash
   ALLEY_SPARKLE_PRIVATE_KEY="<새 키>" ./install-worker.sh --bundle <지금 쓰는 zip>
   ```

   키만 바꾸는 것이라 워커 번들은 그대로 두어도 됩니다. 지금 설치된 것과 같은 zip 을
   다시 주면 됩니다.

   이때부터 새로 서명되는 결과물은 전부 새 키로 서명됩니다. appcast 에 이미 올라가
   있는 옛 버전의 서명은 그대로 남아 옛 키로 계속 검증됩니다.

3. **각 앱에 새 공개키를 박은 빌드를 낸다**

   위 `openssl` 명령으로 새 공개키를 꺼내 앱의 `Info.plist` 에서 `SUPublicEDKey` 를
   바꾸고 빌드합니다. **인증서는 건드리지 않습니다.**

4. **그 빌드를 평소대로 올린다**

   이미 깔린 앱은 이 업데이트의 Ed25519 서명(새 키)을 검증하지 못하지만, 코드 서명이
   이어져 있어서 받아들입니다. 설치되고 나면 그 앱은 새 공개키를 갖게 되고 그다음부터는
   Ed25519 검증으로 돌아갑니다.

5. **옛 키를 지운다**

   모든 앱이 4번을 통과한 것을 확인한 뒤에 보관소에서 지웁니다. 오래 켜지 않은 맥이
   남아 있으면 그 앱은 아직 옛 키를 믿고 있습니다. 관리 > 통계의 다운로드 수로 얼마나
   넘어왔는지 가늠할 수 있습니다.

#### 4번이 안 되는 경우

이때는 새 빌드를 **사람이 나눠줘야** 합니다. 스토어 앱으로 받게 하거나 링크를 직접
전달합니다. Sparkle 경로로는 넘어갈 방법이 없습니다.

- **앱이 `SUVerifyUpdateBeforeExtraction` 을 켰을 때.** 이 설정을 켜면 Sparkle 은
  압축을 풀기 전에 검증해서 새 번들의 코드 서명을 볼 수 없습니다. Sparkle 문서는 이
  경우 키 교체를 "Developer ID 로 서명한 디스크 이미지(dmg)" 에서만 지원한다고 적습니다.
  **Alley 는 zip 을 배포합니다.** 이 설정을 켠 앱은 Sparkle 로 키를 교체할 수 없습니다

- **번들 ID 나 서명 identity 가 함께 바뀌었을 때.** Sparkle 은 이미 깔린 앱의
  designated requirement 를 새 빌드에 그대로 적용합니다. 무엇이 걸려 있는지는 그 앱에서
  직접 볼 수 있습니다:

  ```bash
  codesign -d -r- /Applications/MyApp.app
  ```

  Developer ID 의 designated requirement 는 보통 번들 ID 와 Team ID 에 걸리므로 같은
  팀에서 인증서를 갱신만 한 경우는 그대로 통과할 것으로 보입니다. **다만 이건 확인
  필요입니다.** 실제로 갱신해보기 전에는 단정하지 마세요. 위 명령으로 requirement 를
  미리 확인해두면 판단할 수 있습니다

### 언제 교체하나

- **유출이 의심될 때.** 워커 머신이 뚫렸거나, 백업이 엉뚱한 곳에 올라갔거나, 키를
  슬랙이나 이슈에 붙여넣었을 때. 의심만으로 충분합니다
- **키를 알던 사람이 나갈 때.** 팀을 옮기는 것도 포함합니다
- **워커 머신을 폐기할 때.** 디스크를 지웠어도 백업에는 남아 있습니다

정기 교체는 권하지 않습니다. 교체할 때마다 모든 앱이 3~4번을 밟아야 하고, 그 사이
어느 앱 하나가 빠지면 그 앱만 조용히 업데이트가 멈춥니다. 이유 없이 그 위험을 반복할
값이 없습니다.

## 자주 겪는 문제

**로그인 후 `redirect_uri_mismatch`**
`OAUTH_REDIRECT_URI` 와 Google 콘솔의 승인된 URI 가 글자 하나까지 같아야 합니다.
끝의 슬래시도 다릅니다.

**업로드가 `draft` 에서 멈춤 (브라우저 콘솔에 CORS 오류)**
브라우저가 스토리지로 직접 올리는 구조라(ADR-0009) 스토리지에 닿지 못하면 여기서
멈춥니다. 콘솔에 `blocked by CORS policy` 가 보이면 스토리지가 웹 콘솔의 출처를
허용하지 않고 있습니다. 지금 무엇이 허용돼 있는지부터 봅니다.

```bash
docker compose exec minio printenv MINIO_API_CORS_ALLOW_ORIGIN
```

브라우저 주소창의 `scheme://host:port` 와 글자 하나까지 같아야 합니다.
`https://store.example.com` 과 `https://store.example.com/` 은 다르고, `http` 와
`https` 도 다릅니다. `.env` 를 고쳤다면 `docker compose up -d minio` 로 다시 띄워야
반영됩니다.

스토리지에 직접 물어볼 수도 있습니다. `Access-Control-Allow-Origin` 이 돌아오지
않으면 그 출처가 막혀 있는 것입니다.

```bash
curl -si -X OPTIONS \
     -H 'Origin: https://store.example.com' \
     -H 'Access-Control-Request-Method: PUT' \
     https://storage.example.com/alley-artifacts/probe | grep -i access-control
```

**서명이 계속 대기 중**
관리 > 서명 워커에서 마지막 접속 시각을 보세요. 워커 머신이 잠자기로 들어가면
조용해집니다.

**`ALLOWED_EMAIL_DOMAINS` 를 고쳤는데 반영되지 않음**
그 값은 씨앗입니다. 관리자 화면에서 바꾸세요.

**설치는 되는데 실행하자마자 죽음**
entitlements 를 먼저 의심하세요. 앱 상세 화면의 버전 줄에서 어떤 권한으로 서명됐는지
볼 수 있습니다. 아무것도 안 보이면 권한 없이 서명된 것입니다. JIT 를 쓰는 런타임은
`com.apple.security.cs.allow-jit` 없이 Hardened Runtime 아래에서 실행되지 않습니다.
plist 를 갖춰 새 빌드를 다시 올리세요.
