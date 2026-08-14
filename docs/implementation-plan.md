# Alley 구현 계획

무엇을 언제 만드는지에 대한 문서입니다. 진행에 따라 계속 갱신됩니다.

무엇을 왜 이렇게 만드는지는 [설계 문서](design.md)를, 개별 결정의 배경은
[ADR](adr/README.md)을 보세요.

- 최종 갱신: 2026-08-13
- 현재 상태: Phase 0 완료, Phase 1-1 진행 예정

## 진행 현황

| 단계 | 범위 | 예상 | 상태 |
| --- | --- | --- | --- |
| Phase 0 | 프로젝트 셋업 | 0.5주 | 완료 |
| Phase 1 | MVP: 코어 배포 루프 | 3~4주 | 진행 예정 |
| Phase 2 | 발급 자동화 + CLI | 1~2주 | 대기 |
| Phase 3 | 별점 + 피드백 + 알림 | 1~2주 | 대기 |
| Phase 4 | 마무리 + 공개 준비 | 1~2주 | 대기 |

---

## Phase 0. 프로젝트 셋업 — 완료

- [x] 모노레포 스캐폴딩 (Package.swift: 서버·워커·공유)
- [x] docker-compose (server + postgres + minio), Dockerfile (멀티스테이지)
- [x] CI: 빌드 + 테스트 (GitHub Actions)
- [x] 환경변수 기반 `AppConfig` + 조직 고유값 deny list 스크립트
- [ ] StoreApp Xcode 프로젝트 (Phase 1-5에서 생성)

## Phase 1. MVP: 코어 배포 루프 (3~4주)

목표: 로그인 → 앱 등록/업로드 → 자동 서명·공증 → 스토어 앱에서 다운로드·설치가
끝까지 동작한다.

### 1-1. 서버 기초 (1주)

- [x] `/api/v1/meta`, 스토어 설정
- [x] Google OAuth 플로우 + 도메인 서버 검증 + JWT 세션 ([ADR-0008](adr/0008-session-token-design.md))
- [x] users/roles, 초기 관리자 부트스트랩
- [x] Fluent 마이그레이션 골격
- [ ] 브라우저로 실제 로그인 E2E 확인

**선행 조건**: Google Cloud Console에서 OAuth 클라이언트 발급 (완료).
프로젝트 `alley-store`, 동의 화면 Internal, 웹 애플리케이션 클라이언트.

### 1-2. 앱/버전/아티팩트 (1주)

- [ ] apps/versions/artifacts CRUD + 권한 (developer만 등록, app_members만 업로드)
- [ ] 앱 등록 시 번들 ID 검증 (프리픽스 준수 + 중복 차단), 번들 ID 대장 조회
- [ ] S3 presigned 업로드/다운로드 (SotoS3, multipart)
- [ ] 버전 상태 머신 서버 연동

### 1-3. 서명 워커 (1주)

- [ ] signing_jobs 큐 + 워커 API (long-poll, 클레임, 하트비트)
- [ ] codesign → notarytool → staple 파이프라인
- [ ] entitlements 검사 (restricted 항목이 있는데 프로필이 없으면 서명 전 실패)
- [ ] launchd 설치 스크립트 + 실제 인증서로 E2E 검증
- [ ] 실패 로그 수집/재시도

**선행 조건**: 서명 워커를 돌릴 macOS 머신, Developer ID Application 인증서,
`notarytool store-credentials`로 저장한 공증 자격증명.

### 1-4. 웹 콘솔 (0.5~1주, 1-2와 병행 가능)

- [ ] 로그인, 앱 등록/편집, 버전 업로드(진행률), 서명 상태, 릴리즈
- [ ] 관리자 화면: 역할 관리, 워커 등록, 스토어 설정

### 1-5. 스토어 앱 (1~1.5주, 병행 가능)

- [ ] StoreApp Xcode 프로젝트 생성 (비샌드박스 + Hardened Runtime)
- [ ] 서버 주소 입력 온보딩 + `/meta` 브랜딩 적용
- [ ] `ASWebAuthenticationSession` 로그인
- [ ] 앱 목록/상세/다운로드/설치
- [ ] 설치 전 서명·Team ID·해시 검증
- [ ] 설치 앱 탐지(`/Applications`, `~/Applications` 스캔) + 수동 업데이트

### 1-6. 첫 배포

- [ ] 배포 환경 구성 (시크릿·도메인, 이 레포 밖)
- [ ] Google OAuth 클라이언트 발급 (운영용 리다이렉트 URI 추가)
- [ ] 워커 설치, 파일럿 앱 1개로 전체 루프 검증

## Phase 2. 발급 자동화 + CLI (1~2주)

- [ ] App Store Connect API 연동: 인증서 현황 조회, 특수 capability 앱용 explicit
      App ID 등록, 필요 시 Developer ID 프로필 발급
- [ ] 와일드카드 App ID 1회 등록 + 웹 콘솔 현황 표시
- [ ] `alley-cli`: CI에서 버전 업로드 (`alley upload --app com.example.tool build.zip`)

## Phase 3. 별점 + 피드백 + 알림 (1~2주)

- [ ] 별점(1~5, 버전별), 피드백(텍스트 + 스크린샷 첨부)
- [ ] 스토어 앱/웹에 별점·리뷰 UI
- [ ] 알림 채널 추상화: Slack Incoming Webhook + SMTP. 앱별 알림 대상 설정
- [ ] 신규 피드백·별점 등록 시 앱 오너에게 발송
- [ ] 워커 하트비트 끊김 알림

## Phase 4. 마무리 (1~2주)

- [ ] 스토어 앱 자동 업데이트 (Sparkle 통합)
- [ ] Sparkle appcast 엔드포인트 + 앱별 피드 토큰
- [ ] 관리 대상 앱 백그라운드 업데이트 확인
- [ ] 다운로드/설치 통계 대시보드
- [ ] 공개 준비: LICENSE, 셀프호스팅 가이드, 시크릿 스캔, deny list 최종 점검

---

## MVP 수용 기준

Phase 1을 완료로 판정하는 조건입니다.

1. `docker compose up`만으로 로컬에서 서버·DB·스토리지가 뜨고 브라우저에서
   로그인까지 동작한다
2. 허용 도메인 밖의 계정은 로그인이 서버 단에서 거부된다
3. developer가 미서명 빌드를 올리면 워커가 자동으로 서명·공증·스테이플을 수행하고
   상태가 `ready`가 된다
4. released 버전을 스토어 앱에서 로그인 후 다운로드하면 Gatekeeper 경고 없이
   실행된다
5. 다운로드 이력에 사용자·버전·시각이 기록된다
6. 코드에 조직 고유 명사가 검색되지 않는다 (CI deny list 통과)
7. 스토어 앱은 서버 주소만 입력하면 다른 조직 서버에도 그대로 붙는다

## 검증 방법

- **단위 테스트**: 상태 머신 전이, 번들 ID 검증, 설정 로딩, 권한 미들웨어,
  OAuth 도메인 검증
- **통합 테스트**: docker-compose 기반 API 시나리오
  (등록 → 업로드 → 잡 생성 → 상태 전이)
- **E2E**: 파일럿 앱 1개로 실제 서명·공증·다운로드·Gatekeeper 통과 확인
- **보안 점검**: 워커 토큰 없는 잡 API 접근 거부, 비로그인 다운로드 거부,
  presigned URL 만료 확인, 메타 응답에 비밀값 미포함

---

## 열려 있는 결정

착수 전에 정해야 하는 것들입니다.

| 항목 | 정해야 할 시점 | 내용 |
| --- | --- | --- |
| Sparkle 경로 허용 여부 | Phase 4 착수 전 | appcast 경로는 사용자 단위 다운로드 이력이 남지 않는다. 추적이 중요하면 이 경로를 막는 선택지가 있다 ([ADR-0006](adr/0006-dual-path-app-updates.md)) |
| 재개 가능 업로드 | Phase 1-2 이후 | MVP는 단순 재시도로 간다. 대용량에서 실패가 잦으면 재개 가능 업로드를 도입한다 |
| 웹 콘솔 SPA 전환 | Phase 3 착수 전 | Leaf 서버 렌더링으로 시작한다. 통계·피드백 대시보드가 복잡해지면 재검토한다 |
