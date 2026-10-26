import AlleyStoreCore

// 앱 코드는 AlleyStoreCore 에 있다. 여기서는 띄우기만 한다.
// 실행 타깃에 코드를 두면 테스트가 그것을 임포트할 수 없다.
// launchd 가 업데이트 확인으로 띄웠으면 창을 열지 않고 확인만 하고 끝낸다 (이슈 #74).
if BackgroundUpdateCheck.isRequested {
    BackgroundUpdateCheck.runAndExit()
}
AlleyStoreApp.main()
