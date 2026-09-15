/*
 * 한 번만 보여줄 표시를 한 번만 보여준다.
 *
 * 저장하고 나면 서버가 `?saved=1` 을 붙여 같은 화면으로 돌려보낸다. 그 표시를 읽어
 * "저장했습니다" 를 띄우는데, **표시가 주소에 남아 있어서** 새로고침하든 뒤로 갔다
 * 오든 같은 줄이 다시 뜬다. 방금 저장한 것이 아닌데 방금 저장한 것처럼 보이고,
 * 한 번 뜨면 그 탭에서는 없앨 방법이 없다.
 *
 * 그려진 뒤에 주소에서 걷어낸다. 화면에는 그대로 있고, 다시 불러오면 없다.
 * 주소만 바꾸므로 뒤로 가기 기록도 늘어나지 않는다 (`replaceState`).
 *
 * 잘 됐다는 줄은 몇 초 뒤 스스로 비켜준다. 읽고 나면 할 일이 없는 문장이고, 남아
 * 있으면 다음에 본 화면이 방금 한 일의 결과인지 헷갈린다. **오류는 남긴다.** 그쪽은
 * 읽고 나서 할 일이 있고, 사라지면 무엇이 잘못됐는지 다시 알아낼 방법이 없다.
 */
(function () {
    "use strict";

    /** 서버가 한 번만 쓰라고 붙이는 것들. */
    var ONE_SHOT = ["saved", "error", "built"];

    /** 잘 됐다는 줄이 화면에 머무는 시간. 한 문장을 읽고도 남는 길이다. */
    var LINGER_MS = 6000;

    function stripQuery() {
        if (!window.history || !window.history.replaceState || !window.URL) return;

        var url = new URL(window.location.href);
        var changed = false;
        ONE_SHOT.forEach(function (key) {
            if (url.searchParams.has(key)) {
                url.searchParams.delete(key);
                changed = true;
            }
        });
        if (!changed) return;

        window.history.replaceState(
            window.history.state, "", url.pathname + url.search + url.hash
        );
    }

    function fadeOut(notice) {
        window.setTimeout(function () {
            notice.classList.add("notice-leaving");
            // 다 사라진 뒤에 자리까지 없앤다. 먼저 없애면 아래 내용이 덜컥 올라온다.
            window.setTimeout(function () {
                notice.hidden = true;
            }, 400);
        }, LINGER_MS);
    }

    stripQuery();
    document.querySelectorAll(".notice-ok").forEach(fadeOut);
})();
