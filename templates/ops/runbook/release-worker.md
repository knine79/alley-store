# 워커를 새로 배포하기

보통은 **할 일이 없습니다.** 제품 레포에 새 릴리스가 뜨면 `watch.yml` 이 PR 을
만들고, 그것을 머지하면 `adopt.yml` 이 빌드·서명해 올립니다. 워커들은 일이 없을 때
스스로 갈아끼웁니다.

## 손으로 해야 할 때

자동 경로가 막혔거나 급할 때입니다.

```bash
cd product
export $(grep -v '^#' ../config/signing.env | xargs -0 echo)   # 값에 공백이 있으면 직접 export
./scripts/build-worker-app.sh --sign
```

만들어진 `.build/worker-app/alley-worker.zip` 을 관리 > 서명 워커 > 릴리스 올리기에
넣습니다. **`alley-worker-kit.zip` 이 아닙니다** - 그건 처음 설치할 때 쓰는 것이고,
올리면 서버가 "설치 키트를 올리신 것 같습니다" 로 거절합니다.

## 잘 갔는지

관리 > 서명 워커 화면의 **워커 버전** 열을 봅니다. 빨간 배지는 서버가 아는 것보다
낡았다는 뜻입니다. 10분쯤 뒤에 사라져야 정상입니다.

워커 로그에 이런 줄이 남습니다.

```
새 워커 0.2.1 를 받습니다. 지금은 0.2.0 입니다.
워커를 0.2.1 로 갈아끼웠습니다. 이전 번들은 alley-worker.app.previous 에 둡니다.
```

## 되돌리기

관리 > 서명 워커 > 릴리스 목록에서 **옛 버전의 배포 버튼**을 누릅니다. 워커들이
다음 확인에서 그쪽으로 내려갑니다.

그것도 안 되면 워커 맥에서 직접 되돌립니다. 갈아끼우기 전 번들이 옆에 있습니다.

```bash
cd ~/Library/Application\ Support/alley-worker
rm -rf alley-worker.app && mv alley-worker.app.previous alley-worker.app
launchctl kickstart -k gui/$(id -u)/<launchd 라벨>
```
