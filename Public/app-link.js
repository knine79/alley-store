/*
 * 공유 페이지가 열리면 스토어 앱을 바로 부른다 (ADR-0072).
 *
 * 처음에는 "여는 중입니다" 만 보이고 버튼이 없다. 대부분은 스토어 앱이 깔려 있고,
 * 그 사람에게 버튼은 누를 필요가 없는 것이다.
 *
 * 브라우저는 앱이 깔려 있는지 알려주지 않는다. 그래서 포커스로 짐작한다. 스토어
 * 앱이 열리면 브라우저 창이 포커스를 잃는다. **2초 뒤에도 이 페이지가 포커스를 쥐고
 * 있거나, 다른 곳에 갔다가 포커스가 돌아오면** 버튼 둘(보기, 다운로드)을 꺼낸다.
 * 돌아온 경우를 넣은 것은 Chrome 의 "앱을 여시겠습니까" 에서 취소했거나, 설치하러
 * 갔다가 돌아온 사람이 다시 누를 자리가 있어야 하기 때문이다.
 *
 * **버튼은 나타나기만 하고 바뀌지 않는다.** 예전에는 반응이 없으면 버튼의 순서와
 * 색을 바꿨는데, 짐작이 틀리면 앱이 열렸는데도 눈앞의 버튼이 바뀌어 당황스러웠다.
 *
 * 스크립트가 없으면 템플릿의 `noscript` 가 처음부터 버튼을 보여준다.
 */
(function () {
    "use strict";

    /** 스토어 앱이 앞으로 나오기를 기다리는 시간. 앱이 처음 뜨는 데 걸리는 시간보다 길게. */
    var WAIT_MS = 2000;

    var root = document.querySelector("[data-app-link]");
    if (!root) return;
    var actions = root.querySelector("[data-app-link-actions]");
    var opening = root.querySelector("[data-app-link-opening]");
    var open = root.querySelector("[data-app-link-open]");
    if (!actions) return;

    function showActions() {
        if (!actions.hidden) return;
        actions.hidden = false;
        if (opening) opening.hidden = true;
    }

    // 스킴 주소를 만들지 못한 경우다. 부를 것이 없으니 바로 버튼을 보인다.
    if (!open) {
        showActions();
        return;
    }

    function hasPage() {
        return !document.hidden && document.hasFocus();
    }

    function start() {
        window.location.href = open.href;

        window.setTimeout(function () {
            if (hasPage()) showActions();
        }, WAIT_MS);

        // 다른 곳(스토어 앱, 브라우저의 확인 창, 다운로드)에 갔다가 돌아왔다. 한 번
        // 떠난 뒤의 포커스만 센다. 페이지가 뜨면서 받는 포커스로 버튼이 나오면 안 된다.
        var left = false;
        function markLeft() { left = true; }
        function maybeReturned() {
            if (left && hasPage()) showActions();
        }
        window.addEventListener("blur", markLeft);
        window.addEventListener("focus", maybeReturned);
        document.addEventListener("visibilitychange", function () {
            if (document.hidden) markLeft();
            else maybeReturned();
        });
    }

    // 뒤에서 열린 탭에서 부르면 아무도 보지 않는 사이에 끝난다. 사람이 볼 때 부른다.
    if (document.hidden) {
        document.addEventListener("visibilitychange", function onVisible() {
            if (document.hidden) return;
            document.removeEventListener("visibilitychange", onVisible);
            start();
        });
    } else {
        start();
    }
})();
