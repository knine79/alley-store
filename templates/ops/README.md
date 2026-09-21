# Alley 운영 레포 (템플릿)

이 디렉터리를 **비공개 레포로 복사해** 쓰세요. 여기에는 조직에 묶이는 것만 둡니다.
제품 코드는 [Alley 제품 레포](https://github.com/knine79/alley-store)에 있고, 이
레포는 그것을 태그로 고정해 받아 **빌드·서명·배포**합니다 (ADR-0043).

## 왜 레포가 둘인가

제품 레포는 어떤 조직도 모르게 만들어져 있습니다. 그런데 실제로 스토어를 세우려면
조직에 묶이는 것이 반드시 생깁니다 - 서버 주소, 허용 도메인, Developer ID 인증서,
어느 맥이 워커인지.

그리고 **서명은 제품 레포에서 할 수 없습니다.** Developer ID 개인키는 조직 것이고,
공개 전제인 레포의 CI 에 둘 수 없습니다.

## 처음 세우기

### 1. 이 디렉터리를 비공개 레포로 복사

```bash
gh repo create <조직>/alley-ops --private
git clone https://github.com/<조직>/alley-ops && cd alley-ops
cp -R <제품레포>/templates/ops/. .
git submodule add https://github.com/knine79/alley-store.git product
git -C product checkout v0.3.0
```

`alley.lock` 에 그 태그를 적습니다.

### 2. 서명 맥에 러너 붙이기

**개인키가 그 맥을 떠나지 않게 하려고 self-hosted 러너를 씁니다.** 워커가 도는 맥에
얹으면 됩니다. 그 맥은 이미 조직 서명 권한을 가진 머신이라 신뢰 경계가 새로 생기지
않습니다.

레포 Settings > Actions > Runners 에서 러너를 추가하고 라벨을 이렇게 답니다.

```
self-hosted, macos, alley-signing
```

> **이 러너는 이 비공개 레포에만 등록하세요.** 공개 레포에 등록하면 누구든 PR 로
> 그 맥에서 코드를 돌릴 수 있습니다.

**그 맥은 자동 로그인을 켜야 합니다.** 로그인 키체인이 잠겨 있으면 서명이 조용히
실패합니다. `notarytool` 은 `User interaction is not allowed` 로 죽습니다.

자세한 절차는 `runbook/setup-runner.md` 에 있습니다. 설치가 끝나면 점검 스크립트를
돌리세요. **설치는 됐는데 나중에 터지는 것들**을 여기서 잡습니다.

```bash
./scripts/check-signing-mac.sh
```

서명과 공증을 실제로 해보고, 그 맥에 공개 레포 러너가 함께 있는지도 봅니다.

### 3. 시크릿 넣기

레포 Settings > Secrets 에 넣습니다.

| 이름 | 무엇 |
| --- | --- |
| `ALLEY_SERVER_URL` | 스토어 서버 주소 |
| `ALLEY_OPERATOR_TOKEN` | 관리 > 서명 워커 화면에서 발급한 운영 토큰 (`alleyo_…`). 워커 릴리스와 스토어 앱 빌드에 함께 씁니다 |
| `ALLEY_REGISTRY_USER` | (선택) 서버 이미지를 받을 레지스트리 사용자 |
| `ALLEY_REGISTRY_TOKEN` | (선택) 그 레지스트리 토큰 |

아래 둘은 `scripts/rollout-server.sh` 가 비공개 레지스트리에서 이미지를 받을 때만
필요합니다. 그 스크립트가 다른 값을 더 쓴다면 `adopt.yml` 의 **서버 롤아웃** 단계
`env:` 에 함께 적어주세요. 워크플로는 그 스크립트가 무엇을 필요로 하는지 모릅니다.

**인증서와 공증 자격증명은 시크릿에 넣지 않습니다.** 러너가 도는 맥의 키체인에
이미 있습니다. `config/signing.env` 에 이름만 적습니다.

### 3-1. 사람에게 알림을 보내려면 (선택)

스토어가 보내는 알림에는 두 갈래가 있습니다.

| 받는 곳 | 무엇으로 | 어디서 정하나 |
| --- | --- | --- |
| 앱 채널 | Incoming Webhook | 앱 상세의 **알림** 에서 앱마다 |
| 사람 | 이 봇 토큰 | 서버 환경변수 하나로 스토어 전체 |

받는 사람이 정해지는 알림은 봇 토큰 쪽으로 갑니다. 지금은 서명 실패 하나뿐이고,
비워 두면 그 알림이 가지 않아 올린 사람이 웹 콘솔에 다시 들어와야 실패를 압니다.

[`slack-app-manifest.yml`](slack-app-manifest.yml) 을 <https://api.slack.com/apps> >
Create New App > **From an app manifest** 에 붙여넣으면 앱이 만들어집니다. 설치한 뒤
Bot User OAuth Token (`xoxb-` 로 시작)을 **서버 환경변수** `SLACK_BOT_TOKEN` 에
넣으세요.

**이 레포 시크릿이 아니라 배포 플랫폼 시크릿입니다.** 서버가 읽는 값이고, 이 레포의
워크플로는 쓰지 않습니다.

### 4. 첫 배포

```bash
gh workflow run adopt.yml
```

## 담는 것과 담지 않는 것

| 담는다 | 담지 않는다 |
| --- | --- |
| 어떤 값으로 빌드하는가 | 값 자체 (시크릿·키체인에) |
| 자격증명이 몇 개고 어디 있고 언제 만료되는가 | 비밀번호, 개인키 |
| 워커 맥 목록과 상태 | |
| 무엇을 언제 올렸는가 | |
| 겪은 일 (`incidents/`) | |

**비밀값을 넣지 마세요.** 비공개 레포라도 접근 권한은 시간이 지나며 넓어집니다.

## 디렉터리

```
alley.lock                  고정한 제품 버전. 이것만 올리면 전체가 따라감
product/                    제품 레포 서브모듈 (alley.lock 의 태그에 고정)
config/
  signing.env               서명 identity 와 공증 프로필 "이름"
  store.env                 스토어 이름, 번들 ID 접두어 등
.github/workflows/
  adopt.yml                 빌드 → 서명 → 업로드 → 롤아웃
  watch.yml                 제품 레포 새 릴리스 감지 → PR 생성
credentials.md              자격증명 대장
slack-app-manifest.yml      사람에게 DM 을 보내는 Slack 앱 manifest
scripts/
  check-signing-mac.sh      서명 맥이 제대로 섰는지 본다
  rollout-server.sh         이미지를 배포 플랫폼으로 옮김 (.example 참고)
runbook/                    무엇이 잘못됐을 때 무엇을 하나
  setup-runner.md           서명 맥에 러너 얹기
incidents/                  겪은 일. 시간이 지나면 재구성 안 되는 것
```
