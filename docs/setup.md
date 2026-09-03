# 설치 가이드

Alley 를 조직에 처음 올리는 절차입니다. 끝까지 따라가면 개발자가 빌드를 올리고
구성원이 스토어 앱으로 받는 상태가 됩니다.

설치한 뒤에 하는 일(업그레이드, 백업, 문제 해결)은 [운영 가이드](operations.md)에
따로 있습니다.

## 전체 지도

| 단계 | 무엇을 하나 | 필요한 것 | 대략 |
| --- | --- | --- | --- |
| [1](#1-google-oauth-클라이언트-발급) | Google OAuth 클라이언트 발급 | Google Workspace 관리 권한 | 15분 |
| [2](#2-https-붙이기) | 도메인에 HTTPS 붙이기 | 도메인, 서버의 80·443 포트 | 30분 |
| [3](#3-서버-띄우기) | 서버·데이터베이스·스토리지 띄우기 | Docker 돌아가는 서버 한 대 | 30분 |
| [4](#4-서명-워커-설치) | 서명 워커 설치 | 늘 켜져 있는 맥, Apple Developer Program | 1-2시간 |
| [5](#5-스토어-앱-배포) | 스토어 앱 만들어 나눠주기 | 4번과 같은 맥 | 30분 |
| [6](#6-첫-앱-올려보기) | 첫 앱 올려보기 | 올릴 `.app` 하나 | 15분 |

1번부터 3번까지는 서버 담당자가, 4번과 5번은 Apple Developer 인증서를 가진 사람이
합니다. 서로 다른 사람이어도 됩니다. 4번의 공증(Apple 서버가 앱을 검사하는 단계)은
기다리는 시간이 대부분이라 그만큼 더 걸릴 수 있습니다.

무엇을 왜 이렇게 만들었는지는 [설계 문서](design.md)에 있습니다. 여기서는 **어떻게
설치하는가**만 다룹니다.

## 준비물

| 항목 | 왜 필요한가 | 없으면 |
| --- | --- | --- |
| 서버 한 대 (Docker) | 서버·데이터베이스·스토리지가 여기 뜹니다 | 시작할 수 없습니다 |
| 도메인 | 로그인 콜백과 스토어 앱이 붙을 주소 | 로컬에서만 씁니다 |
| Google Workspace 계정 | 로그인에 씁니다 | 로그인할 수 없습니다 |
| macOS 머신 한 대 | 서명 워커가 여기서 돕니다 | 미서명 업로드가 서명되지 않습니다 |
| Apple Developer Program | Developer ID Application 인증서 | 서명·공증을 할 수 없습니다 |

TLS 인증서는 따로 준비하지 않아도 됩니다. [2번](#2-https-붙이기)에서 자동으로
받아오는 방법을 씁니다.

서명 워커를 돌릴 맥은 **전용 머신일 필요는 없지만 늘 켜져 있어야** 합니다. 잡을
기다리는 것이 그 프로세스의 일이라, 꺼져 있으면 큐가 쌓입니다.

## 1. Google OAuth 클라이언트 발급

OAuth(Open Authorization)는 "이 사람이 우리 조직 구성원이 맞다" 를 Google 에게
물어보는 방식입니다. Alley 는 자체 비밀번호를 두지 않고 이것만 씁니다.

Google Cloud Console 에서:

1. 프로젝트를 만듭니다
2. **API 및 서비스 > OAuth 동의 화면** 에서 **Internal** 을 고릅니다.
   조직 밖 계정이 애초에 동의 화면을 볼 수 없게 됩니다
3. **사용자 인증 정보 > OAuth 클라이언트 ID > 웹 애플리케이션**
4. 승인된 리디렉션 URI 에 다음을 넣습니다:
   - `https://store.example.com/auth/google/callback` (운영)
   - `http://localhost:8080/auth/google/callback` (로컬 개발)

`store.example.com` 자리에는 여러분이 쓸 도메인을 적습니다. 이 주소는 다음
단계에서 HTTPS 로 열게 됩니다.

발급받은 **클라이언트 ID 와 클라이언트 보안 비밀번호**를 적어두세요. 3번에서
`.env` 에 넣습니다.

동의 화면을 Internal 로 두어도 **서버가 이메일 도메인을 한 번 더 검사합니다.**
Google 설정 하나에 로그인 문을 전부 맡기지 않습니다.

## 2. HTTPS 붙이기

### 왜 필요한가

**로컬 개발이 아니면 HTTPS 없이는 로그인이 안 됩니다.** 그것도 "안 됩니다" 라는
에러가 뜨는 게 아니라, 두 가지 방식으로 조용히 막힙니다. 증상을 알아두면 나중에
디버깅할 때 시간을 아낍니다.

**첫째, Google 이 평문 리디렉션 주소를 거부합니다.** 1번에서 넣은 승인된 리디렉션
URI 가 `http://store.example.com/...` 이면 Google 콘솔이 저장 단계에서 막거나,
저장되더라도 로그인 시도에서 `redirect_uri_mismatch` 로 튕깁니다. 예외는
`localhost` 뿐입니다. Google 이 로컬 개발용으로만 평문을 허용합니다.

**둘째, 그렇다고 `PUBLIC_BASE_URL` 만 `https://` 로 적어두면 로그인이 무한
반복됩니다.** 서버는 이 값이 `https://` 로 시작할 때 세션 쿠키에 `Secure` 속성을
붙입니다. `Secure` 가 붙은 쿠키는 브라우저가 **HTTPS 연결에서만** 저장합니다.
그래서 실제 접속이 평문이면 이렇게 됩니다.

1. Google 로그인은 성공한다
2. 서버가 세션 쿠키를 담아 `/` 로 돌려보낸다
3. 브라우저가 그 쿠키를 **말없이 버린다**
4. `/` 에 도착했을 때 쿠키가 없으니 서버가 다시 로그인 화면을 보낸다
5. 1번으로 돌아간다

에러 메시지가 없고 로그도 깨끗합니다. 로그인 화면과 Google 화면 사이를 계속
왕복하면 이것부터 의심하세요.

반대로 `PUBLIC_BASE_URL` 을 `http://` 로 적으면 쿠키는 저장되지만 이번엔 Google 이
리디렉션 주소를 거부합니다. **둘 다 피하는 길은 실제로 HTTPS 를 붙이는 것뿐입니다.**

### 서버는 TLS 를 하지 않습니다

Alley 서버 자체는 인증서를 다루지 않습니다. `docker-compose.yml` 이 여는 것은
평문 HTTP 8080 포트 하나뿐이고, 서버 코드 어디에도 TLS 설정이 없습니다.
**HTTPS 종단은 앞단이 맡습니다.** 앞단은 리버스 프록시일 수도 있고 클라우드
로드밸런서일 수도 있습니다.

리버스 프록시(reverse proxy)는 바깥에서 오는 요청을 대신 받아 안쪽 서버로
넘겨주는 중계 서버입니다. 여기서는 그 중계 지점에서 인증서를 처리하고, 안쪽으로는
평문으로 넘깁니다.

### 방법 A: Caddy 를 앞에 세운다 (권장)

이미 쓰는 프록시가 없다면 [Caddy](https://caddyserver.com) 를 권합니다. 설정 세 줄로
Let's Encrypt 인증서를 자동으로 받아오고, 만료 전에 알아서 갱신합니다.

**먼저 확인할 것.** 도메인의 DNS A 레코드가 이 서버의 공인 IP 를 가리켜야 하고,
서버의 80·443 포트가 밖에서 닿아야 합니다. 인증서 발급 과정에서 Let's Encrypt 가
그 주소로 실제 접속해 도메인 소유를 확인하기 때문입니다.

`docker-compose.yml` 이 있는 자리에 `Caddyfile` 을 만듭니다.

```
store.example.com {
	reverse_proxy server:8080
}
```

이게 전부입니다. 도메인 이름과 넘길 대상만 적으면 인증서 발급·갱신·HTTP→HTTPS
리디렉션이 따라옵니다. `server` 는 compose 안의 서비스 이름이라 같은 네트워크에서
그대로 통합니다.

같은 자리에 `caddy-compose.yml` 을 만듭니다.

```yaml
services:
  caddy:
    image: caddy:2
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      # 받아온 인증서가 여기 쌓입니다. 이 볼륨을 지우면 다시 발급받습니다.
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - server
    restart: unless-stopped

volumes:
  caddy-data:
  caddy-config:
```

`443/udp` 는 HTTP/3 용입니다. 없어도 동작하지만 열어두면 브라우저가 더 빠른 쪽을
씁니다.

그리고 `.env` 에 세 줄을 맞춥니다.

```bash
# 서버 포트를 루프백에만 엽니다. 밖에서는 Caddy 를 통해서만 닿습니다.
SERVER_PORT=127.0.0.1:8080

PUBLIC_BASE_URL=https://store.example.com
OAUTH_REDIRECT_URI=https://store.example.com/auth/google/callback
```

`SERVER_PORT` 를 그대로 두면 8080 이 밖으로 열린 채로 남습니다. 그러면 누구든
HTTPS 를 건너뛰고 평문으로 붙을 수 있고, 위에 적은 쿠키 문제를 그 경로에서 다시
만납니다.

띄울 때는 compose 파일 두 개를 같이 줍니다.

```bash
docker compose -f docker-compose.yml -f caddy-compose.yml up -d

# 인증서를 제대로 받았는지 확인합니다. 실패해도 컨테이너는 뜨므로 로그를 봅니다.
docker compose -f docker-compose.yml -f caddy-compose.yml logs caddy
```

`certificate obtained successfully` 같은 줄이 보이면 된 것입니다. DNS 가 아직 안
퍼졌거나 80 포트가 막혀 있으면 여기서 실패 로그가 반복됩니다.

**확인 필요.** 이 구성은 Caddy 공식 문서로 문법과 기본 동작을 맞춰 적었지만, 실제
도메인에 인증서를 받아보기까지 돌려본 적은 없습니다. 첫 배포에서는 위 로그를 꼭
확인하세요.

### 방법 B: 이미 있는 프록시나 로드밸런서를 쓴다

회사에 이미 nginx, HAProxy, ALB 같은 것이 있으면 그걸 쓰면 됩니다. Alley 는 앞단이
무엇인지 알지 못하고 알 필요도 없습니다. `https://store.example.com` 을 받아
`http://<서버>:8080` 으로 넘기도록만 하면 됩니다.

맞춰야 할 것은 넷입니다.

- **`PUBLIC_BASE_URL` 을 밖에서 보이는 https 주소로.** 서버가 만드는 모든 링크
  (Slack 알림, Sparkle 피드, 웹 화면의 절대 주소)가 이 값에서 나옵니다. 요청의
  스킴을 보고 만들지 않기 때문에, 프록시 뒤에서 서버가 자기 주소를 http 로 알고
  있어도 링크는 틀어지지 않습니다
- **`OAUTH_REDIRECT_URI` 를 Google 콘솔에 넣은 값과 글자 하나까지 같게.** 이건
  `PUBLIC_BASE_URL` 에서 자동으로 만들어지지 않습니다. 따로 적어야 합니다
- **`Origin` 헤더를 지우지 마세요.** 서버는 쿠키로 인증된 상태 변경 요청(POST,
  PUT, PATCH, DELETE)에서 `Origin` 이 우리 출처인지 확인합니다. CSRF(Cross-Site
  Request Forgery, 다른 사이트가 로그인된 브라우저를 시켜 요청을 보내는 공격)
  방어입니다. 프록시가 이 헤더를 떼면 웹 콘솔의 모든 저장 동작이
  `요청 출처를 확인할 수 없습니다` 로 막힙니다. `Referer` 가 남아 있으면 그걸로
  대신 판단하지만, 둘 다 없으면 방법이 없습니다
- **스토리지 주소도 밖에서 닿아야 합니다.** 버전 업로드는 서버를 거치지 않고
  브라우저에서 스토리지로 바로 갑니다. 그래서 `S3_ENDPOINT` 는 **브라우저가 닿을 수
  있는 주소**여야 합니다. compose 기본값(`http://minio:9000`)은 컨테이너 안에서만
  통하는 이름이고, MinIO 포트도 루프백에만 열려 있습니다. 스토리지를 별도
  서브도메인으로 내보내거나 AWS S3 를 쓰세요

`X-Forwarded-Proto` 헤더는 넘겨주면 좋지만 **필수는 아닙니다.** Alley 가 이 헤더를
읽는 곳은 위의 `Origin` 검사 한 군데뿐이고, 거기서도 `Host` 의 http·https 양쪽과
`PUBLIC_BASE_URL` 을 모두 허용해서 헤더가 없어도 통과합니다. Caddy 는 기본으로
붙여줍니다.

요청 바디 크기 제한은 손댈 필요가 없습니다. 서버가 받는 요청은 1MB 를 넘지 않게
설계돼 있습니다. 큰 파일은 위에 적은 대로 스토리지로 직접 가기 때문입니다.

### 로컬 개발은 그대로

`http://localhost:8080` 은 아무것도 안 해도 됩니다. Google 이 `localhost` 에 한해
평문 리디렉션을 허용하고, `PUBLIC_BASE_URL` 이 http 라 쿠키에 `Secure` 도 붙지
않습니다. 아래 3번을 `.env.example` 기본값 그대로 따라가면 됩니다.

## 3. 서버 띄우기

서버 이미지는 CI 가 커밋마다 `ghcr.io/<소유자>/<레포>` 에 올립니다. **운영 서버에는
제품 소스를 두지 않습니다.** 필요한 것은 파일 두 개입니다.

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
| `PUBLIC_BASE_URL` | 밖에서 보이는 주소 (2번 참조) |
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

2번에서 Caddy 를 붙였다면 두 명령 모두 `-f docker-compose.yml -f caddy-compose.yml`
을 붙입니다.

**서버는 부팅할 때 스키마를 건드리지 않습니다.** 마이그레이션은 `migrate` 명령으로만
돕니다. 이 단계를 건너뛰면 서버는 뜨지만 아무 표도 없어서 첫 요청부터 깨집니다.
버전을 올릴 때도 같은 명령을 씁니다
([운영 가이드의 서버 업그레이드](operations.md#서버-업그레이드)).

`https://store.example.com` (로컬이면 `http://localhost:8080`)에서 로그인 화면이
뜹니다. `INITIAL_ADMIN_EMAILS` 에 적은 계정으로 들어가세요.

### 스토리지가 허용할 출처

버전 업로드는 서버를 거치지 않고 브라우저에서 스토리지로 바로 갑니다. 그래서
스토리지가 웹 콘솔의 출처를 허용해야 합니다. CORS(Cross-Origin Resource Sharing)
라고 부르는 규칙입니다.

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

## 4. 서명 워커 설치

macOS 앱은 서명과 공증(notarization, Apple 서버가 악성코드를 검사하고 도장을 찍는
절차)을 거치지 않으면 다른 맥에서 열리지 않습니다. 워커는 올라온 앱에 그 작업을
해주는 프로그램입니다.

**서명에 쓰는 개인키는 서버에 두지 않습니다.** 서버는 인터넷에 열려 있고 여러 사람이
붙습니다. 거기에 조직의 Developer ID 개인키를 두면, 서버가 뚫렸을 때 공격자가 우리
조직 이름으로 아무 앱이나 서명해 배포할 수 있습니다. 그래서 키는 별도 맥의 키체인에
두고, 워커가 서버에 "할 일 있나요" 하고 물으러 오는 방향으로 만들었습니다. 서버는
워커에 접속하지 못합니다.

워커는 서명·공증된 `.app` 번들로 배포합니다. 번들을 한 번 만들어 워커 맥에 가져다
놓는 두 단계입니다.

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

`--password` 에 넣는 "앱 암호" 는 Apple ID 비밀번호가 아니라 appleid.apple.com 에서
따로 발급하는 앱 전용 암호입니다.

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

스크립트가 번들의 서명을 확인하고, 환경을 점검한 뒤 `launchd` 에 등록합니다.
`launchd` 는 macOS 가 백그라운드 프로그램을 띄우고 죽으면 다시 살리는 장치입니다.
설치 위치는 `~/Library/Application Support/alley-worker/alley-worker.app` 이고, 로그는
`~/Library/Logs/alley-worker.log` 에 쌓입니다.

레포가 있는 맥에 그대로 설치할 때는 `--bundle` 없이 `./scripts/install-worker.sh` 로
부릅니다. 그 자리에서 빌드해 설치합니다.

**시스템 데몬이 아니라 LaunchAgent 입니다.** 서명에 쓰는 개인키가 로그인 키체인에
있고, 그 키체인은 로그아웃 상태에서 잠겨 있기 때문입니다. 그 맥은 로그인된 채로
두어야 합니다.

**워커 릴리스를 누가 언제 만드는지는 아직 정하지 않았습니다.** 지금은 인증서를 가진
사람이 자기 맥에서 `--sign` 을 돌리는 것 말고 절차가 없습니다. CI 에서 만들려면
Developer ID 개인키를 CI 에 두어야 하는데, 그것은 위에 적은 대로 서명을 별도 맥으로
뺀 이유를 정면으로 거스릅니다.

## 5. 스토어 앱 배포

구성원이 앱을 찾아 설치하는 맥 앱입니다. 웹 콘솔로도 같은 일을 할 수 있지만, 스토어
앱이 있어야 업데이트 알림을 받습니다.

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

## 6. 첫 앱 올려보기

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

entitlements 는 "이 앱이 무엇을 해도 되는지" 를 적어 서명에 함께 묶는 목록입니다.

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

## 다음

여기까지 왔으면 설치가 끝난 것입니다. 다음은 **[운영 가이드](operations.md)** 입니다.
서버 업그레이드, 백업, 우리 조직의 설정을 어디에 둘지, 자주 겪는 문제를 다룹니다.

appcast 로 스스로 업데이트하는 앱을 배포한다면 [Sparkle 서명키](sparkle.md)도
함께 보세요. 스토어 앱만 쓰는 조직은 필요 없습니다.

모르는 용어가 나오면 [용어집](glossary.md)에 있습니다. 왜 이렇게 만들었는지가
궁금하면 [ADR 목록](adr/README.md)을 보세요.
