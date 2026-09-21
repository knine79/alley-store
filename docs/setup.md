# 설치 가이드

Alley 를 조직에 처음 올리는 절차입니다. 끝까지 따라가면 개발자가 빌드를 올리고
구성원이 스토어 앱으로 받는 상태가 됩니다.

설치한 뒤에 하는 일(업그레이드, 백업, 문제 해결)은 [운영 가이드](operations.md)에
따로 있습니다.

## 전체 지도

| 단계 | 무엇을 하나 | 필요한 것 | 대략 |
| --- | --- | --- | --- |
| [1](#1-로그인-공급자-클라이언트-발급) | 로그인 공급자 클라이언트 발급 | 조직 계정 시스템의 관리 권한 | 15분 |
| [2](#2-https-붙이기) | 도메인에 HTTPS 붙이기 | 도메인, 서버의 80·443 포트 | 30분 |
| [3](#3-서버-띄우기) | 서버·데이터베이스·스토리지 띄우기 | Docker 돌아가는 서버 한 대 | 30분 |
| [4](#4-서명-워커-설치) | 서명 워커 설치 | 늘 켜져 있는 맥, Apple Developer Program | 1\~2시간 |
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
| OIDC 를 말하는 계정 시스템 | 로그인에 씁니다. Google Workspace, Microsoft Entra ID, Okta, Keycloak 등 (ADR-0047) | 로그인할 수 없습니다 |
| macOS 머신 한 대 | 서명 워커가 여기서 돕니다 | 미서명 업로드가 서명되지 않습니다 |
| Apple Developer Program | Developer ID Application 인증서 | 서명·공증을 할 수 없습니다 |

TLS 인증서는 따로 준비하지 않아도 됩니다. [2번](#2-https-붙이기)에서 자동으로
받아오는 방법을 씁니다.

서명 워커를 돌릴 맥은 **전용 머신일 필요는 없지만 늘 켜져 있어야** 합니다. 잡을
기다리는 것이 그 프로세스의 일이라, 꺼져 있으면 큐가 쌓입니다.

## 1. 로그인 공급자 클라이언트 발급

OIDC(OpenID Connect)는 "이 사람이 우리 조직 구성원이 맞다" 를 조직의 계정 시스템에
물어보는 방식입니다. Alley 는 자체 비밀번호를 두지 않고 이것만 씁니다.

**공급자는 조직이 고릅니다** ([ADR-0047](adr/0047-any-oidc-provider.md)). 표준 OIDC 를
말하는 곳이면 됩니다.

| 공급자 | `OIDC_ISSUER` |
| --- | --- |
| Google Workspace | `https://accounts.google.com` (비워두면 이 값) |
| Microsoft Entra ID | `https://login.microsoftonline.com/<테넌트 ID>/v2.0` |
| Okta | `https://<조직>.okta.com` |
| Keycloak | `https://<호스트>/realms/<realm>` |
| Authentik | `https://<호스트>/application/o/<슬러그>/` |

어느 쪽이든 **웹 애플리케이션(confidential client)** 으로 만들고, 리디렉션 URI 에
아래 주소를 넣고, 클라이언트 ID 와 보안 비밀을 받아 3번에서 `.env` 에 넣습니다.

```
https://store.example.com/auth/google/callback   (운영)
http://localhost:8080/auth/google/callback       (로컬 개발)
```

> 경로에 `google` 이 남아 있는 것은 이미 배포된 스토어의 설정을 깨뜨리지 않으려는
> 것입니다. 공급자와 무관하게 이 경로를 씁니다.

**여러 조직이 함께 쓰는 주소는 쓸 수 없습니다.** Microsoft 의 `common` 이 그렇습니다.
그 주소로 열면 그 공급자에 계정이 있는 사람은 누구나 로그인을 시도할 수 있게 됩니다.
서버가 기동 후 첫 로그인에서 거절하며 무엇을 넣어야 하는지 알려줍니다.

### Google Workspace 를 쓴다면

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
`.env` 에 넣습니다. `OIDC_ISSUER` 는 비워두면 됩니다.

동의 화면을 Internal 로 두어도 **서버가 이메일 도메인을 한 번 더 검사합니다.**
공급자 설정 하나에 로그인 문을 전부 맡기지 않습니다.

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

**그래서 서버가 아예 뜨지 않습니다.** `PUBLIC_BASE_URL` 이 `http://` 인데 호스트가
`localhost`·`127.0.0.1` 이 아니면 기동에서 실패합니다. 위 두 증상이 둘 다 조용해서,
로그인이 안 되기 시작한 다음에 원인을 찾는 것보다 처음부터 막는 편이 낫다고 봤습니다
([ADR-0027](adr/0027-fail-fast-on-unsafe-config.md)).

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

맞춰야 할 것은 다섯입니다.

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
  브라우저에서 스토리지로 바로 갑니다. 서버가 컨테이너 이름으로 스토리지에 붙는다면
  (compose 기본값 `http://minio:9000`) 그 이름은 브라우저가 풀지 못합니다.
  `S3_PUBLIC_ENDPOINT` 에 **브라우저가 닿을 수 있는 주소**를 따로 적으세요.
  스토리지를 별도 서브도메인으로 내보내거나 AWS S3 를 쓰면 됩니다
  ([ADR-0024](adr/0024-storage-prefix-endpoints-credentials.md)).

  **이 값이 CSP 에도 들어갑니다.** 서버는 `connect-src` 에 스토리지 주소를 정확히
  적어 내보냅니다. 여기가 틀리면 브라우저가 업로드 요청을 막고, **화면에는 아무
  표시도 나지 않습니다.** 브라우저 개발자 도구 콘솔에만 CSP 위반이 찍힙니다
- **HSTS 는 앞단에서 붙이세요.** Alley 는 `Strict-Transport-Security` 를 보내지
  않습니다. 서버는 자기가 https 로 서비스되는지 알지 못하고, TLS 를 끊는 자리가
  이미 붙이는 경우가 많아 헤더가 둘 나가기 때문입니다
  ([ADR-0026](adr/0026-security-headers.md)). Caddy 는 기본으로 붙입니다.

  나머지 보안 헤더(`Content-Security-Policy`, `X-Content-Type-Options`,
  `Referrer-Policy`)는 서버가 직접 붙입니다. 앞단에서 **덮어쓰지 마세요.** 특히
  CSP 를 프록시가 다시 쓰면 스토리지 주소가 빠져 업로드가 조용히 막힙니다

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
`docker-compose.override.yml` 이 함께 있어서 이미지를 받는 대신 소스에서 빌드합니다.
아래 절차는 나머지가 같습니다.

`.env` 에서 반드시 채워야 하는 것:

| 변수 | 값 |
| --- | --- |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | 1번에서 발급한 것. 옛 이름 `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` 도 그대로 받습니다 |
| `OIDC_ISSUER` | 공급자의 issuer. 비우면 Google 입니다 |
| `OAUTH_REDIRECT_URI` | 승인된 리디렉션 URI 와 **글자 하나까지** 같아야 합니다 |
| `JWT_SECRET` | `openssl rand -base64 48` (32 바이트보다 짧으면 서버가 뜨지 않습니다) |
| `PUBLIC_BASE_URL` | 밖에서 보이는 주소 (2번 참조) |
| `S3_SECRET_ACCESS_KEY` | `openssl rand -base64 32` (역할로 인증하는 환경이면 액세스 키 둘을 비웁니다) |
| `INITIAL_ADMIN_EMAILS` | 첫 관리자. 이 계정으로 로그인해야 설정을 바꿀 수 있습니다 |
| `ALLOWED_EMAIL_DOMAINS` | 로그인을 허용할 도메인 |
| `ALLEY_IMAGE`, `ALLEY_IMAGE_TAG` | 받아올 서버 이미지 (아래) |

안 채워도 되는 것:

| 변수 | 값 |
| --- | --- |
| `SLACK_BOT_TOKEN` | 서명이 실패했을 때 올린 사람에게 Slack DM 을 보냅니다 (아래) |

### 서명 실패를 올린 사람에게 알리려면

비워 두면 실패해도 알림이 가지 않습니다. 올린 사람이 웹 콘솔에 다시 들어와야
실패를 압니다.

**앱 알림 대상(Incoming Webhook)으로는 안 됩니다.** 그쪽은 만들 때 정한 채널 하나에
쓰는 것이라 받는 사람을 고를 수 없습니다. 서명 실패는 그 버전을 올린 사람이 고치는
일이라 그 사람에게 닿아야 합니다.

1. Slack 워크스페이스에 앱을 하나 만듭니다 (<https://api.slack.com/apps>)
2. **OAuth & Permissions** 에서 봇 권한 둘을 줍니다
   - `users:read.email` - 이메일로 사용자를 찾습니다
   - `chat:write` - 그 사용자에게 DM 을 씁니다
3. 워크스페이스에 설치하고 **Bot User OAuth Token** (`xoxb-` 로 시작)을 받습니다
4. `.env` 에 `SLACK_BOT_TOKEN=xoxb-...` 로 넣습니다

**스토어 계정과 Slack 계정의 이메일이 같아야 합니다.** 다르면 찾지 못하고, 그 사실이
서버 로그에 남습니다. 조직 계정으로 둘 다 쓰는 것이 보통이라 이 가정으로 시작합니다.

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

이 명령을 돌릴 수 없는 플랫폼이라면 `MIGRATE_ON_BOOT` 를 켜는 방법이 있습니다.
기본값은 꺼짐이고, 돌릴 수 있다면 위 명령이 권장 경로입니다
([운영 가이드](operations.md#migrate-를-돌릴-수-없는-환경이라면)).

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

### 관리형 스토리지에 올릴 때

compose 의 MinIO 대신 이미 있는 오브젝트 스토리지를 쓰면 세 가지가 더 필요할 수
있습니다. 왜 이렇게 나누었는지는
[ADR-0024](adr/0024-storage-prefix-endpoints-credentials.md) 에 있습니다.

| 상황 | 채울 것 |
| --- | --- |
| 버킷 하나를 여러 프로젝트가 나눠 쓰고 우리 자리는 프리픽스 하나다 | `S3_KEY_PREFIX` |
| 서버는 클러스터 안 이름으로 붙고 브라우저는 그 이름을 못 푼다 | `S3_PUBLIC_ENDPOINT` |
| 액세스 키가 없고 인스턴스에 붙은 역할로 인증한다 | 액세스 키 둘을 비웁니다 |

`S3_KEY_PREFIX` 는 **배포할 때 정하고 그 뒤로 바꾸지 마세요.** 이미 올라간 오브젝트는
옛 자리에 그대로 있고 계속 읽히지만, 바꾸는 시점에 올리는 중이던 업로드와 워커가 물고
있는 서명 잡은 깨집니다.

`S3_PUBLIC_ENDPOINT` 는 **스토리지가 그 주소로 밖에서 닿을 수 있어야** 값을 합니다.
presigned URL 의 서명은 호스트를 포함해서 계산되므로, 여기에 적은 주소와 클라이언트가
실제로 붙는 주소가 다르면 스토리지가 403 으로 거절합니다.

액세스 키를 비우면 SDK 기본 자격증명 체인이 `AWS_*` 환경변수, 웹 아이덴티티 토큰,
인스턴스 메타데이터, `~/.aws` 를 차례로 봅니다. **둘 중 하나만 채우면 서버가 뜨지
않습니다.** 반쪽만 설정된 채로 뜨면 기본 체인으로 조용히 넘어가서, 방금 넣은 키가 왜
안 먹는지 알 수 없게 되기 때문입니다.

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

### 준비: 공증 자격증명

공증은 Apple 서버에 앱을 올려 검사받는 일이라 Apple 계정 인증이 필요합니다. 서명에
쓰는 인증서(`.p12`)와는 **다른 것**입니다.

| | 서명에 쓰는 것 | 공증에 쓰는 것 |
| --- | --- | --- |
| 무엇 | Developer ID Application 인증서 + 개인키 | App Store Connect API 키 |
| 형식 | `.p12` | `.p8` + Key ID + Issuer ID |
| 어디서 | developer.apple.com > Certificates | App Store Connect > 사용자 및 액세스 > 통합 > 키 |

App Store Connect 에서 키를 만들 때 **팀 키(Team Key)** 로 만드세요. 개인 키
(Individual Key)로는 공증이 안 됩니다. `.p8` 파일은 만들 때 한 번만 내려받을 수
있습니다.

키체인에 이름을 붙여 저장해둡니다.

```bash
xcrun notarytool store-credentials "alley" \
    --key ~/AuthKey_XXXXXXXXXX.p8 \
    --key-id "XXXXXXXXXX" \
    --issuer "00000000-0000-0000-0000-000000000000"
```

여기 붙인 이름(`alley`)을 아래에서 `ALLEY_NOTARY_PROFILE` 로 씁니다.

### 번들 만들기

레포와 Swift 툴체인, Developer ID 인증서가 있는 맥에서 합니다.

```bash
export ALLEY_WORKER_BUNDLE_ID="com.example.alley.worker"
export ALLEY_SIGNING_IDENTITY="Developer ID Application: Example Inc. (TEAMID)"
export ALLEY_NOTARY_PROFILE="alley"

./scripts/build-worker-app.sh --sign
```

`ALLEY_SIGNING_IDENTITY` 에 넣을 정확한 이름은
`security find-identity -v -p codesigning` 으로 확인합니다.

두 파일이 나옵니다.

| 파일 | 무엇 |
| --- | --- |
| `.build/worker-app/alley-worker.zip` | 번들만 |
| `.build/worker-app/alley-worker-kit.zip` | **번들 + 설치 스크립트** |

워커 맥으로는 **키트(kit)** 를 가져갑니다. 설치 스크립트가 번들 옆에 들어 있어서
따로 챙길 것이 없고, 둘의 버전이 어긋날 일도 없습니다.

공증은 Apple 서버가 처리하는 동안 몇 분에서 몇십 분 걸립니다. `--sign` 을 빼면
서명하지 않은 번들만 나오고, 그 번들은 만든 맥에서만 쓸 수 있습니다.

### 워커 맥에 설치하기

**워커 맥에는 소스도 Swift 툴체인도 필요 없습니다.** Xcode Command Line Tools 만
있으면 됩니다 (`xcode-select --install`).

워커 맥으로 옮길 파일은 셋입니다.

| 파일 | 어디서 나오나 |
| --- | --- |
| `alley-worker-kit.zip` | 위에서 만든 것 |
| Developer ID 인증서 (`.p12`) | `security export -k login.keychain -t identities -f pkcs12 -o signing.p12` |
| 공증 API 키 (`.p8`) | App Store Connect 에서 받아둔 것 |

**자격증명은 키트에 넣지 않습니다.** 한 파일에 모으면 그것 하나가 새는 순간 조직의
서명 권한이 통째로 넘어갑니다.

워커 맥에서 키트를 풀고 설정 파일을 만듭니다.

```bash
ditto -x -k alley-worker-kit.zip .
cd kit

./install-worker.sh --init-config ~/worker.conf
```

**설정 파일은 키트 밖에 둡니다.** 워커 토큰과 인증서 암호가 들어가는 파일이라, 키트
디렉터리 안에 두면 그것을 다른 곳으로 옮기거나 다시 압축할 때 비밀이 함께 딸려갑니다.

`~/worker.conf` 를 열어 값을 채웁니다. 워커 토큰은 웹 콘솔의 **관리 > 서명 워커** 에서
발급하고, **발급 직후 한 번만 보입니다.**

```
ALLEY_SERVER_URL=https://store.example.com
ALLEY_WORKER_TOKEN=발급받은-토큰
ALLEY_BUNDLE_PATH=alley-worker.app

ALLEY_P12_PATH=~/signing.p12
ALLEY_P12_PASSWORD=인증서-암호
ALLEY_KEYCHAIN_PASSWORD=이-맥의-로그인-키체인-암호

ALLEY_ASC_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8
ALLEY_ASC_KEY_ID=XXXXXXXXXX
ALLEY_ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
```

**서버 앞에 프록시가 있으면 `ALLEY_POLL_TIMEOUT` 도 정하세요.** 워커는 잡을
long-poll 로 기다리는데, 기본값 30초가 프록시의 타임아웃보다 길면 큐가 빌 때마다
504 가 납니다. 잡이 있을 때는 곧바로 응답이 오니 서명은 멀쩡히 되고, 로그만
"서버와 통신하지 못했습니다" 로 가득 찹니다. 프록시 타임아웃보다 짧게 잡으세요.

**`ALLEY_KEYCHAIN_PASSWORD` 는 인증서 암호가 아니라 그 맥에 로그인할 때 쓰는
암호입니다.** `codesign` 이 개인키를 꺼낼 때 승인 창을 띄우지 않게 하는 데 쓰고,
이 값이 맞지 않으면 첫 서명에서 창이 뜬 채로 멈춥니다. 워커는 아무도 안 보는
맥에서 도니까 그 창에 답할 사람이 없습니다.

경로는 `~/` 로 시작하는 홈 기준, `/` 로 시작하는 절대 경로, 그냥 이름만 쓰는 상대
경로 셋 다 됩니다. 상대 경로는 지금 있는 위치에서 먼저 찾고, 없으면 설정 파일이
있는 곳에서 찾습니다. 위 예시의 `alley-worker.app` 은 키트 안에서 실행하니 그대로
찾힙니다.

그리고 한 줄로 설치합니다.

```bash
./install-worker.sh --config ~/worker.conf
```

스크립트가 순서대로 합니다.

1. Xcode Command Line Tools 가 있는지 본다
2. 인증서를 로그인 키체인에 넣는다
3. 공증 자격증명을 프로필로 저장한다
4. 서명 identity 를 키체인에서 찾는다 (하나뿐이면 자동)
5. 번들의 서명을 확인하고 `launchd` 에 등록한다
6. 환경을 점검한다 (다섯 항목)

**설정 파일을 다 채웠으면 아무것도 묻지 않습니다.** 비워둔 값만 물어봅니다. 이미
인증서와 공증 프로필이 있는 맥이면 `ALLEY_P12_*` 와 `ALLEY_ASC_*` 를 비워두면 됩니다.

설치가 끝나면 **인증서와 API 키 파일을 그 맥에서 지우세요.** 키체인에 들어갔으니
파일은 더 필요 없습니다. `worker.conf` 도 토큰과 암호가 들어 있으니 함께 지웁니다.

`launchd` 는 macOS 가 백그라운드 프로그램을 띄우고 죽으면 다시 살리는 장치입니다.
설치 위치는 `~/Library/Application Support/alley-worker/alley-worker.app` 이고, 로그는
`~/Library/Logs/alley-worker.log` 에 쌓입니다. 되돌리려면
`./install-worker.sh --uninstall` 입니다.

레포가 있는 맥에 그대로 설치할 때는 `--bundle` 없이 `./scripts/install-worker.sh` 로
부릅니다. 그 자리에서 빌드해 설치합니다.

**워커를 여러 대 붙일 때는 토큰을 대마다 따로 발급하세요.** 하나를 나눠 쓰면 관리
화면에서 어느 맥인지 구분되지 않고, 한 대만 폐기할 수도 없습니다.

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

### 올릴 것이 없습니다

**스토어 앱은 서버 이미지에 들어 있습니다** ([ADR-0048](adr/0048-server-ships-the-store-app-bundle.md)).
받아서 올리는 단계가 없고, 서버를 올리면 그 번들도 함께 새것이 됩니다. 버전도 서버
버전을 그대로 씁니다.

1. **관리 > 스토어 앱** 에서 이름·번들 ID·URL 스킴·아이콘을 정합니다
2. **빌드해서 올리기** 를 누릅니다. 서버가 번들을 만들고 서명 워커가 서명·공증합니다
3. 같은 화면의 빌드 표에서 **출시** 를 누릅니다

출시를 사람이 누르는 것은 일부러 그렇게 둔 것입니다. 구성원의 맥에 설치될 앱이라
CI 사고가 그대로 나가면 안 됩니다.

운영 레포의 `adopt.yml` 을 붙여두면 1번과 2번도 저절로 돕니다
([ADR-0046](adr/0046-server-assembles-store-app.md)).

### 다른 번들로 빌드하기

특정 번들을 콕 집어 내보내야 할 때만 씁니다. 제품 릴리스에서
`alley-store-app-unsigned.zip` 을 받아 같은 화면의 **다른 번들로 빌드하기** 에
올리면, 그 뒤로는 서버에 들어 있는 것 대신 그것이 쓰입니다.

**올려두면 계속 그것이 쓰입니다.** 서버를 새로 올려도 마찬가지입니다. 화면이 "올려둔
번들" 이라고 적는 것이 그 표시입니다.

**스토어 앱에 관한 일은 이 화면에서 끝납니다.** 앱 목록에는 나오지 않습니다. 다른 앱을
받는 도구라 같은 줄에 서면 안 되고, 관리할 자리가 둘로 갈리지도 않아야 합니다.

받는 사람은 **앱 목록 맨 위의 안내 줄**에서 내려받습니다. 출시본이 있을 때만 나옵니다.
스토어 앱이 없는 사람에게는 그것이 유일한 입구라, 목록에서 뺐다고 받을 길까지 없애면
아무도 시작할 수 없습니다.

빌드 번호와 붙을 서버 주소는 서버가 정해서 넣습니다. 손으로 맞출 값이 없습니다.

### 이 맥에서 스토어 앱을 빌드하지 않습니다

예전에는 서명 맥에서 `build-store-app.sh --sign` 으로 만들고 배포 토큰으로 올렸습니다.
[ADR-0046](adr/0046-server-assembles-store-app.md) 이후로는 서버가 그 일을 합니다.
그래서 스토어 앱에는 **전용 배포 토큰이 필요 없습니다.** 운영 레포의
`ALLEY_STORE_APP_TOKEN` 은 뺐고, CI 는 워커 릴리스에 이미 쓰던
`ALLEY_OPERATOR_TOKEN` 하나로 베이스 번들까지 올립니다.

`scripts/build-store-app.sh` 는 남아 있지만 하는 일이 달라졌습니다. 브랜딩 없는 베이스
번들을 만들고, 로컬에서 앱을 띄워볼 때도 씁니다. 조직의 이름과 아이콘을 입히는 것은
서버 몫입니다.

### 새 번들을 올릴 때

`scripts/publish-store-app.sh` 하나가 번들을 만들고 올리고 빌드까지 시킵니다.
운영 CI 와 로컬이 같은 스크립트를 씁니다.

```bash
export ALLEY_SERVER_URL=http://localhost:8080
export ALLEY_OPERATOR_TOKEN=alleyo_...   # 관리 > 설정에서 발급
./scripts/publish-store-app.sh
```

버전은 `AlleyVersion.current` 에서 읽습니다. 이미 그 버전으로 빌드했으면 아무것도
하지 않고 끝납니다. 빌드 번호는 서버가 스스로 올려서, 같은 버전을 두 번 돌리면
쓸모없는 버전이 하나 더 생기기 때문입니다.

토큰이 없으면 번들까지만 만들고 그 경로를 알려줍니다. **관리 > 스토어 앱** 에서 손으로
올려도 됩니다.

**한 번 올린 번들이 서버 이미지에 딸려 온 것을 이깁니다**
([ADR-0048](adr/0048-server-ships-the-store-app-bundle.md)). 이미지 안의 최신 번들을
쓰고 싶으면 **관리 > 스토어 앱** 에서 `올려둔 번들 비우기` 를 누르세요. 그러면 이
서버에 들어 있는 것으로 돌아갑니다. 다른 번들로 갈아끼우는 것뿐이라면 이 스크립트를
다시 돌려 덮어써도 됩니다.

**스토어 앱은 Sparkle 을 쓰지 않습니다.** 앱을 받아 검증하고 `/Applications` 에 놓는
코드를 이미 갖고 있어서 자기 자신을 갈아끼우는 데도 그것을 씁니다
([설계 5.5](design.md#55-앱-업데이트)). 스토어 앱을 올리려고
[Sparkle 서명키](sparkle.md)를 먼저 만들 필요가 없습니다.

## 6. 첫 앱 올려보기

1. 웹 콘솔의 **새 앱** 화면에 앱 파일을 끌어다 놓습니다. zip 이나 dmg 둘 다 됩니다.
   **zip 이면** 번들 ID·이름·버전·빌드 번호·최소 macOS 를 읽어서 채워줍니다. dmg 는
   브라우저가 열 수 없어서 아무것도 묻지 않고, 다 올린 뒤 번들에서 읽습니다
   ([ADR-0034](adr/0034-worker-decides-bundle-id-for-disk-images.md))
2. **등록** 을 누르면 앱 등록과 첫 버전 업로드가 함께 됩니다. 번들 ID 는 나중에
   못 바꿉니다
3. 워커가 가져가 서명·공증합니다. 이미 서명·공증된 번들이면 알아보고 건너뜁니다
   ([ADR-0035](adr/0035-worker-decides-signing-state.md))
4. 상태가 `배포 준비됨` 이 되면 **출시** 를 누릅니다. 그때부터 스토어 앱 목록에 보입니다

Electron 처럼 권한이 필요한 앱은 **여기서 한 번 실패합니다.** 번들에 entitlements 가
안 붙어 있으면 서명 직전에 막고, 그 버전 옆에 파일을 붙여 다시 시도하는 자리가
나옵니다 ([ADR-0036](adr/0036-ask-for-entitlements-only-when-needed.md)). 올릴 때
미리 묻지 않는 이유는 대부분의 맥 앱이 필요 없기 때문입니다.

지금 올릴 파일이 없으면 파일 칸을 비우고 앱만 먼저 등록해도 됩니다. 번들 ID 를 미리
잡아두거나 빌드가 나오기 전에 멤버를 정해둘 때 그렇게 합니다. 두 번째 버전부터는 앱
상세 화면의 **새 버전** 으로 올립니다.

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

파일은 빌드 설정에 이미 있을 수 있습니다. Xcode 는 `CODE_SIGN_ENTITLEMENTS` 가 가리키는
`.entitlements` 파일이고, electron-builder 는 보통 `build/entitlements.mac.plist` 입니다.

**없는 경우도 흔합니다.** 개발 중에는 애드혹 서명이라 Hardened Runtime 이 걸리지 않고,
그러면 JIT 제한도 없어서 만들 이유가 없었습니다. 개발자 맥에서 잘 돌던 앱이 여기서
처음 막히는 것이 그래서입니다. 없으면 새로 만들면 됩니다. 파일 이름은 아무거나 되고
확장자만 `.plist` 나 `.entitlements` 면 됩니다. 실패 화면에 Electron 기준 본보기를
복사해 쓸 수 있게 붙여뒀습니다.

**웹 콘솔은 올릴 때 이 파일을 묻지 않습니다.** 번들에 붙어 있으면 워커가 읽어 그대로
다시 붙이고, 없는데 필요하면 그때 실패시키면서 붙일 자리를 냅니다
([ADR-0036](adr/0036-ask-for-entitlements-only-when-needed.md)). CLI 는 `--entitlements`
로 미리 줄 수 있고, 그러면 실패 한 번을 건너뜁니다.

이미 서명·공증을 마친 번들이면 워커가 알아보고 서명 자체를 건너뛰므로 역시 필요
없습니다 ([ADR-0035](adr/0035-worker-decides-signing-state.md)).

어떤 권한으로 서명됐는지는 앱 상세 화면의 버전 줄에서 볼 수 있습니다.

## 다음

여기까지 왔으면 설치가 끝난 것입니다. 다음은 **[운영 가이드](operations.md)** 입니다.
서버 업그레이드, 백업, 우리 조직의 설정을 어디에 둘지, 자주 겪는 문제를 다룹니다.

appcast 로 스스로 업데이트하는 앱을 배포한다면 [Sparkle 서명키](sparkle.md)도
함께 보세요. 스토어 앱만 쓰는 조직은 필요 없습니다.

모르는 용어가 나오면 [용어집](glossary.md)에 있습니다. 왜 이렇게 만들었는지가
궁금하면 [ADR 목록](adr/README.md)을 보세요.
