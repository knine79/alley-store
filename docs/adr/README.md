# 아키텍처 결정 기록 (ADR)

되돌리기 어렵거나 나중에 "왜 이렇게 했지"를 묻게 될 결정을 기록합니다.
코드는 무엇을 하는지 보여주지만 무엇을 하지 않기로 했는지는 보여주지 않습니다.
버려진 대안을 남기는 것이 이 문서들의 목적입니다.

## 목록

| 번호 | 제목 | 상태 | 날짜 |
| --- | --- | --- | --- |
| [0001](0001-swift-fullstack-monorepo.md) | Swift 풀스택 모노레포로 간다 | 수락됨 | 2026-08-12 |
| [0002](0002-pull-based-signing-worker.md) | 서명을 별도 macOS 워커에 pull 방식으로 분리한다 | 수락됨 | 2026-08-12 |
| [0003](0003-organization-neutral-by-construction.md) | 조직 고유값을 코드에서 완전히 몰아낸다 | 일부 대체됨(ADR-0044) | 2026-08-12 |
| [0004](0004-docker-selfhosting-s3-abstraction.md) | Docker 셀프호스팅을 기본 배포 단위로 삼는다 | 수락됨 | 2026-08-12 |
| [0005](0005-bundle-id-and-app-id-policy.md) | 번들 ID는 고유하게, 포털 App ID는 와일드카드로 묶는다 | 수락됨 | 2026-08-12 |
| [0006](0006-dual-path-app-updates.md) | 앱 업데이트를 스토어 앱과 Sparkle 두 경로로 지원한다 | 수락됨 | 2026-08-13 |
| [0007](0007-store-app-without-sandbox.md) | 스토어 앱에 App Sandbox를 쓰지 않는다 | 수락됨 | 2026-08-13 |
| [0008](0008-session-token-design.md) | 세션 토큰은 신원만 담고 권한은 매번 조회한다 | 수락됨 | 2026-08-14 |
| [0009](0009-presigned-artifact-transfer.md) | 바이너리는 서버를 거치지 않고 presigned URL로 주고받는다 | 수락됨 | 2026-08-14 |
| [0010](0010-cookie-and-bearer-authentication.md) | 세션 토큰을 쿠키와 Authorization 헤더 양쪽에서 받는다 | 수락됨 | 2026-08-14 |
| [0011](0011-store-settings-in-database.md) | 스토어 설정을 데이터베이스로 옮기고 환경변수는 씨앗으로만 쓴다 | 수락됨 | 2026-08-18 |
| [0012](0012-browser-upload-script.md) | 콘솔에서 스크립트를 쓰는 화면은 업로드 하나로 한정한다 | 일부 대체됨(ADR-0030) | 2026-08-26 |
| [0013](0013-worker-token-authentication.md) | 워커는 사용자와 다른 신원으로, 해시만 저장하는 토큰으로 인증한다 | 수락됨 | 2026-08-31 |
| [0014](0014-store-app-without-xcode-project.md) | 스토어 앱을 Xcode 프로젝트 없이 SwiftPM 과 조립 스크립트로 만든다 | 수락됨 | 2026-08-31 |
| [0015](0015-app-scoped-deploy-tokens.md) | CI 는 앱 하나에 묶인 배포 토큰으로 올린다 | 수락됨 | 2026-08-31 |
| [0016](0016-server-handles-small-uploads.md) | 피드백 스크린샷은 서버가 직접 받는다 | 수락됨 | 2026-09-01 |
| [0017](0017-sparkle-feed-tokens.md) | Sparkle 피드는 앱별 읽기 전용 토큰을 주소에 실어 인증한다 | 수락됨 | 2026-09-01 |
| [0018](0018-stalled-signing-job-recovery.md) | 멈춘 서명 잡은 서버가 주기적으로 훑어 큐로 되돌린다 | 수락됨 | 2026-09-02 |
| [0019](0019-abandoned-draft-cleanup.md) | 버려진 draft 는 보관 기간이 지나면 오브젝트까지 함께 지운다 | 수락됨 | 2026-09-02 |
| [0020](0020-uploader-provides-entitlements.md) | entitlements 는 업로더가 버전과 함께 올린다 | 수락됨 | 2026-09-02 |
| [0021](0021-publish-server-container-image.md) | 서버를 컨테이너 이미지로 발행한다 | 수락됨 | 2026-09-02 |
| [0022](0022-worker-as-signed-app-bundle.md) | 서명 워커를 서명·공증된 `.app` 번들로 배포한다 | 수락됨 | 2026-09-02 |
| [0023](0023-signing-failure-codes.md) | 서명 실패에 오류 코드를 붙인다 | 수락됨 | 2026-09-02 |
| [0024](0024-storage-prefix-endpoints-credentials.md) | 스토리지 설정을 프리픽스·공개 주소·선택 자격증명으로 나눈다 | 수락됨 | 2026-09-03 |
| [0025](0025-feed-token-in-path.md) | 피드 토큰을 경로로 옮기고 질의 형식은 한동안 함께 받는다 | 수락됨 | 2026-09-08 |
| [0026](0026-security-headers.md) | 보안 헤더를 서버가 붙이고, CSP 는 화면이 실제로 쓰는 것만 연다 | 수락됨 | 2026-09-08 |
| [0027](0027-fail-fast-on-unsafe-config.md) | 안전하지 않은 설정으로는 서버가 뜨지 않는다 | 수락됨 | 2026-09-08 |
| [0028](0028-migrate-on-boot-with-advisory-lock.md) | 부팅 시 마이그레이션을 옵트인으로 열고 advisory lock 으로 한 대만 돌린다 | 수락됨 | 2026-09-08 |
| [0029](0029-verify-bundle-identifier-before-signing.md) | 번들 ID 는 서명 전에 워커가 대조한다 | 수락됨 | 2026-09-08 |
| [0030](0030-read-bundle-info-in-browser.md) | 번들 속성은 브라우저가 zip 을 열어 읽는다 | 수락됨 | 2026-09-08 |
| [0031](0031-register-and-first-upload-in-one-screen.md) | 앱 등록과 첫 버전 업로드를 한 화면에서 한다 | 수락됨 | 2026-09-09 |
| [0032](0032-accept-disk-images.md) | dmg 도 받고, 내용을 보고 형식을 가른다 | 수락됨 | 2026-09-09 |
| [0033](0033-drop-file-first-then-confirm.md) | 파일을 먼저 놓고 값을 확인한다 | 수락됨 | 2026-09-09 |
| [0034](0034-worker-decides-bundle-id-for-disk-images.md) | dmg 는 번들 ID 를 묻지 않고 워커가 정한다 | 수락됨 | 2026-09-10 |
| [0035](0035-worker-decides-signing-state.md) | 서명 여부는 사람에게 묻지 않고 워커가 판정한다 | 수락됨 | 2026-09-10 |
| [0036](0036-ask-for-entitlements-only-when-needed.md) | entitlements 는 필요한 것이 확인된 뒤에 묻는다 | 수락됨 | 2026-09-10 |
| [0037](0037-confirm-disk-image-upload-in-a-dialog.md) | dmg 업로드 확인을 `<dialog>` 로 받는다 | 수락됨 | 2026-09-10 |
| [0038](0038-container-credentials-provider.md) | 컨테이너 자격증명 공급자를 직접 붙인다 | 수락됨 | 2026-09-10 |
| [0039](0039-remove-unconfirmed-registrations.md) | 확정 전 등록만 지울 수 있다 | 대체됨 | 2026-09-11 |
| [0040](0040-version-upload-for-non-mac-developers.md) | 새 버전도 파일만 놓게 한다 | 수락됨 | 2026-09-11 |
| [0041](0041-remove-any-app-with-a-real-guard.md) | 어떤 앱이든 지울 수 있게 하되, 문턱을 서버에 둔다 | 수락됨 | 2026-09-11 |
| [0042](0042-worker-self-update.md) | 워커가 스스로를 갈아끼운다 | 수락됨 | 2026-09-11 |
| [0043](0043-product-and-operations-repositories.md) | 제품 레포와 운영 레포를 나눈다 | 수락됨 | 2026-09-11 |
| [0044](0044-store-app-knows-its-server.md) | 스토어 앱에 서버 주소를 빌드할 때 넣는다 | 수락됨 | 2026-09-15 |
| [0045](0045-branding-assets-in-storage.md) | 브랜딩 이미지를 서버가 받아 보관한다 | 수락됨 | 2026-09-15 |
| [0046](0046-server-assembles-store-app.md) | 스토어 앱 번들은 서버가 조립하고 워커가 서명한다 | 수락됨 | 2026-09-15 |
| [0047](0047-any-oidc-provider.md) | 로그인은 표준 OIDC 공급자면 무엇이든 받는다 | 수락됨 | 2026-09-15 |
| [0048](0048-server-ships-the-store-app-bundle.md) | 서버 이미지가 스토어 앱 번들을 함께 싣는다 | 수락됨 | 2026-09-16 |
| [0049](0049-public-store-app-download-page.md) | 스토어 앱을 받는 페이지를 로그인 없이 연다 | 수락됨 | 2026-09-16 |
| [0050](0050-store-app-ships-as-a-disk-image.md) | 스토어 앱만 dmg 로도 내보낸다 | 수락됨 | 2026-09-16 |
| [0051](0051-console-lists-only-what-you-can-touch.md) | 웹 콘솔 목록은 손댈 수 있는 앱만 보여준다 | 수락됨 | 2026-09-17 |
| [0052](0052-tell-long-polls-that-shutdown-started.md) | 종료가 시작됐다는 것을 긴 폴링에 알린다 | 수락됨 | 2026-09-17 |
| [0053](0053-make-app-ids-where-they-are-needed.md) | 포털 App ID 는 그것이 필요해진 자리에서 만든다 | 수락됨 | 2026-09-17 |
| [0054](0054-logging-out-of-the-provider-is-a-choice.md) | 공급자 세션까지 끊을지는 조직이 정한다 | 수락됨 | 2026-09-17 |
| [0055](0055-unique-names-among-usable-tokens.md) | 쓸 수 있는 토큰끼리는 이름이 겹치지 않게 한다 | 수락됨 | 2026-09-16 |
| [0056](0056-console-visitors-are-developers.md) | 웹 콘솔로 들어온 사람은 개발자로 둔다 | 수락됨 | 2026-09-21 |
| [0057](0057-workers-report-the-sparkle-public-key.md) | 워커가 Sparkle 공개키를 알리고, 화면이 쓸 수 있는 상태인지 말한다 | 수락됨 | 2026-09-21 |
| [0058](0058-mail-is-the-second-way-to-reach-a-person.md) | 사람에게 닿는 두 번째 길로 메일을 들인다 | 일부 대체됨(ADR-0059) | 2026-09-21 |
| [0059](0059-every-alert-picks-people-or-a-channel.md) | 알림은 어디서나 "사람들" 과 "채널" 중 하나를 고른다 | 수락됨 | 2026-09-21 |
| [0060](0060-mcp-connects-as-a-person.md) | MCP 는 사람으로 붙고, 배포 토큰은 CI 에 남긴다 | 수락됨 | 2026-09-22 |
| [0061](0061-leavers-are-cut-off-not-deleted.md) | 나간 사람은 지우지 않고 끊는다 | 수락됨 | 2026-09-22 |

## 언제 쓰나

다음에 해당하면 ADR을 씁니다.

- 되돌리려면 여러 파일을 고쳐야 하는 결정 (언어, 프레임워크, 배포 형태)
- 보안이나 신뢰 경계에 관한 결정 (키를 어디 두는가, 무엇을 검증하는가)
- 그럴듯한 대안을 놓고 고민한 끝에 하나를 고른 경우
- 나중 사람이 "왜 더 쉬운 길을 두고 이렇게 했지"라고 물을 만한 결정

다음은 쓰지 않습니다.

- 관례를 그대로 따른 선택 (린터 규칙, 파일 배치)
- 언제든 되돌릴 수 있는 구현 세부
- 대안을 진지하게 검토하지 않은 결정. 그건 결정이 아니라 기본값입니다

## 어떻게 쓰나

`NNNN-영문-제목.md` 형식으로 다음 번호를 붙여 이 디렉터리에 만들고, 위 표에
한 줄 추가합니다. 파일 이름의 번호는 바꾸지 않습니다.

구조는 다음을 따릅니다.

```markdown
# ADR-NNNN: 결정을 한 문장으로

- 상태: 수락됨 | 일부 대체됨(ADR-MMMM) | 대체됨(ADR-MMMM) | 폐기됨
- 날짜: YYYY-MM-DD

## 맥락
무엇 때문에 이 결정이 필요했는지. 제약이 무엇이었는지.

## 결정
무엇으로 정했는지. 구체적으로.

## 대안과 기각 사유
진지하게 검토한 대안들과 각각을 왜 버렸는지.
**대안의 장점을 먼저 인정하고 나서** 기각 이유를 씁니다.
장점이 없는 대안은 애초에 대안이 아니었습니다.

## 결과
좋은 점 / 나쁜 점 / 후속 과제.
나쁜 점을 반드시 씁니다. 없다고 쓰면 검토가 부족했다는 뜻입니다.
```

## 결정이 바뀌면

기존 ADR을 고치지 않습니다. 새 ADR을 쓰고 기존 것의 상태를
`대체됨(ADR-MMMM)`으로 바꿉니다. 왜 바뀌었는지가 기록으로 남아야 합니다.

**결정의 일부만 바뀌었으면** `일부 대체됨(ADR-MMMM)` 으로 두고, 무엇이 무효가 되고
무엇이 그대로인지를 그 ADR 맨 위에 인용 블록으로 적습니다. 전체를 `대체됨`으로
바꾸면 아직 유효한 나머지 결정까지 죽은 것으로 읽힙니다. ADR-0012 가 그 예입니다.
스크립트 경계는 무효가 됐지만 presigned 업로드 구조는 그대로입니다.
