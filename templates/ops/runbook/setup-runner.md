# 서명 맥에 러너 얹기

서명 맥에 GitHub self-hosted 러너를 설치합니다. `adopt.yml` 이 이 러너에서만
돕니다 - Developer ID 개인키를 맥 밖으로 내보내지 않으려는 것입니다 (ADR-0043).

**한 번만 하는 일입니다.** 맥을 새로 깔거나 서명 맥을 바꿀 때 다시 봅니다.

## 반드시 그 맥의 화면 앞에서 하세요

SSH 로 하지 마세요. 러너는 LaunchAgent 로 돌고, 로그인 키체인은 **GUI 로그인
세션에서만** 열립니다. SSH 세션에서 설치하면 설치는 되는데 서명할 때
`User interaction is not allowed` 로 죽습니다. 공증 프로필 저장도 마찬가지입니다
(`credentials.md` 참고 - 실패해도 마지막 줄은 `Success.` 로 끝납니다).

화면 공유도 GUI 세션이라 괜찮습니다.

## 어느 맥에 얹나

**러너는 맥이 아니라 레포에 등록됩니다.** 맥 쪽에서만 보면 그 맥이 어느 레포에
열려 있는지 알 수 없습니다. 얹기 전에 이미 붙어 있는 것부터 봅니다.

```bash
launchctl list | grep actions.runner
gh api /repos/<owner>/<repo> -q .visibility
gh api /repos/<owner>/<repo>/actions/permissions/fork-pr-contributor-approval
```

**공개 레포 러너가 있는 맥에는 서명 키를 두지 않습니다.** fork PR 이 같은 맥에서
돌고, 그 잡에서 `codesign` 을 부르는 것을 막는 것은 아무것도 없습니다. 시크릿이
주어지지 않는 것과 로컬 키체인은 별개입니다.

사내 CI 맥에 러너를 얹는 일이 흔한데, 그중 하나가 공개 레포면 그 맥은 서명 맥이
될 수 없습니다. **비공개 레포 러너가 함께 있는 것은 괜찮습니다** - 외부인이 PR 로
코드를 보낼 수 없으니까요. 대신 그 레포에 write 권한이 있는 사람은 그 맥에서 코드를
돌릴 수 있다는 점은 남습니다.

## 0. 맥이 깨어 있고 스스로 로그인하는가

**여기가 틀어져 있으면 러너를 얹어도 재부팅 한 번에 조용히 멈춥니다.**

```bash
fdesetup status                                                   # FileVault
sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser
pmset -g | grep -E ' sleep| autorestart'
```

| 봐야 하는 것 | 이래야 합니다 |
| --- | --- |
| FileVault | **꺼져 있어야** 자동 로그인을 켤 수 있습니다 |
| `autoLoginUser` | 러너를 돌릴 계정 이름 |
| `autorestart` | `1` (정전 뒤 스스로 켜짐) |

```bash
sudo pmset -a autorestart 1
```

자동 로그인은 시스템 설정 > 사용자 및 그룹 > 자동으로 로그인 에서 켭니다.
**FileVault 가 켜져 있으면 이 항목이 아예 안 보입니다.** 그때는 둘 중 하나입니다 -
FileVault 를 끄고 그 맥을 잠글 수 있는 곳에 두거나, 재부팅 때마다 사람이 가거나.

### 잠자기는 확인만 하면 됩니다

`sleep 0` 이 꼭 필요한 것은 아닙니다. Apple Silicon 맥은 잠자기가 얕고, 유선
이더넷이거나 뭔가 power assertion 을 걸고 있으면 애초에 잠들지 않습니다. 잠을
막는 앱(Caffeine 류)이 깔려 있어도 마찬가지입니다.

추측하지 말고 그 맥이 실제로 잠든 적이 있는지 보세요.

```bash
pmset -g assertions | head -20                       # 지금 누가 잠을 막고 있나
pmset -g log | grep -E "Entering Sleep|Wake from" | tail -20
```

`Entering Sleep` 기록이 없으면 그냥 둡니다. 있으면 시스템 설정 > 배터리(또는
에너지) > "디스플레이가 꺼져 있을 때 자동으로 잠자지 않게 하기" 를 켜거나
`sudo pmset -a sleep 0` 합니다.

> **"네트워크 연결 시 깨우기" 로는 안 됩니다.** 그건 밖에서 이 맥으로 들어오는
> 트래픽에 깨어나는 기능인데, 러너는 반대 방향입니다. 이 맥이 GitHub 쪽으로
> 연결을 걸어두고 기다리는 구조라 깨워줄 패킷이 도착할 자리가 없습니다.

공증 대기 중에는 수십 분간 CPU 가 놉니다. 빌드 중에 idle sleep 조건에 가장
가까워지는 지점이라, 걱정되면 그 스텝만 `caffeinate -i` 로 감싸는 방법도 있습니다.

키체인이 시간이 지나 잠기지 않는지도 봅니다. Keychain Access > login >
암호 변경 옆 **설정**에서 "다음 시간 후 잠금" 과 "잠자기 시 잠금" 이 꺼져 있어야
합니다.

## 1. 등록 토큰 받기

**이 레포에만 등록합니다.** 제품 레포 `knine79/alley-store` 는 공개라서, 거기
등록하면 누구든 PR 로 서명 맥에서 코드를 돌릴 수 있습니다.

브라우저에서 받는 쪽이 쉽습니다.

```
https://github.com/<조직>/<운영 레포>/settings/actions/runners/new
```

`gh` 가 깔려 있으면 이렇게도 됩니다.

```bash
gh api -X POST /repos/<조직>/<운영 레포>/actions/runners/registration-token -q .token
```

**한 시간 지나면 못 씁니다.** 받고 바로 다음 단계로 갑니다.

## 2. 내려받아 설정

한 맥에 러너를 여러 개 돌릴 수 있습니다. **디렉터리만 분리하면 됩니다.** plist
라벨이 `actions.runner.<owner>-<repo>.<name>` 이라 서로 안 부딪힙니다.

**기존 러너가 어디 깔려 있는지 먼저 보고 그 옆에 둡니다.** 맥마다 다릅니다 -
맥마다 다릅니다.

```bash
plutil -extract WorkingDirectory raw -o - \
  ~/Library/LaunchAgents/actions.runner.<owner>-<repo>.<name>.plist
```

```bash
mkdir -p ~/actions-runner-<이름> && cd ~/actions-runner-<이름>

RUNNER_VERSION=2.337.0
ARCH=$([ "$(uname -m)" = arm64 ] && echo arm64 || echo x64)
curl -fsSL -O \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-${ARCH}-${RUNNER_VERSION}.tar.gz"
tar xzf "actions-runner-osx-${ARCH}-${RUNNER_VERSION}.tar.gz"
```

```bash
./config.sh \
  --url https://github.com/<조직>/<운영 레포> \
  --token <1단계에서 받은 토큰> \
  --name <맥 이름> \
  --labels macos,alley-signing \
  --work _work \
  --unattended --replace
```

`self-hosted` 는 저절로 붙습니다. `adopt.yml` 의
`runs-on: [self-hosted, macos, alley-signing]` 과 맞춰야 합니다.
**라벨이 하나라도 어긋나면 잡이 실패하지 않고 영원히 대기합니다.** 러너가 없는
것과 구분이 안 됩니다.

## 3. PATH 를 적어둡니다

LaunchAgent 는 로그인 셸의 환경을 물려받지 않습니다. Homebrew 나 mise 로 깐 것을
빌드 스크립트가 쓰면 러너 안에서만 `command not found` 가 납니다.

```bash
cat > .env <<'EOF'
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
EOF
```

`codesign`·`xcrun`·`swift` 는 `/usr/bin` 에 있어 그대로 됩니다.

## 4. 서비스로 등록

```bash
./svc.sh install
./svc.sh start
./svc.sh status
```

`~/Library/LaunchAgents/actions.runner.<조직>-<운영 레포>.<맥 이름>.plist` 가
생깁니다. Daemon 이 아니라 **Agent** 입니다. 로그인해야 뜬다는 뜻이고, 그래서
0번이 전제입니다.

```bash
launchctl print gui/$(id -u)/actions.runner.<조직>-<운영 레포>.<맥 이름> | head -5
gh api /repos/<조직>/<운영 레포>/actions/runners \
  -q '.runners[] | "\(.name) \(.status) \(.labels[].name)"'
```

`online` 이면 붙은 것입니다.

## 5. 서명이 되는 맥인지 확인

`adopt.yml` 이 맨 앞에서 보는 것과 같습니다. 손으로 먼저 통과시켜 둡니다.

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
xcrun notarytool history --keychain-profile alley --output-format json >/dev/null && echo "공증 OK"
```

둘 중 하나라도 안 되면 러너 문제가 아니라 키체인 문제입니다.
`runbook/cert-expiry.md` 로 갑니다.

## 6. 점검 스크립트를 돌립니다

설치가 끝났으면 이걸 먼저 돌리세요. **설치는 됐는데 나중에 터지는 것들**을
여기서 잡습니다.

```bash
./scripts/check-signing-mac.sh
```

서명과 공증은 실제로 해봅니다. 특히 **프롬프트 없이 서명되는지**를 보는데,
그 창이 뜨면 러너에서는 답할 사람이 없어 잡이 타임아웃까지 멈춥니다.

그 맥에 공개 레포 러너가 함께 있는지도 봅니다. 있으면 서명 키가 fork PR 의
사정거리 안에 있는 것입니다.

## 7. 한 번 돌려보기

Actions > 제품 반영 > Run workflow.

**지금은 "고정 버전 대조" 에서 실패하는 것이 정상입니다.** 제품 레포에 아직
릴리스 태그가 없어 `alley.lock` 과 서브모듈이 맞을 수가 없습니다. 여기까지 왔으면
러너는 제대로 붙은 것입니다 - 잡을 집었고, 체크아웃했고, 그 맥에서 돌았다는
뜻이니까요.

`README.md` 의 남은 준비에서 첫 태그를 만든 뒤 다시 돌립니다.

## 잘 안 될 때

| 증상 | 볼 곳 |
| --- | --- |
| 잡이 계속 대기 | 라벨 오타. 러너 목록의 라벨과 `adopt.yml` 의 `runs-on` 대조 |
| 러너가 offline | 그 맥이 로그인돼 있는지. 재부팅 뒤 자동 로그인이 안 걸렸을 수 있음 |
| 서명이 `User interaction is not allowed` | 키체인이 잠김. SSH 로 설치했거나 자동 로그인이 꺼짐 |
| `command not found` | 3번의 `.env` |
| 빌드가 디스크로 죽음 | `_work` 가 커짐. 잡 사이에 안 지웁니다 |

러너 자체 로그는 여기 쌓입니다.

```bash
tail -100 ~/actions-runner-<이름>/_diag/Runner_*.log
```

## 떼어낼 때

```bash
cd ~/actions-runner-<이름>
./svc.sh stop && ./svc.sh uninstall
./config.sh remove --token <제거 토큰>
```

제거 토큰은 등록 토큰과 다릅니다.

```bash
gh api -X POST /repos/<조직>/<운영 레포>/actions/runners/remove-token -q .token
```

러너 자체는 새 버전이 나오면 스스로 갱신합니다. 손댈 일이 없습니다.
