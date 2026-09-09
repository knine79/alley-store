# Sparkle 서명키

appcast 로 스스로 업데이트하는 앱이 있을 때만 해당됩니다. 스토어 앱만 쓰는 조직은
이 문서를 통째로 건너뛰어도 됩니다.

Sparkle 은 맥 앱이 자기 자신을 업데이트할 때 널리 쓰는 오픈소스 프레임워크이고,
appcast 는 그 앱이 "새 버전 있나요" 하고 들여다보는 XML 피드입니다.

워커가 결과물에 Ed25519 서명을 만들고, 앱은 자기 `Info.plist` 의 `SUPublicEDKey` 로
그 서명을 확인합니다. 서버가 가짜 업데이트를 밀어 넣지 못하게 하는 장치입니다.

- [어디에 있나](#어디에-있나)
- [백업](#백업)
- [잃어버리면 무슨 일이 벌어지나](#잃어버리면-무슨-일이-벌어지나)
- [교체 절차](#교체-절차)
- [언제 교체하나](#언제-교체하나)

## 어디에 있나

개인키는 워커 머신의 launchd 설정에 평문으로 들어갑니다. 워커 번들 자체는
`~/Library/Application Support/alley-worker/alley-worker.app` 에 설치되고, 아래 설정이
그 안의 실행 파일을 가리킵니다.

```
~/Library/LaunchAgents/com.example.alley-worker.plist
    → EnvironmentVariables > ALLEY_SPARKLE_PRIVATE_KEY
```

`install-worker.sh` 가 이 파일을 `600` 으로 만듭니다. 그래도 그 맥에 로그인할 수 있는
사람은 키를 읽을 수 있습니다. 코드 서명 인증서와 같은 자리에 두기로 한 결정이고,
그래서 지켜야 할 머신이 하나로 유지됩니다.

**Sparkle 의 `generate_keys` 를 쓰지 않습니다.** 그 도구는 개인키를 로그인 키체인에
넣지만 워커는 환경변수에서 읽습니다. 이미 키체인에 있는 키를 옮겨오려면
`generate_keys -x <파일>` 로 내보낸 값을 `ALLEY_SPARKLE_PRIVATE_KEY` 에 넣으세요.

## 백업

키는 32바이트뿐이라 백업 자체는 쉽습니다. 어려운 것은 잃은 뒤입니다.

- 조직의 비밀 보관소(1Password, Vault 같은 것)에 넣습니다. **워커 머신 백업에만
  기대지 마세요.** 그 머신을 새로 깔면 키가 사라집니다
- 최소 두 사람이 꺼낼 수 있어야 합니다. 담당자 한 명만 아는 상태를 만들지 마세요
- 공개키도 같이 적어둡니다. 개인키에서 언제든 다시 계산할 수 있지만, 개인키를 잃으면
  "지금 배포된 앱들이 어떤 키를 믿고 있는지" 확인할 방법이 없어집니다

공개키를 꺼내는 명령입니다. 워커에 별도 명령을 두지 않아서 `openssl` 로 합니다.

```bash
KEY="$ALLEY_SPARKLE_PRIVATE_KEY"
{ printf '302e020100300506032b657004220420' | xxd -r -p; \
  printf '%s' "$KEY" | base64 -d | head -c 32; } \
  | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64
```

## 잃어버리면 무슨 일이 벌어지나

잃은 키를 되살릴 방법은 없습니다. 그건 복구할 수 없습니다.

새 키를 만들면 워커는 새 키로 서명하는데, 이미 배포된 앱들은 옛 공개키로 그 서명을
검증하니 맞지 않습니다. Sparkle 은 `SUPublicEDKey` 를 **문자열 하나로만** 읽습니다.
두 키를 동시에 믿게 하거나, 옛 키를 남겨둔 채 새 키를 더하는 항목은 없습니다.

다만 Alley 에서는 여기서 끝나지 않습니다. Sparkle 은 Ed25519 서명과 Apple 코드 서명
**둘 중 하나만** 맞아도 업데이트를 받아들입니다. Sparkle 소스(`SUUpdateValidator.m`)의
주석이 그대로 말합니다.

> Either DSA must be valid, or Apple Code Signing must be valid. We allow failure of
> one of them, because this allows key rotation without breaking chain of trust.

Alley 의 결과물은 워커가 Developer ID 로 서명·공증한 것이고, 이미 깔린 앱도 같은
identity 로 서명돼 있습니다. **코드 서명 쪽이 이어져 있는 한 새 키로 넘어갈 수
있습니다.** 아래 절차를 밟으면 됩니다. 그 조건이 깨지는 경우는 절차 끝에 적었습니다.

## 교체 절차

**한 번에 하나만 바꿉니다.** Ed25519 키와 Developer ID 인증서를 같은 업데이트에서
동시에 바꾸면 이어줄 것이 없어져 그 자리에서 끊깁니다. Sparkle 문서의 표현 그대로
"changes either your Apple code signing certificate or your EdDSA keys (but not both)"
입니다.

1. **새 키를 만든다**

   ```bash
   openssl rand -base64 32
   ```

2. **워커를 새 키로 바꾼다**

   설정 파일의 `ALLEY_SPARKLE_PRIVATE_KEY` 를 새 키로 고치고 다시 설치합니다.

   ```bash
   vi ~/worker.conf                              # ALLEY_SPARKLE_PRIVATE_KEY 를 바꿉니다
   ./install-worker.sh --config ~/worker.conf
   ```

   키만 바꾸는 것이라 워커 번들은 그대로 두어도 됩니다. 지금 설치된 것과 같은
   키트를 다시 쓰면 됩니다.

   이때부터 새로 서명되는 결과물은 전부 새 키로 서명됩니다. appcast 에 이미 올라가
   있는 옛 버전의 서명은 그대로 남아 옛 키로 계속 검증됩니다.

3. **각 앱에 새 공개키를 박은 빌드를 낸다**

   위 `openssl` 명령으로 새 공개키를 꺼내 앱의 `Info.plist` 에서 `SUPublicEDKey` 를
   바꾸고 빌드합니다. **인증서는 건드리지 않습니다.**

4. **그 빌드를 평소대로 올린다**

   이미 깔린 앱은 이 업데이트의 Ed25519 서명(새 키)을 검증하지 못하지만, 코드 서명이
   이어져 있어서 받아들입니다. 설치되고 나면 그 앱은 새 공개키를 갖게 되고 그다음부터는
   Ed25519 검증으로 돌아갑니다.

5. **옛 키를 지운다**

   모든 앱이 4번을 통과한 것을 확인한 뒤에 보관소에서 지웁니다. 오래 켜지 않은 맥이
   남아 있으면 그 앱은 아직 옛 키를 믿고 있습니다. 관리 > 통계의 다운로드 수로 얼마나
   넘어왔는지 가늠할 수 있습니다.

### 4번이 안 되는 경우

이때는 새 빌드를 **사람이 나눠줘야** 합니다. 스토어 앱으로 받게 하거나 링크를 직접
전달합니다. Sparkle 경로로는 넘어갈 방법이 없습니다.

- **앱이 `SUVerifyUpdateBeforeExtraction` 을 켰을 때.** 이 설정을 켜면 Sparkle 은
  압축을 풀기 전에 검증해서 새 번들의 코드 서명을 볼 수 없습니다. Sparkle 문서는 이
  경우 키 교체를 "Developer ID 로 서명한 디스크 이미지(dmg)" 에서만 지원한다고 적습니다.
  **Alley 는 zip 을 배포합니다.** 이 설정을 켠 앱은 Sparkle 로 키를 교체할 수 없습니다

- **번들 ID 나 서명 identity 가 함께 바뀌었을 때.** Sparkle 은 이미 깔린 앱의
  designated requirement 를 새 빌드에 그대로 적용합니다. 무엇이 걸려 있는지는 그 앱에서
  직접 볼 수 있습니다:

  ```bash
  codesign -d -r- /Applications/MyApp.app
  ```

  Developer ID 의 designated requirement 는 보통 번들 ID 와 Team ID 에 걸리므로 같은
  팀에서 인증서를 갱신만 한 경우는 그대로 통과할 것으로 보입니다. **다만 이건 확인
  필요입니다.** 실제로 갱신해보기 전에는 단정하지 마세요. 위 명령으로 requirement 를
  미리 확인해두면 판단할 수 있습니다

## 언제 교체하나

- **유출이 의심될 때.** 워커 머신이 뚫렸거나, 백업이 엉뚱한 곳에 올라갔거나, 키를
  슬랙이나 이슈에 붙여넣었을 때. 의심만으로 충분합니다
- **키를 알던 사람이 나갈 때.** 팀을 옮기는 것도 포함합니다
- **워커 머신을 폐기할 때.** 디스크를 지웠어도 백업에는 남아 있습니다

정기 교체는 권하지 않습니다. 교체할 때마다 모든 앱이 3번과 4번을 밟아야 하고, 그 사이
어느 앱 하나가 빠지면 그 앱만 조용히 업데이트가 멈춥니다. 이유 없이 그 위험을 반복할
값이 없습니다.

---

워커 설치는 [설치 가이드 4번](setup.md#4-서명-워커-설치)에, 나머지 운영은
[운영 가이드](operations.md)에 있습니다. 왜 이렇게 만들었는지가 궁금하면
[ADR 목록](adr/README.md)을 보세요.
