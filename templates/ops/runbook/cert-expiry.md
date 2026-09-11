# 인증서가 만료될 때

**만료되면 서명과 공증이 전부 멈춥니다.** 워커가 잡을 받아도 실패하고, 새 릴리스를
만들 수도 없습니다.

`credentials.md` 에 만료일을 적어두고 미리 보세요.

## 미리 확인

```bash
security find-identity -v -p codesigning
# 인증서 상세
security find-certificate -c "Developer ID Application" -p | \
  openssl x509 -noout -dates
```

## 갱신한 뒤 고쳐야 하는 곳

새 인증서는 이름이 같아도 다른 것입니다.

1. `config/signing.env` 의 `ALLEY_SIGNING_IDENTITY` — 이름이 바뀌었으면 고칩니다
2. 각 워커 맥의 설정 파일 — 워커가 이 이름으로 서명합니다
3. `credentials.md` 의 만료일

**옛 인증서로 서명된 번들은 그대로 유효합니다.** `--timestamp` 로 Apple 타임스탬프를
받아뒀기 때문입니다. 갱신은 새로 서명할 것에만 영향을 줍니다.

## 공증 자격증명

App Store Connect API 키도 만료됩니다. 갱신하면 프로필을 다시 저장합니다.

```bash
xcrun notarytool store-credentials <프로필 이름> \
  --key <AuthKey_XXX.p8> --key-id <키 ID> --issuer <발급자 UUID>
```

**키체인이 잠겨 있으면 저장이 실패합니다.** 그런데도 마지막 줄은
`Success. Credentials validated.` 로 끝납니다. 그건 Apple 쪽 검증만 통과했다는 뜻입니다.
저장됐는지는 `notarytool history` 로 확인하세요.
