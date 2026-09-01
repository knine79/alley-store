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

```bash
git clone <이 레포>
cd alley-store
cp .env.example .env
```

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

```bash
docker compose up -d
```

`http://localhost:8080` (또는 설정한 주소)에서 로그인 화면이 뜹니다.

### 설정은 어디서 바꾸나

`.env` 의 값 중 **스토어 이름·로고·강조색·허용 도메인·번들 ID 프리픽스**는 최초
1회만 씨앗으로 쓰입니다. 그 뒤로는 관리자 화면에서 바꾸고, `.env` 를 고쳐도 아무 일도
일어나지 않습니다 ([ADR-0011](adr/0011-store-settings-in-database.md)).

비밀값과 부팅에 필요한 값(데이터베이스 주소 등)은 계속 `.env` 에 있습니다.

## 3. 서명 워커 설치

인증서를 보관할 맥에서:

```bash
# 공증 자격증명을 키체인에 저장합니다 (한 번만)
xcrun notarytool store-credentials "alley-notary" \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "앱 암호"

# 웹 콘솔의 관리 > 서명 워커에서 토큰을 발급받은 뒤
./scripts/install-worker.sh
```

스크립트가 환경을 점검하고 `launchd` 에 등록합니다. 로그는
`~/Library/Logs/alley-worker.log` 에 쌓입니다.

**시스템 데몬이 아니라 LaunchAgent 입니다.** 서명에 쓰는 개인키가 로그인 키체인에
있고, 그 키체인은 로그아웃 상태에서 잠겨 있기 때문입니다. 그 맥은 로그인된 채로
두어야 합니다.

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
2. 새 버전 화면에서 zip 을 올립니다
3. 미서명으로 올렸다면 워커가 가져가 서명·공증합니다. 상태가 `배포 준비됨` 이 되면
4. **출시** 를 누릅니다. 그때부터 스토어 앱 목록에 보입니다

CI 에서 올리려면 앱 상세 화면에서 배포 토큰을 발급하고:

```bash
export ALLEY_SERVER_URL="https://store.example.com"
export ALLEY_TOKEN="alleyd_..."
alley upload build/MyApp.zip --version 1.2.0
```

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
따로 백업해야 합니다.

## 자주 겪는 문제

**로그인 후 `redirect_uri_mismatch`**
`OAUTH_REDIRECT_URI` 와 Google 콘솔의 승인된 URI 가 글자 하나까지 같아야 합니다.
끝의 슬래시도 다릅니다.

**업로드가 `draft` 에서 멈춤**
브라우저가 스토리지로 직접 올리는 구조라(ADR-0009) 스토리지에 닿지 못하면 여기서
멈춥니다. 브라우저 콘솔에서 CORS 오류를 확인하세요.

**서명이 계속 대기 중**
관리 > 서명 워커에서 마지막 접속 시각을 보세요. 워커 머신이 잠자기로 들어가면
조용해집니다.

**`ALLOWED_EMAIL_DOMAINS` 를 고쳤는데 반영되지 않음**
그 값은 씨앗입니다. 관리자 화면에서 바꾸세요.
