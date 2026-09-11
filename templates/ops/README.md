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

### 3. 시크릿 넣기

레포 Settings > Secrets 에 넣습니다.

| 이름 | 무엇 |
| --- | --- |
| `ALLEY_SERVER_URL` | 스토어 서버 주소 |
| `ALLEY_OPERATOR_TOKEN` | 관리 > 서명 워커 화면에서 발급한 운영 토큰 (`alleyo_…`) |
| `ALLEY_STORE_APP_TOKEN` | 스토어 앱의 배포 토큰 (`alleyd_…`) |

**인증서와 공증 자격증명은 시크릿에 넣지 않습니다.** 러너가 도는 맥의 키체인에
이미 있습니다. `config/signing.env` 에 이름만 적습니다.

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
runbook/                    무엇이 잘못됐을 때 무엇을 하나
incidents/                  겪은 일. 시간이 지나면 재구성 안 되는 것
```
