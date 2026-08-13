# Alley 설계 문서

조직 내부에서 macOS 앱을 배포하는 셀프호스팅 앱 스토어의 설계와 구현 계획입니다.

- 상태: 승인됨 (2026-08-12)
- 진행: Phase 0 완료, Phase 1 착수 전

---

## 1. 무엇을 만드는가

### 배경

조직 안에서 쓰는 Mac 앱을 나눠주는 과정은 보통 이렇습니다. 누군가 로컬에서 빌드하고,
서명하고, 공증을 기다리고, 결과물을 스토리지나 메신저로 올립니다. 받는 사람은 그게
최신인지, 누가 만들었는지, 안전한지 알기 어렵습니다.

Mac App Store를 쓰면 이 문제가 해결되지만, 조직 내부에서만 쓸 앱을 공개 스토어에
올릴 수는 없습니다. Alley는 그 사이의 빈자리를 채웁니다.

### 결정사항

| 항목 | 결정 |
| --- | --- |
| 클라이언트 | 웹 콘솔(개발자용) + 네이티브 SwiftUI 스토어 앱(사용자용) |
| 배포 형태 | Docker 셀프호스팅. 어떤 호스팅 환경도 전제하지 않음 |
| 서명 파이프라인 | 서버 + macOS 서명 워커(pull 방식). 서명 키는 워커 머신에만 |
| 기술 스택 | Swift 풀스택 (Vapor 서버 + Swift 워커 + SwiftUI 앱 + 공유 DTO 패키지) |
| 인증 | Google OAuth (OIDC). 허용 도메인은 서버 설정. 다운로드도 로그인 필수 |
| MVP 범위 | 코어 배포 루프 (로그인 → 업로드 → 자동 서명·공증 → 다운로드/설치) |

### 왜 Swift 풀스택인가

세 계층(서버, 워커, 스토어 앱)이 같은 DTO 타입을 공유합니다. API 스펙이 어긋나면
런타임이 아니라 컴파일 단계에서 잡힙니다. 워커와 스토어 앱은 어차피 macOS 전용이라
Swift일 수밖에 없으므로, 서버까지 통일하면 한 팀이 전 계층을 유지보수할 수 있습니다.

절충한 부분도 있습니다. Vapor 생태계는 Node나 Go보다 작아서 없는 라이브러리는 직접
만들어야 할 수 있고, 기여자 풀이 "서버를 아는 Swift 개발자"로 좁아집니다. 이 프로젝트는
Apple 플랫폼 개발자가 주인이므로 이 절충을 받아들였습니다.

---

## 2. 코드 서명에 대해 짚고 갈 점

이 프로젝트의 설계는 macOS 코드 서명의 다음 사실 위에 서 있습니다.

### 서명하는 것은 인증서지 프로비저닝 프로필이 아니다

Developer ID 배포(App Store 외부 배포)에서 Gatekeeper가 보는 것은 두 가지입니다.

1. 유효한 **Developer ID Application 인증서** 서명
2. **Apple 공증(notarization)** 티켓

프로비저닝 프로필은 이 판단에 관여하지 않습니다. Apple의
[Developer ID 문서](https://developer.apple.com/support/developer-id)도 프로필 없는
앱을 정상 케이스로 전제합니다.

### 프로필이 필요한 경우

앱이 **restricted entitlement**를 쓸 때입니다. iCloud/CloudKit, Push Notifications,
App Groups, Sign in with Apple, Associated Domains, Network Extension, DriverKit 등이
여기 해당합니다. 이 경우 프로필이 없으면 Gatekeeper 경고가 아니라 entitlement 검증
실패로 앱이 실행되지 않습니다.

Xcode의 자동 서명이 Developer ID 빌드에서도 App ID와 프로필을 만들어주기 때문에
"항상 필요한 것"으로 오해하기 쉽습니다.

### 설계에 미치는 영향

서명·공증을 스토어가 대행하므로 **개발자는 인증서를 직접 다룰 필요가 없습니다.**
이것이 이 프로젝트가 제공하는 실질적인 편의입니다.

다만 restricted entitlement를 쓰는 앱은 `Contents/embedded.provisionprofile`이
**서명 이전에** 번들 안에 있어야 하므로, 개발자가 업로드하는 번들에 프로필이 이미
포함돼 있어야 합니다. 워커는 업로드된 번들의 entitlements를 검사해서, restricted
항목이 있는데 프로필이 없으면 서명 전에 명확한 에러로 실패시킵니다. 서명은 됐지만
실행되지 않는 앱이 배포되는 상황을 막기 위해서입니다.

---

## 3. 번들 ID와 App ID 관리 정책

번들 ID와 개발자 포털의 App ID는 다른 개념이므로 분리해서 다룹니다.

### 번들 ID는 앱마다 고유해야 한다

공유할 수 없습니다. macOS가 번들 ID를 기준으로 LaunchServices 앱 등록,
`UserDefaults` 도메인, Application Support 경로, 키체인 접근 그룹, TCC 권한
(카메라/마이크/화면 녹화) 승인 단위를 결정하기 때문입니다. 스토어 DB의
`apps.bundle_id`도 유니크 키입니다.

### 포털의 App ID는 와일드카드로 묶을 수 있다

조직의 개발자 계정에 App ID 엔트리가 쌓이는 것을 막기 위해 3단 정책을 씁니다.

| 앱 유형 | 포털 등록 | 비고 |
| --- | --- | --- |
| 대부분의 내부 앱 | **등록 없음** | 번들 ID만 고유하게. 서명 + 공증만으로 배포 |
| 프로필은 필요하나 특수 capability 없음 | **와일드카드 App ID 1개 공유** (`<prefix>.*`) | 포털에 엔트리 하나만 유지 |
| Push / iCloud / App Groups / Sign in with Apple / Associated Domains 사용 | explicit App ID 개별 등록 | 와일드카드로 커버 불가능 |

### 스토어가 ID 대장 역할을 한다

번들 ID 프리픽스는 서버 설정값 `BUNDLE_ID_PREFIX`로 둡니다. 스토어는 앱 등록 시
프리픽스 준수와 중복 여부를 검증하고, 등록된 번들 ID 목록을 웹 콘솔에서 조회할 수
있게 합니다. 포털의 엔트리는 최소로 유지하면서 실제 ID 관리 책임은 스토어가 가져갑니다.

---

## 4. 아키텍처

```
┌─────────────────┐     ┌──────────────────────────────┐
│  개발자          │     │  서버 (Docker)                 │
│  웹 콘솔에서      │────▶│  Vapor API + 웹 콘솔           │
│  앱 등록/업로드   │     │  PostgreSQL + S3 호환 스토리지  │
└─────────────────┘     └──────┬───────────────▲───────┘
                               │ ① 서명 잡 폴링   │ ③ 서명·공증
                               │   (아웃바운드만) │    완료본 업로드
                        ┌──────▼───────────────┴───────┐
                        │  서명 워커 (macOS)             │
                        │  codesign + notarytool        │
                        │  서명 키는 이 머신의 키체인에만  │
                        └───────────────────────────────┘
┌─────────────────┐
│  사용자          │     스토어 앱: 최초 실행 시 서버 주소 입력
│  SwiftUI 스토어  │──▶  /api/v1/meta 로 브랜딩·인증 설정 수신
│  앱에서 다운로드  │     로그인 후 탐색 → presigned URL 다운로드 → 설치
└─────────────────┘
```

### 서명 워커가 pull 방식인 이유

워커는 서버로 **나가는 방향으로만** 통신합니다(long-poll). 서명 키를 보관한 머신에
외부에서 들어오는 포트를 열 필요가 없습니다. 서버를 컨테이너 플랫폼에 두고 워커만
격리된 물리 머신에 두는 구성이 자연스럽게 나옵니다.

대안으로 서명 머신에 서버 전체를 올리는 방법도 있었지만, 서비스 가용성이 빌드 머신에
묶이고 macOS에서의 서버 운영 부담이 커지며, 셀프호스팅 진입장벽이 생겨서 택하지
않았습니다. 바이너리 왕복 전송 비용은 공증 대기 시간(수 분)에 비하면 무시할 수준입니다.

### 조직 중립성 원칙

이 프로젝트는 오픈소스 공개를 전제로 합니다.

- 애플리케이션 코드는 표준 인터페이스만 압니다: PostgreSQL URL, S3 호환 엔드포인트,
  SMTP, Slack Webhook URL. 전부 환경변수 주입
- 특정 조직의 이름, 내부 호스트, 실제 계정 주소가 코드에 등장하지 않습니다
- 스토어 이름/로고/색상/허용 도메인은 서버가 `GET /api/v1/meta`로 내려줍니다.
  클라이언트 바이너리에는 조직 고유값이 들어가지 않습니다
- 조직별 배포 매니페스트(플랫폼 설정, 시크릿, 도메인)는 이 레포 밖에 둡니다
- `scripts/check-denylist.sh`가 CI에서 이 원칙을 강제합니다

### 레포 구조

```
alley-store/
├── Package.swift
├── Sources/
│   ├── AlleyShared/       # DTO, API 경로 (서버·워커·앱 공유, 외부 의존 없음)
│   ├── AlleyServer/       # Vapor API 서버 + 웹 콘솔
│   └── AlleyWorker/       # macOS 서명 워커
├── Tests/
├── StoreApp/              # SwiftUI 스토어 앱 (예정)
├── Web/                   # 웹 콘솔 리소스 (Leaf 템플릿 + 정적 파일)
├── scripts/
├── docker-compose.yml
├── Dockerfile
└── docs/
```

`AlleyShared`는 Vapor를 포함해 어떤 외부 프레임워크에도 의존하지 않습니다.
SwiftUI 스토어 앱이 그대로 임포트해야 하기 때문입니다. HTTP 직렬화 능력은
서버 쪽에서 덧붙입니다.

웹 콘솔은 MVP에서 Vapor + Leaf 서버 렌더링에 최소한의 JS로 갑니다. 화면이 복잡해지면
(통계, 피드백 대시보드) 그때 SPA 전환을 검토합니다.

---

## 5. 핵심 설계

### 5.1 인증

- 표준 OIDC Authorization Code 플로우. 서버가 콜백을 받아 자체 세션 토큰(JWT) 발급
- ID 토큰의 `hd`(hosted domain) claim과 이메일 도메인을 **서버 측에서** 허용 도메인
  설정과 대조합니다. 클라이언트 검증만으로는 우회할 수 있으므로 반드시 서버에서 봅니다.
  `email_verified`도 확인합니다
- 스토어 앱은 `ASWebAuthenticationSession`으로 같은 서버 플로우를 태웁니다
  (커스텀 URL 스킴 콜백)
- 역할: `admin` / `developer` / `user`
  - 최초 로그인 시 기본 `user`
  - 서버 설정의 초기 관리자 목록에 있으면 `admin`
  - `admin`이 웹 콘솔에서 `developer`로 승격
- 다운로드 API도 인증 필수. 누가 언제 무슨 버전을 받았는지 기록합니다

### 5.2 데이터 모델

| 테이블 | 주요 필드 |
| --- | --- |
| `users` | google_sub, email, name, avatar_url, role |
| `store_settings` | 스토어 이름, 로고, 허용 도메인, 초기 관리자, 번들 ID 프리픽스 (singleton) |
| `apps` | bundle_id, 이름, 아이콘, 설명, 카테고리, owner_id |
| `app_members` | app_id, user_id (앱별 업로드 권한) |
| `versions` | app_id, short_version, build_number, 릴리즈 노트, min_macos, 상태 |
| `artifacts` | version_id, kind(unsigned/signed), s3_key, sha256, size |
| `signing_jobs` | version_id, 상태, worker_id, 로그, 시도 횟수 |
| `workers` | 이름, 토큰 해시, 마지막 폴링 시각 |
| `downloads` | user_id, version_id, timestamp |

버전 상태 머신:

```
draft → uploaded → signing → notarizing → ready → released
                      └──────── failed (재시도 가능) ────┘
```

로컬에서 이미 서명·공증을 마친 완성본을 올리는 경로는 `uploaded → ready`로 서명
단계를 건너뜁니다. 전이 규칙은 `VersionState`에 박아두어 단계를 건너뛰는 경로를
타입 수준에서 막습니다.

### 5.3 서명 워커

- Swift 실행 파일 + `launchd` LaunchAgent. 설치 스크립트 제공
- 워커가 서버로 long-poll (`GET /api/v1/worker/jobs/next`). 인바운드 포트 불필요
- 워커 등록: 관리자가 웹 콘솔에서 토큰 발급 → 워커 설정에 기입
- 잡 처리 순서:
  1. 잡 클레임 → presigned URL로 미서명 아티팩트 다운로드
  2. entitlements 검사 (restricted 항목이 있는데 프로필이 없으면 여기서 실패)
  3. `codesign --force --options runtime --sign "..."` (내부 프레임워크·헬퍼 포함
     inside-out 서명)
  4. `xcrun notarytool submit --wait`
  5. `xcrun stapler staple`
  6. 결과물을 presigned URL로 업로드, 상태·로그 보고
- 공증 자격증명은 환경변수가 아니라 `notarytool` 키체인 프로필 방식을 씁니다.
  자격증명이 프로세스 환경에 노출되지 않습니다
- `alley-worker preflight`로 설치 직후 환경을 점검합니다. 잡을 받은 뒤에 환경 문제를
  발견하면 원인 파악이 번거롭기 때문입니다
- 워커를 여러 대 등록할 수 있게 설계합니다. 큐가 서버에 있으므로 워커가 죽어도
  복구 시 이어서 처리합니다

### 5.4 스토어 앱

- 최초 실행: 서버 주소 입력 → `/api/v1/meta`로 브랜딩·인증 설정 수신
- 로그인 → 앱 목록/검색/상세 → presigned URL 다운로드 → `/Applications`에 설치
- 공증된 앱이므로 Gatekeeper를 통과합니다. quarantine 속성은 그대로 두어 macOS
  표준 검증을 태웁니다
- 설치된 앱의 버전을 추적해 업데이트를 표시합니다 (MVP는 수동 버튼)
- 스토어 앱 자체의 첫 배포는 웹 콘솔에서 직접 다운로드하고, 이후는 스토어 앱이
  자기 자신을 업데이트합니다

### 5.5 API 개요

```
GET   /health                          # 헬스체크
GET   /api/v1/meta                     # 브랜딩·인증 설정 (비인증)
GET   /auth/google, /auth/google/callback
POST  /api/v1/auth/token               # 앱용 토큰 교환
GET   /api/v1/me
GET   /api/v1/apps,  POST /api/v1/apps
GET   /api/v1/apps/:id,  PATCH /api/v1/apps/:id
POST  /api/v1/apps/:id/versions        # 버전 생성 + 업로드 URL 발급
POST  /api/v1/versions/:id/complete    # 업로드 완료 통지 → 서명 잡 생성
POST  /api/v1/versions/:id/release
GET   /api/v1/versions/:id/download    # 인증 → 이력 기록 → presigned URL
GET   /api/v1/worker/jobs/next         # 워커 long-poll (워커 토큰 인증)
PATCH /api/v1/worker/jobs/:id          # 상태·로그 보고
POST  /api/v1/admin/workers            # 워커 등록 토큰 발급
```

경로 상수는 `AlleyShared/APIPath.swift`에서만 정의합니다. 서버·워커·앱이 각자
문자열을 하드코딩하면 스펙이 어긋나기 때문입니다.

---

## 6. 구현 계획

### Phase 0. 프로젝트 셋업 — 완료

- [x] 모노레포 스캐폴딩 (Package.swift: 서버·워커·공유)
- [x] docker-compose (server + postgres + minio), Dockerfile (멀티스테이지)
- [x] CI: 빌드 + 테스트 (GitHub Actions)
- [x] 환경변수 기반 `AppConfig` + 조직 고유값 deny list 스크립트
- [ ] StoreApp Xcode 프로젝트 (Phase 1-5에서 생성)

### Phase 1. MVP: 코어 배포 루프 (3~4주)

**1-1. 서버 기초 (1주)**
- [x] `/api/v1/meta`, 스토어 설정
- [ ] Google OAuth 플로우 + 도메인 서버 검증 + JWT 세션
- [ ] users/roles, 초기 관리자 부트스트랩
- [ ] Fluent 마이그레이션 골격

**1-2. 앱/버전/아티팩트 (1주)**
- [ ] apps/versions/artifacts CRUD + 권한 (developer만 등록, app_members만 업로드)
- [ ] 앱 등록 시 번들 ID 검증 (프리픽스 준수 + 중복 차단), 번들 ID 대장 조회
- [ ] S3 presigned 업로드/다운로드 (SotoS3, multipart)
- [ ] 버전 상태 머신 서버 연동

**1-3. 서명 워커 (1주)**
- [ ] signing_jobs 큐 + 워커 API (long-poll, 클레임, 하트비트)
- [ ] codesign → notarytool → staple 파이프라인
- [ ] launchd 설치 스크립트 + 실제 인증서로 E2E 검증
- [ ] 실패 로그 수집/재시도

**1-4. 웹 콘솔 (0.5~1주, 1-2와 병행 가능)**
- [ ] 로그인, 앱 등록/편집, 버전 업로드(진행률), 서명 상태, 릴리즈
- [ ] 관리자 화면: 역할 관리, 워커 등록, 스토어 설정

**1-5. 스토어 앱 (1~1.5주, 병행 가능)**
- [ ] 서버 주소 입력 온보딩 + `/meta` 브랜딩 적용
- [ ] `ASWebAuthenticationSession` 로그인
- [ ] 앱 목록/상세/다운로드/설치
- [ ] 설치 버전 추적 + 수동 업데이트

**1-6. 첫 배포**
- [ ] 배포 환경 구성 (시크릿·도메인, 이 레포 밖)
- [ ] Google OAuth 클라이언트 발급
- [ ] 워커 설치, 파일럿 앱 1개로 전체 루프 검증

### Phase 2. 발급 자동화 + CLI (1~2주)

- [ ] App Store Connect API 연동: 인증서 현황 조회, 특수 capability 앱용 explicit
      App ID 등록, 필요 시 Developer ID 프로필 발급
- [ ] 와일드카드 App ID 1회 등록 + 웹 콘솔 현황 표시
- [ ] `alley-cli`: CI에서 버전 업로드 (`alley upload --app com.example.tool build.zip`)

### Phase 3. 별점 + 피드백 + 알림 (1~2주)

- [ ] 별점(1~5, 버전별), 피드백(텍스트 + 스크린샷 첨부)
- [ ] 스토어 앱/웹에 별점·리뷰 UI
- [ ] 알림 채널 추상화: Slack Incoming Webhook + SMTP. 앱별 알림 대상 설정
- [ ] 신규 피드백·별점 등록 시 앱 오너에게 발송

### Phase 4. 마무리 (1~2주)

- [ ] 스토어 앱 자동 업데이트 (백그라운드 체크 + 자체 교체)
- [ ] 다운로드/설치 통계 대시보드
- [ ] 공개 준비: LICENSE, 셀프호스팅 가이드, 시크릿 스캔, deny list 최종 점검

---

## 7. 수용 기준 (MVP)

1. `docker compose up`만으로 로컬에서 서버·DB·스토리지가 뜨고 브라우저에서 로그인까지 동작한다
2. 허용 도메인 밖의 계정은 로그인이 서버 단에서 거부된다
3. developer가 미서명 빌드를 올리면 워커가 자동으로 서명·공증·스테이플을 수행하고
   상태가 `ready`가 된다
4. released 버전을 스토어 앱에서 로그인 후 다운로드하면 Gatekeeper 경고 없이 실행된다
5. 다운로드 이력에 사용자·버전·시각이 기록된다
6. 코드에 조직 고유 명사가 검색되지 않는다 (CI deny list 통과)
7. 스토어 앱은 서버 주소만 입력하면 다른 조직 서버에도 그대로 붙는다

---

## 8. 리스크와 대응

| 리스크 | 대응 |
| --- | --- |
| 서명 워커 단일 장애점 | 큐는 서버 보관, 복구 시 이어서 처리. 워커 다중 등록 가능. 하트비트로 다운 감지 후 알림(Phase 3) |
| 서명 키 유출 | 키는 워커 머신 키체인에만. 워커 토큰은 해시 저장 + 회전 가능. 서명은 서버가 검증한 잡에 한정 |
| 공증 지연 / Apple 장애 | `notarytool --wait` 타임아웃 + 재시도. 상태를 웹 콘솔에 투명하게 노출 |
| OAuth `hd` claim 우회 | 이메일 도메인 + `hd` + `email_verified` 이중 검증을 서버에서 수행 |
| 대용량 업로드 실패 | S3 multipart. MVP는 단순 재시도, 재개 가능 업로드는 후속 |
| Vapor 생태계 한계 | OAuth/S3/JWT는 검증된 라이브러리 존재. 없는 것은 REST 직접 호출로 대체 |
| 조직 정보가 git 히스토리에 유입 | 처음부터 조직 값은 레포 밖 시크릿으로 분리. CI deny list. 공개 전 히스토리 청소가 필요 없는 구조 |
| 스토어 앱 첫 설치 배포 | 웹 콘솔에서 직접 다운로드(부트스트랩), 이후 자체 업데이트 |

---

## 9. 검증 계획

- **단위 테스트**: 상태 머신 전이, 번들 ID 검증, 설정 로딩, 권한 미들웨어,
  OAuth 도메인 검증
- **통합 테스트**: docker-compose 기반 API 시나리오
  (등록 → 업로드 → 잡 생성 → 상태 전이)
- **E2E**: 파일럿 앱 1개로 실제 서명·공증·다운로드·Gatekeeper 통과 확인
- **보안 점검**: 워커 토큰 없는 잡 API 접근 거부, 비로그인 다운로드 거부,
  presigned URL 만료 확인, 메타 응답에 비밀값 미포함
