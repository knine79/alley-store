# 자격증명 대장

**값은 여기 적지 않습니다.** 몇 개가 있고, 어디 있고, 언제 만료되고, 누가 주인인지만
적습니다.

| 무엇 | 어디 | 만료 | 주인 | 없으면 |
| --- | --- | --- | --- | --- |
| Developer ID Application | 서명 맥의 로그인 키체인 | 20XX-XX-XX | | 서명·배포 전부 멈춤 |
| 공증 자격증명 (notarytool 프로필) | 서명 맥의 data-protection 키체인 | API 키 만료일 | | 공증 멈춤 |
| 운영 토큰 (`alleyo_…`) | 이 레포 시크릿 `ALLEY_OPERATOR_TOKEN` | 없음 | | 워커 릴리스·스토어 앱 자동 빌드 멈춤 |
| 워커 토큰 | 각 워커 맥의 설정 파일 | 없음 | | 그 워커만 멈춤 |
| 서버 환경변수 | 배포 플랫폼 시크릿 | | | 서버가 안 뜸 |
| App Store Connect API 키 | 배포 플랫폼 시크릿 `ASC_*` | 없음 (폐기는 가능) | | 인증서 현황·App ID 등록 화면만 멈춤 |
| Slack 봇 토큰 | 배포 플랫폼 시크릿 `SLACK_BOT_TOKEN` | 없음 (폐기는 가능) | | **아무것도 안 멈추고 사람에게 가는 알림만 조용히 안 감** |

마지막 둘은 없어도 서버가 뜹니다. 그래서 끊겨도 한동안 모릅니다. Slack 봇 토큰이
특히 그런데, 알림이 안 오는 것과 실패가 없는 것이 구분되지 않습니다. 앱을 워크스페이스
에서 지우거나 토큰을 새로 발급하면 옛 토큰이 죽는다는 것을 알아두세요.

## 공증 자격증명은 보이지 않습니다

`notarytool store-credentials` 는 **data-protection 키체인**에 저장합니다. `security`
CLI 로도 Keychain Access 로도 보이지 않습니다. 있는지 확인하려면 실제로 써봐야 합니다.

```bash
xcrun notarytool history --keychain-profile <프로필 이름>
```

**키체인이 잠겨 있으면 저장도 사용도 실패합니다.** SSH 로 붙어 저장하려 하면
`User interaction is not allowed` 가 나고, 그런데도 마지막 줄은
`Success. Credentials validated.` 로 끝납니다. 그건 Apple 쪽 검증만 통과했다는
뜻이지 저장됐다는 뜻이 아닙니다.
